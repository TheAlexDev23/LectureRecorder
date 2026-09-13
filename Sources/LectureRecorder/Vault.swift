import Foundation
import PDFKit

struct Vault {
    static let fm = FileManager.default
    static func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    static func initialize(_ course: Course) throws {
        let root = URL(fileURLWithPath: course.directory)
        for dir in ["Transcripts", "Lectures", "Topics", "Materials/Inbox", "Views", "Personal Notes"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let index = root.appendingPathComponent("\(course.code).md")
        if !fm.fileExists(atPath: index.path) {
            try write("""
            ---
            type: course
            course: \(jsonString(course.code))
            title: \(jsonString(course.name))
            tags: [university/course]
            ---
            # \(course.code) · \(course.name)

            ![[Lectures.base]]

            ![[Topics.base]]
            """, to: index)
        }
        for (name, type) in [("Lectures", "lecture"), ("Topics", "topic")] {
            let url = root.appendingPathComponent("Views/\(name).base")
            if !fm.fileExists(atPath: url.path) {
                try write("""
                filters:
                  and:
                    - 'type == "\(type)"'
                    - 'course == "\(course.code)"'
                views:
                  - type: table
                    name: \(name)
                    order:
                      - file.name
                      - date
                      - status
                """, to: url)
            }
        }
    }
    static func export(_ lecture: Lecture, course: Course) throws -> String {
        let name = "\(course.code) LEC \(lecture.number)"
        let relative = "Transcripts/\(name) - Transcript.md"
        let text = lecture.segments.enumerated().map { index, segment in
            "**[\(timestamp(segment.start))–\(timestamp(segment.end))]** \(segment.text) ^t\(index + 1)"
        }.joined(separator: "\n\n")
        try write("""
        ---
        type: transcript
        course: \(jsonString(course.code))
        lecture: \(lecture.number)
        lecture_id: \(jsonString(lecture.id.uuidString))
        date: \(lecture.date.ISO8601Format())
        transcription: apple-speech-analyzer
        tags: [university/transcript]
        ---
        # \(name) — Transcript

        [[\(course.code)]] · [[\(name)]]

        > Machine transcript. Timing is audio-relative; wording and alignment may contain errors.

        \(text)
        """, to: try containedURL(relative, root: URL(fileURLWithPath: course.directory)))
        let timingURL = URL(fileURLWithPath: course.directory).appendingPathComponent("Transcripts/\(name) - Timing.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(lecture.segments).write(to: timingURL, options: .atomic)
        try exportNotes(lecture, course: course)
        return relative
    }
    static func exportNotes(_ lecture: Lecture, course: Course) throws {
        try write("# \(course.code) LEC \(lecture.number) — Personal Notes\n\n\(lecture.notes)\n", to: URL(fileURLWithPath: course.directory).appendingPathComponent("Personal Notes/\(course.code) LEC \(lecture.number) - Personal Notes.md"))
    }
    static func importMaterial(_ source: URL, lecture: Lecture, course: Course) throws -> Material {
        let id = UUID()
        let name = try safeComponent(source.lastPathComponent)
        let relative = "Materials/Inbox/\(lecture.id.uuidString)/\(id.uuidString.prefix(8))-\(name)"
        let target = try containedURL(relative, root: URL(fileURLWithPath: course.directory))
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)
        if source.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: source) {
            let pages = (0..<pdf.pageCount).map { "--- Page \($0 + 1) ---\n\(pdf.page(at: $0)?.string ?? "[No extractable text; inspect page image]")" }.joined(separator: "\n\n")
            try write(pages, to: target.appendingPathExtension("txt"))
        }
        return Material(id: id, originalName: name, relativePath: relative)
    }
    // Never follow symlinks into unrelated vault content when copying or publishing.
    static func files(in root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let walker = fm.enumerator(atPath: root.path) else { return result }
        for case let relative as String in walker {
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { walker.skipDescendants(); continue }
            let url = root.appendingPathComponent(relative)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw AppFailure("Course contains a symbolic link: \(relative). Use regular files.") }
            if attributes[.type] as? FileAttributeType == .typeRegular { result[relative] = try Data(contentsOf: url) }
        }
        return result
    }
    static func publish(workspace: URL, destination: URL, baseline: [String: Data]) throws {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let generated = try files(in: workspace)
        var changes: [(URL, Data)] = []
        for (path, data) in generated where data != baseline[path] {
            let permitted = path.hasPrefix("Lectures/") || path.hasPrefix("Topics/") || path.hasPrefix("Views/") || (path.hasPrefix("Materials/") && !path.hasPrefix("Materials/Inbox/")) || (!path.contains("/") && path.hasSuffix(".md"))
            guard permitted else { throw AppFailure("Agent attempted to change protected input: \(path)") }
            let originalMaterialCopy = path.hasPrefix("Materials/") && baseline.contains { $0.key.hasPrefix("Materials/Inbox/") && $0.value == data }
            guard originalMaterialCopy || ["md", "base", "txt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { throw AppFailure("Output must be a note, Base, text extract, or an exact copy of an attached material: \(path)") }
            let target = try containedURL(path, root: destination)
            let current = try? Data(contentsOf: target)
            guard current == baseline[path] else { throw AppFailure("\(path) changed in Obsidian during processing. Nothing was published; retry with the current notes.") }
            changes.append((target, data))
        }
        for (path, _) in baseline where generated[path] == nil { throw AppFailure("Agent deleted \(path). Nothing was published.") }
        var written: [URL] = []
        do {
            for (url, data) in changes {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                written.append(url)
            }
        } catch {
            for url in written {
                let relative = String(url.path.dropFirst(destination.path.count + 1))
                if let old = baseline[relative] { try? old.write(to: url, options: .atomic) }
                else { try? fm.removeItem(at: url) }
            }
            throw error
        }
    }
}
