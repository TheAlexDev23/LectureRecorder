import Foundation

struct Course: Codable, Identifiable, Hashable {
    var id = UUID()
    var code: String
    var name: String
    var directory: String
    var archived = false
    var textbooks: [Textbook]? = nil // Optional for libraries saved before textbook support.
}
struct WordTiming: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
}
struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var wordTimings: [WordTiming]? = nil
}
enum LectureStatus: String, Codable { case recording, needsTranscription, transcribing, queued, processing, processed, failed }
struct Material: Codable, Identifiable {
    var id = UUID()
    var originalName: String
    var relativePath: String
}
struct Lecture: Codable, Identifiable {
    var id = UUID()
    var courseID: UUID
    var number: Int
    var title: String
    var date = Date()
    var status: LectureStatus = .recording
    var notes = ""
    var segments: [Segment] = []
    var materials: [Material] = []
    var error: String?
    var duration: Double = 0
    var transcriptPath: String?
    var stem: String { "LEC \(number)" }
}
struct AgentIssue: Codable, Identifiable {
    var id: String
    var lectureID: String
    var severity: String
    var message: String
    var timestamp: String
    var source: String
}
struct AgentReport: Codable {
    var completedLectureIDs: [String]
    var issues: [AgentIssue]
    var summary: String
}
struct Job: Codable, Identifiable {
    var id = UUID()
    var courseID: UUID
    var lectureIDs: [UUID]
    var date = Date()
    var state = "running"
    var directory: String
    var message = "Preparing course workspace"
    var issues: [AgentIssue] = []
}
struct Settings: Codable {
    var vaultPath = ""
    var coursesPath = "Courses"
    var locale = "en-CA"
    var codexPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
}
struct Library: Codable {
    var courses: [Course] = []
    var lectures: [Lecture] = []
    var jobs: [Job] = []
    var settings = Settings()
}
struct AppFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
}
func jsonString(_ text: String) -> String {
    String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
}
func safeComponent(_ text: String) throws -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count < 120, value != ".", value != "..",
          value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:[]#^\n\r\t\0")) == nil,
          !value.hasPrefix(".") else { throw AppFailure("Use a plain name without slashes, brackets, #, ^ or control characters.") }
    return value
}
func containedURL(_ relative: String, root: URL) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw AppFailure("Invalid relative path: \(relative)") }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    var cursor = base
    for component in relative.split(separator: "/") {
        cursor.appendPathComponent(String(component))
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw AppFailure("Symbolic links are not allowed inside managed paths: \(relative)")
        }
    }
    let result = cursor.standardizedFileURL
    guard result.path.hasPrefix(base.path + "/") else { throw AppFailure("Path leaves its selected directory: \(relative)") }
    return result
}
