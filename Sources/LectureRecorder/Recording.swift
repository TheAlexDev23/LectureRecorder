import AVFoundation
import Speech
import CoreMedia
import AudioTap

@available(macOS 26.0, *)
@MainActor final class SpeechSession {
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    var format: AVAudioFormat?

    func prepare(locale identifier: String, onSegments: @escaping @MainActor ([Segment]) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw AppFailure("Apple SpeechTranscriber is unavailable on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else { throw AppFailure("Apple does not support the selected transcription language (\(identifier)).") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw AppFailure("No compatible speech audio format.") }
        self.format = format
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        resultsTask = Task {
            for try await result in transcriber.results {
                var words: [WordTiming] = []
                for run in result.text.runs {
                    if let range = run.audioTimeRange {
                        words.append(WordTiming(start: CMTimeGetSeconds(range.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd(range)), text: String(result.text[run.range].characters)))
                    }
                }
                let segment = Segment(start: CMTimeGetSeconds(result.range.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)), text: String(result.text.characters), wordTimings: words)
                onSegments([segment])
            }
        }
    }
    func beginStream() async throws -> AsyncStream<AnalyzerInput>.Continuation {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer!.start(inputSequence: stream)
        return continuation
    }
    func finish() async throws {
        continuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        continuation = nil
        analyzer = nil
    }
    func transcribe(file: URL) async throws {
        let audio = try AVAudioFile(forReading: file)
        try await analyzer!.start(inputAudioFile: audio, finishAfterFile: true)
        try await resultsTask?.value
        analyzer = nil
    }
    func cancel() async {
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
    }
}

// AVAudioEngine owns the callback thread. Conversion and file writes are serialized by its tap.
final class AudioSink: @unchecked Sendable {
    let file: AVAudioFile
    let converter: AVAudioConverter?
    let outputFormat: AVAudioFormat?
    let deliver: ((AVAudioPCMBuffer) -> Void)?
    let failure: (String) -> Void
    private let lock = NSLock()
    private var recordedFrames: AVAudioFramePosition = 0
    // Created when the microphone changes mid-recording (e.g. headphones connect) so the file keeps one format.
    private var inputConverter: AVAudioConverter?
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(recordedFrames) / file.processingFormat.sampleRate
    }
    var hasFailed = false
    init(url: URL, input: AVAudioFormat, output: AVAudioFormat?, deliver: ((AVAudioPCMBuffer) -> Void)?, failure: @escaping (String) -> Void) throws {
        let file = try AVAudioFile(forWriting: url, settings: input.settings)
        self.file = file
        outputFormat = output
        converter = output.flatMap { AVAudioConverter(from: file.processingFormat, to: $0) }
        self.deliver = deliver
        self.failure = failure
        if output != nil && converter == nil { throw AppFailure("Could not convert microphone audio for SpeechAnalyzer.") }
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !hasFailed else { return }
        do {
            let recorded = try normalize(buffer)
            guard recorded.frameLength > 0 else { return }
            try file.write(from: recorded)
            recordedFrames += AVAudioFramePosition(recorded.frameLength)
            guard let converter, let outputFormat else { return }
            let converted = try Self.convert(recorded, with: converter, to: outputFormat)
            if converted.frameLength > 0 { deliver?(converted) }
        } catch {
            hasFailed = true
            failure(error.localizedDescription)
        }
    }
    private func normalize(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let format = file.processingFormat
        guard buffer.format != format else { return buffer }
        if inputConverter?.inputFormat != buffer.format {
            guard let converter = AVAudioConverter(from: buffer.format, to: format) else { throw AppFailure("The new microphone's audio format cannot be recorded into this session.") }
            inputConverter = converter
        }
        return try Self.convert(buffer, with: inputConverter!, to: format)
    }
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AppFailure("Could not allocate an audio buffer.") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        if status == .error { throw AppFailure("Audio conversion failed.") }
        return converted
    }
}

