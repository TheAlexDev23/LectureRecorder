import AVFoundation
import Speech
import CoreMedia

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
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(recordedFrames) / file.processingFormat.sampleRate
    }
    var hasFailed = false
    init(url: URL, input: AVAudioFormat, output: AVAudioFormat?, deliver: ((AVAudioPCMBuffer) -> Void)?, failure: @escaping (String) -> Void) throws {
        file = try AVAudioFile(forWriting: url, settings: input.settings)
        outputFormat = output
        converter = output.flatMap { AVAudioConverter(from: input, to: $0) }
        self.deliver = deliver
        self.failure = failure
        if output != nil && converter == nil { throw AppFailure("Could not convert microphone audio for SpeechAnalyzer.") }
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !hasFailed else { return }
        do {
            try file.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
            guard let converter, let outputFormat else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw AppFailure("Could not allocate speech audio buffer.") }
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
            if converted.frameLength > 0 { deliver?(converted) }
        } catch {
            hasFailed = true
            failure(error.localizedDescription)
        }
    }
}

@MainActor final class Recorder {
    private let engine = AVAudioEngine()
    private var sink: AudioSink?
    private var speech: AnyObject?
    private var sleepActivity: NSObjectProtocol?
    private(set) var isPaused = false
    var duration: TimeInterval { sink?.duration ?? 0 }
    func start(url: URL, locale: String, onSegments: @escaping @MainActor ([Segment]) -> Void, onError: @escaping @MainActor (String) -> Void) async throws -> String? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppFailure("Microphone access was denied. Enable Lecture Recorder in System Settings → Privacy & Security → Microphone.") }
        var output: AVAudioFormat?
        var deliver: ((AVAudioPCMBuffer) -> Void)?
        var warning: String?
        if #available(macOS 26.0, *) {
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
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AppFailure("No working microphone input. Check Sound settings.") }
            let sink = try AudioSink(url: url, input: format, output: output, deliver: deliver) { message in Task { @MainActor in onError(message) } }
            self.sink = sink
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in sink.consume(buffer) }
            engine.prepare()
            try engine.start()
            isPaused = false
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a lecture")
            return warning
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            if #available(macOS 26.0, *), let session = speech as? SpeechSession { await session.cancel() }
            speech = nil
            sink = nil
            throw error
        }
    }
    func pause() {
        guard sink != nil, !isPaused else { return }
        engine.pause()
        isPaused = true
    }
    func resume() throws {
        guard sink != nil, isPaused else { return }
        // Keep the tap, file, converter and analyzer alive across the pause.
        try engine.start()
        isPaused = false
    }
    func stop() async throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
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
