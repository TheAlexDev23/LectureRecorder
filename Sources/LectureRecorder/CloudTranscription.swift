import Foundation
import AVFoundation
import Security

enum OpenRouterKeychain {
    private static let service = "com.alex.LectureRecorder.openrouter"
    private static let account = "OpenRouter"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppFailure("Enter an OpenRouter API key.") }
        remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppFailure("Could not save the OpenRouter key in Keychain (\(status)).") }
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct OpenRouterTranscriptionResponse: Decodable {
    struct APIWord: Decodable {
        var start: Double
        var end: Double
        var word: String?
        var text: String?
        var value: String { word ?? text ?? "" }
    }
    struct APISegment: Decodable {
        var start: Double
        var end: Double
        var text: String
    }
    var text: String
    var segments: [APISegment]?
    var words: [APIWord]?
}

enum MicrosoftTranscriber {
    static func transcribe(file: URL, locale: String, duration _: Double) async throws -> [Segment] {
        guard let key = OpenRouterKeychain.read() else { throw AppFailure("Add your OpenRouter API key in Settings before using Microsoft transcription.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LectureRecorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let chunks = try await makeChunks(file: file, folder: folder)
        let language = locale.split(separator: "-").first.map(String.init) ?? "en"
        var words: [WordTiming] = []
        for (index, chunk) in chunks.enumerated() {
            let result = try await request(chunk.url, key: key, language: language)
            let low = index == 0 ? -Double.infinity : chunk.start + 5
            let high = index == chunks.count - 1 ? Double.infinity : chunks[index + 1].start + 5
            for word in result.words ?? [] {
                let start = chunk.start + word.start
                let end = chunk.start + word.end
                if end >= low, start < high, !word.value.isEmpty { words.append(WordTiming(start: start, end: end, text: word.value)) }
            }
        }
        words.sort { $0.start < $1.start }
        guard !words.isEmpty else { throw AppFailure("Microsoft returned an empty transcript. The recording is still available for retry.") }
        return makeSegments(words)
    }

    private struct AudioChunk { var url: URL; var start: Double }

    private static func makeChunks(file: URL, folder: URL) async throws -> [AudioChunk] {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let normalized = folder.appendingPathComponent("normalized.wav")
            do { try StoredAudio.speechWAV(file, to: normalized) } catch {
                throw AppFailure("Could not prepare audio for Microsoft transcription. \(error.localizedDescription)")
            }
            let input = try AVAudioFile(forReading: normalized)
            let rate = input.processingFormat.sampleRate
            let windowFrames = AVAudioFramePosition(rate * 270) // Under OpenRouter's hidden decoded-audio limit.
            let stepFrames = AVAudioFramePosition(rate * 260)   // Ten seconds of overlap protects boundary words.
            var result: [AudioChunk] = []
            var start: AVAudioFramePosition = 0
            while start < input.length {
                input.framePosition = start
                let count = min(windowFrames, input.length - start)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { throw AppFailure("Could not allocate an audio upload buffer.") }
                try input.read(into: buffer, frameCount: AVAudioFrameCount(count))
                let url = folder.appendingPathComponent(String(format: "%06d.wav", Int(Double(start) / rate)))
                let output = try AVAudioFile(forWriting: url, settings: input.fileFormat.settings)
                try output.write(from: buffer)
                result.append(AudioChunk(url: url, start: Double(start) / rate))
                if start + count >= input.length { break }
                start += stepFrames
            }
            return result
        }.value
    }

    private static func request(_ file: URL, key: String, language: String) async throws -> OpenRouterTranscriptionResponse {
        let audio = try Data(contentsOf: file, options: .mappedIfSafe)
        let body: [String: Any] = [
            "model": "microsoft/mai-transcribe-2",
            "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
            "language": language,
            "temperature": 0,
            "response_format": "verbose_json",
            "timestamp_granularities": ["word"]
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Lecture Recorder", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppFailure("OpenRouter returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(600)) } ?? "No response details"
            throw AppFailure("Microsoft transcription failed (HTTP \(http.statusCode)): \(detail)")
        }
        return try JSONDecoder().decode(OpenRouterTranscriptionResponse.self, from: data)
    }

    private static func makeSegments(_ words: [WordTiming]) -> [Segment] {
        var result: [Segment] = []
        var current: [WordTiming] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            if !text.isEmpty { result.append(Segment(start: first.start, end: last.end, text: text, wordTimings: current)) }
            current.removeAll(keepingCapacity: true)
        }
        var previousEnd: Double?
        for word in words {
            if let previousEnd, !current.isEmpty, word.start - previousEnd > 1.6 { flush() }
            current.append(word)
            let elapsed = word.end - (current.first?.start ?? word.start)
            if (elapsed >= 5 && [".", "?", "!"].contains(where: { word.text.hasSuffix($0) })) || elapsed >= 24 { flush() }
            previousEnd = word.end
        }
        flush()
        return result
    }
}