@MainActor final class Recorder {
    // A fresh engine per recording: a reused engine keeps the input format of a device that may since have disappeared.
    private var engine: AVAudioEngine?
    private var sink: AudioSink?
    private var speech: AnyObject?
    private var sleepActivity: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var recovery: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var onInterrupted: (@MainActor (String) -> Void)?
    private var lastDuration: TimeInterval = -1
    private var failedRecoveries = 0
    private(set) var isPaused = false
    var duration: TimeInterval { sink?.duration ?? 0 }
    func start(url: URL, locale: String, liveTranscription: Bool = true, onSegments: @escaping @MainActor ([Segment]) -> Void, onError: @escaping @MainActor (String) -> Void, onInterrupted: @escaping @MainActor (String) -> Void) async throws -> String? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppFailure("Microphone access was denied. Enable Lecture Recorder in System Settings → Privacy & Security → Microphone.") }
        var output: AVAudioFormat?
        var deliver: ((AVAudioPCMBuffer) -> Void)?
        var warning: String?
        if !liveTranscription {
            warning = "Microsoft transcription runs after you stop recording. Live transcription is unavailable in Microsoft mode."
        } else if #available(macOS 26.0, *) {
            let session = SpeechSession()
            do {
                try await session.prepare(locale: locale, onSegments: onSegments)
                let continuation = try await session.beginStream()
                output = session.format
                deliver = { continuation.yield(AnalyzerInput(buffer: $0)) }
                speech = session
            } catch {
                await session.cancel()
                warning = "Recording audio only: \(error.localizedDescription) Retry transcription after stopping."
            }
        } else {
            warning = "Recording audio only. Live transcription requires macOS 26; this audio can be transcribed after upgrading."
        }
        do {
            let engine = AVAudioEngine()
            self.engine = engine
            let sink = try AudioSink(url: url, input: try Self.inputFormat(engine), output: output, deliver: deliver) { message in Task { @MainActor in onError(message) } }
            self.sink = sink
            try capture(engine, into: sink)
            isPaused = false
            self.onInterrupted = onInterrupted
            monitor(engine)
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a lecture")
            return warning
        } catch {
            tearDownEngine()
            if #available(macOS 26.0, *), let session = speech as? SpeechSession { await session.cancel() }
            speech = nil
            sink = nil
            throw error
        }
    }
    private static func inputFormat(_ engine: AVAudioEngine) throws -> AVAudioFormat {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0, format.channelCount > 0, format.sampleRate == hardware.sampleRate else {
            throw AppFailure("No working microphone input. Check Sound settings.")
        }
        return format
    }
    private func capture(_ engine: AVAudioEngine, into sink: AudioSink) throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in sink.consume(buffer) }
        try LRAudioTap.install(on: engine.inputNode, bus: 0, bufferSize: 4096, format: try Self.inputFormat(engine), block: tap)
        try LRAudioTap.start(engine)
        lastDuration = -1
    }
    // macOS stops the engine whenever the input device changes (headphones connect, a dock is unplugged, ...).
    // Without a restart the session looks live but records nothing.
    private func monitor(_ engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Device switches arrive as a burst of notifications; restart once it settles.
                self.recovery?.cancel()
                self.recovery = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    self?.recover()
                }
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.checkCapture()
            }
        }
    }
    private func checkCapture() {
        guard let engine, let sink, !isPaused else { lastDuration = -1; return }
        let current = sink.duration
        if !engine.isRunning || current == lastDuration { recover(); return }
        if lastDuration >= 0 { failedRecoveries = 0 }
        lastDuration = current
    }
    private func recover() {
        guard let engine, let sink, !isPaused else { return }
        failedRecoveries += 1
        do {
            guard failedRecoveries <= 3 else { throw AppFailure("No audio is arriving from the microphone.") }
            try capture(engine, into: sink)
        } catch {
            engine.pause()
            isPaused = true
            failedRecoveries = 0
            onInterrupted?("Recording paused because the microphone stopped: \(error.localizedDescription) Check Sound settings, then press Resume.")
        }
    }
    func pause() {
        guard let engine, sink != nil, !isPaused else { return }
        engine.pause()
        isPaused = true
    }
    func resume() throws {
        guard let engine, let sink, isPaused else { return }
        // Keep the file, converters and analyzer alive across the pause; reinstall the tap in case the microphone changed.
        try capture(engine, into: sink)
        isPaused = false
        failedRecoveries = 0
    }
    private func tearDownEngine() {
        recovery?.cancel(); recovery = nil
        watchdog?.cancel(); watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        onInterrupted = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }
    func stop() async throws {
        tearDownEngine()
        sink = nil
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil }
        defer { speech = nil; isPaused = false }
        if #available(macOS 26.0, *), let session = speech as? SpeechSession { try await session.finish() }
    }
    func retry(url: URL, locale: String, onSegments: @escaping @MainActor ([Segment]) -> Void) async throws {
        guard #available(macOS 26.0, *) else { throw AppFailure("Transcription requires macOS 26 or later. Your recording is safely stored locally.") }
        let session = SpeechSession()
        do {
            try await session.prepare(locale: locale, onSegments: onSegments)
            try await session.transcribe(file: url)
        } catch { await session.cancel(); throw error }
    }
}
