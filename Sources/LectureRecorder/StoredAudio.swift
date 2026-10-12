import Foundation
import AVFoundation

// Recordings are captured as full-rate PCM, which stays readable if the app dies mid-lecture, and shrunk once finished.
// Both transcribers only ever read 16 kHz 16-bit mono, so storing exactly that losslessly (ALAC) changes nothing they see.
enum StoredAudio {
    // The conversion the Microsoft upload uses. Compression reuses it, so a compressed file uploads bit-identically.
    static func speechWAV(_ source: URL, to destination: URL) throws {
        try afconvert([source.path, destination.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])
    }
    static func isCompressed(_ url: URL) throws -> Bool {
        let format = try AVAudioFile(forReading: url).fileFormat
        return format.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless && format.sampleRate == 16000
    }
    // Replaces the recording only after the compressed copy is verified; on any failure the original is untouched.
    static func compress(_ url: URL) throws {
        guard try !isCompressed(url) else { return }
        let fm = FileManager.default
        let wav = url.deletingPathExtension().appendingPathExtension("compressing.wav")
        let staged = url.deletingPathExtension().appendingPathExtension("compressing.caf")
        defer { try? fm.removeItem(at: wav); try? fm.removeItem(at: staged) }
        try? fm.removeItem(at: staged)
        try speechWAV(url, to: wav)
        try afconvert([wav.path, staged.path, "-f", "caff", "-d", "alac", "-c", "1"])
        guard try isCompressed(staged), try AVAudioFile(forReading: staged).length == AVAudioFile(forReading: wav).length else {
            throw AppFailure("The compressed recording did not match the original.")
        }
        _ = try fm.replaceItemAt(url, withItemAt: staged)
    }
    private static func afconvert(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = arguments
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppFailure("Audio conversion failed. \(detail)")
        }
    }
}
