import Foundation
import PDFKit

struct Textbook: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var relativePath: String
    var indexPath: String
    var sectionCount: Int
    var warning: String?
}

struct TextbookSection {
    var title: String
    var start: Int // zero-based PDF page, not printed page number
    var end: Int
}

enum TextbookImporter {
    // Bound individual reads even when a chapter is unusually long.
    static func sections(pages: [String], bookmarks: [(String, Int)]) -> [TextbookSection] {
        guard !pages.isEmpty else { return [] }
        var starts = bookmarks.filter { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pages.indices.contains($0.1) }
        if starts.isEmpty {
            for (page, text) in pages.enumerated() {
                let lines = text.components(separatedBy: .newlines).prefix(8)
                if let heading = lines.first(where: { $0.range(of: #"^\s*(chapter|part)\s+([0-9]+|[IVXLCDM]+)\b.*$"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                    if starts.last?.0 != heading { starts.append((heading, page)) }
                }
            }
        }
        starts.sort { $0.1 < $1.1 }
        var unique: [(String, Int)] = []
        for entry in starts where unique.last?.1 != entry.1 { unique.append(entry) }
        if unique.first?.1 != 0 { unique.insert((unique.isEmpty ? "Page range (chapter boundaries unavailable)" : "Front matter", 0), at: 0) }
        var result: [TextbookSection] = []
        for (index, entry) in unique.enumerated() {
            let end = index + 1 < unique.count ? unique[index + 1].1 : pages.count
            for start in stride(from: entry.1, to: end, by: 20) {
                result.append(TextbookSection(title: entry.0, start: start, end: min(start + 20, end)))
            }
        }
        return result
    }

    static func importPDF(_ source: URL, course: Course) throws -> Textbook {
        guard source.pathExtension.lowercased() == "pdf" else { throw AppFailure("Textbooks must be PDF files.") }
        let id = UUID()
        let relative = "Textbooks/\(id.uuidString)"
        let folder = try containedURL(relative, root: URL(fileURLWithPath: course.directory))
        try Vault.fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let original = folder.appendingPathComponent("Original.pdf")
            try Vault.fm.copyItem(at: source, to: original)
            guard let pdf = PDFDocument(url: original), !pdf.isLocked, pdf.pageCount > 0 else { throw AppFailure("This PDF is empty, damaged, or password protected. Upload an unlocked readable copy.") }
            let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard pages.contains(where: { !$0.isEmpty }) else { throw AppFailure("This PDF has no extractable text. Run OCR on it and upload the searchable PDF.") }
            var bookmarks: [(String, Int)] = []
            func visit(_ outline: PDFOutline) {
                if let page = (outline.destination ?? (outline.action as? PDFActionGoTo)?.destination)?.page {
                    let index = pdf.index(for: page)
                    if index < pages.count { bookmarks.append((outline.label ?? "Section", index)) }
                }
                for index in 0..<outline.numberOfChildren { if let child = outline.child(at: index) { visit(child) } }
            }
            if let outline = pdf.outlineRoot { visit(outline) }
            let sections = sections(pages: pages, bookmarks: bookmarks)
            let missing = pages.indices.filter { pages[$0].isEmpty }.map { String($0 + 1) }
            let warning = missing.isEmpty ? nil : "No extractable text on PDF pages \(missing.joined(separator: ", ")). Inspect the original or provide an OCR copy."
            let title = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "\n", with: " ")
            var indexText = "# \(title)\n\nOriginal: \(relative)/Original.pdf\n\nUse only for unresolved questions after lecture sources. Page numbers below are 1-based PDF pages, not printed page labels. Boundaries use PDF bookmarks, then detected chapter/part headings, otherwise page ranges; they may need review. Extraction may omit figures, equations or tables.\n\n"
            if let warning { indexText += "> Warning: \(warning)\n\n" }
            for (number, section) in sections.enumerated() {
                let path = "Sections/\(String(format: "%04d", number + 1)).txt"
                let text = (section.start..<section.end).map { "--- PDF Page \($0 + 1) ---\n\(pages[$0].isEmpty ? "[No extractable text; inspect original page]" : pages[$0])" }.joined(separator: "\n\n")
                try Vault.write("\(section.title)\nSource: \(relative)/Original.pdf\n\n\(text)\n", to: folder.appendingPathComponent(path))
                indexText += "- \(section.title) · PDF pages \(section.start + 1)–\(section.end): \(relative)/\(path)\n"
            }
            try Vault.write(indexText, to: folder.appendingPathComponent("Index.md"))
            return Textbook(id: id, title: title, relativePath: relative + "/Original.pdf", indexPath: relative + "/Index.md", sectionCount: sections.count, warning: warning)
        } catch {
            try? Vault.fm.removeItem(at: folder)
            throw error
        }
    }
}
