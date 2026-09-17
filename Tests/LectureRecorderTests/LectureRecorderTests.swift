import XCTest
import AVFoundation
import PDFKit
import CoreText
@testable import LectureRecorder

final class LectureRecorderTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testRecordingSinkAppendsAudioAndCountsOnlyCapturedFrames() throws {
        let url = root.appendingPathComponent("resume.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        var deliveredFrames = 0
        var sink: AudioSink? = try AudioSink(url: url, input: format, output: output, deliver: {
            deliveredFrames += Int($0.frameLength)
        }, failure: { XCTFail($0) })
        func capture(_ value: Float) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for index in 0..<4800 { buffer.floatChannelData![0][index] = value }
            sink!.consume(buffer)
        }
        capture(0.25)
        XCTAssertEqual(sink!.duration, 0.1, accuracy: 0.00001)
        // A pause supplies no buffers. Continuing must append, not replace prior audio.
        capture(-0.25)
        XCTAssertEqual(sink!.duration, 0.2, accuracy: 0.00001)
        XCTAssertGreaterThan(deliveredFrames, 3000)
        XCTAssertLessThanOrEqual(deliveredFrames, 3200)
        sink = nil
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.length, 9600)
        let saved = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 9600)!
        try audio.read(into: saved)
        XCTAssertEqual(saved.floatChannelData![0][0], 0.25)
        XCTAssertEqual(saved.floatChannelData![0][4800], -0.25)
    }
    func makePDF(_ pages: [String], name: String = "Book.pdf") throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 720)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16)]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    func testTextbookSegmentationCoversPagesAndBoundsReads() {
        let pages = ["Preface", "Chapter 1 Trees"] + Array(repeating: "content", count: 23) + ["Chapter 2 Graphs", "end"]
        let sections = TextbookImporter.sections(pages: pages, bookmarks: [])
        XCTAssertEqual(sections.map(\.start), [0, 1, 21, 25])
        XCTAssertEqual(sections.flatMap { Array($0.start..<$0.end) }, Array(pages.indices))
        XCTAssertTrue(sections.allSatisfy { $0.end - $0.start <= 20 })
        let fallback = TextbookImporter.sections(pages: Array(repeating: "text", count: 45), bookmarks: [])
        XCTAssertEqual(fallback.map(\.start), [0, 20, 40])
        XCTAssertTrue(fallback[0].title.contains("unavailable"))
        let bookmarked = TextbookImporter.sections(pages: pages, bookmarks: [("Second", 25), ("First", 0), ("Duplicate", 0), ("Invalid", 100)])
        XCTAssertEqual(bookmarked.map(\.start), [0, 20, 25])
    }
    func testTextbookImportExtractsPagesAndProtectsInputs() throws {
        let source = try makePDF(["Chapter 1 Trees", "Balanced trees", "Chapter 2 Graphs", ""])
        let course = Course(code: "CS", name: "Algorithms", directory: root.appendingPathComponent("course").path)
        let book = try TextbookImporter.importPDF(source, course: course)
        let directory = URL(fileURLWithPath: course.directory)
        XCTAssertEqual(book.sectionCount, 2)
        XCTAssertTrue(book.warning?.contains("4") == true)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: directory.appendingPathComponent(book.relativePath)))
        let index = try String(contentsOf: directory.appendingPathComponent(book.indexPath), encoding: .utf8)
        XCTAssertTrue(index.contains("Chapter 2"))
        let section = directory.appendingPathComponent(book.indexPath).deletingLastPathComponent().appendingPathComponent("Sections/0001.txt")
        XCTAssertTrue(try String(contentsOf: section, encoding: .utf8).contains("--- PDF Page 2 ---"))
        let baseline = try Vault.files(in: directory)
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.copyItem(at: directory, to: stage)
        try Vault.write("tampered", to: stage.appendingPathComponent(book.indexPath))
        XCTAssertThrowsError(try Vault.publish(workspace: stage, destination: directory, baseline: baseline))
    }
    func testUnreadableTextbookLeavesNoPartialImport() throws {
        let course = Course(code: "CS", name: "Algorithms", directory: root.appendingPathComponent("course").path)
        XCTAssertThrowsError(try TextbookImporter.importPDF(makePDF([""]), course: course))
        XCTAssertTrue(try Vault.files(in: URL(fileURLWithPath: course.directory)).isEmpty)
    }
    func testLegacyCourseDecodesWithoutTextbooks() throws {
        let data = Data("{\"id\":\"\(UUID().uuidString)\",\"code\":\"CS\",\"name\":\"Course\",\"directory\":\"/tmp/course\",\"archived\":false}".utf8)
        XCTAssertNil(try JSONDecoder().decode(Course.self, from: data).textbooks)
    }
    func testTraversalAndSymlinkRejected() throws {
        XCTAssertThrowsError(try containedURL("../outside", root: root))
        XCTAssertThrowsError(try containedURL("/outside", root: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try containedURL("link/outside", root: root))
        XCTAssertThrowsError(try Vault.files(in: root))
    }
    func testTimestampAndNames() throws {
        XCTAssertEqual(timestamp(3661.7), "01:01:01")
        XCTAssertEqual(timestamp(-1), "00:00:00")
        XCTAssertThrowsError(try safeComponent("../course"))
        XCTAssertEqual(try safeComponent(" CSC263 "), "CSC263")
    }
    func testTranscriptHasStableSourceBlocksAndEscapedMetadata() throws {
        let course = Course(code: "CSC263", name: "Data Structures", directory: root.path)
        try Vault.initialize(course)
        var lecture = Lecture(courseID: course.id, number: 5, title: "Trees")
        lecture.segments = [Segment(start: 12.5, end: 15.1, text: "AVL trees keep their height balanced.")]
        let path = try Vault.export(lecture, course: course)
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(text.contains("^t1")); XCTAssertTrue(text.contains("00:00:12")); XCTAssertTrue(text.contains(lecture.id.uuidString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Views/Topics.base").path))
    }
    func testPublishRejectsUserConflictBeforeAnyWrites() throws {
        let source = root.appendingPathComponent("vault"), stage = root.appendingPathComponent("stage")
        try Vault.write("original", to: source.appendingPathComponent("Topics/A.md"))
        let baseline = try Vault.files(in: source)
        try Vault.write("agent edit", to: stage.appendingPathComponent("Topics/A.md"))
        try Vault.write("new", to: stage.appendingPathComponent("Lectures/new.md"))
        try Vault.write("personal edit", to: source.appendingPathComponent("Topics/A.md"))
        XCTAssertThrowsError(try Vault.publish(workspace: stage, destination: source, baseline: baseline))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Lectures/new.md").path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Topics/A.md"), encoding: .utf8), "personal edit")
    }
    func testProtectedInputsAndDeletionRejected() throws {
        let source = root.appendingPathComponent("vault"), stage = root.appendingPathComponent("stage")
        try Vault.write("raw", to: source.appendingPathComponent("Transcripts/raw.md"))
        let baseline = try Vault.files(in: source)
        try Vault.write("modified", to: stage.appendingPathComponent("Transcripts/raw.md"))
        XCTAssertThrowsError(try Vault.publish(workspace: stage, destination: source, baseline: baseline))
        try FileManager.default.removeItem(at: stage.appendingPathComponent("Transcripts/raw.md"))
        XCTAssertThrowsError(try Vault.publish(workspace: stage, destination: source, baseline: baseline))
    }
    func testPublishValidChangesAndKeepsUnrelatedNotes() throws {
        let source = root.appendingPathComponent("vault"), stage = root.appendingPathComponent("stage")
        try Vault.write("personal", to: source.appendingPathComponent("Topics/A.md"))
        let baseline = try Vault.files(in: source)
        try Vault.write("personal", to: stage.appendingPathComponent("Topics/A.md"))
        try Vault.write("summary", to: stage.appendingPathComponent("Lectures/B.md"))
        try Vault.publish(workspace: stage, destination: source, baseline: baseline)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Topics/A.md"), encoding: .utf8), "personal")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Lectures/B.md"), encoding: .utf8), "summary")
    }
    @MainActor func testRecoveryAndArchiveAreNonDestructive() throws {
        let store = Store(root: root)
        store.library.settings.vaultPath = root.appendingPathComponent("vault").path
        try store.addCourse(code: "CSC263", name: "Trees")
        let course = store.currentCourse!
        store.library.lectures = [Lecture(courseID: course.id, number: 1, title: "", status: .recording)]
        store.save()
        let restored = Store(root: root)
        XCTAssertEqual(restored.library.lectures[0].status, .needsTranscription)
        restored.archiveCourse(course.id, archived: true)
        XCTAssertTrue(restored.library.courses[0].archived)
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.directory))
    }
    @MainActor func testForgetArchivedCourseRemovesRecordsButKeepsFiles() throws {
        let store = Store(root: root)
        store.library.settings.vaultPath = root.appendingPathComponent("vault").path
        try store.addCourse(code: "CS135", name: "Test Course")
        let course = store.currentCourse!
        let lecture = Lecture(courseID: course.id, number: 1, title: "Test")
        let audio = store.audioURL(lecture.id)
        let jobDirectory = root.appendingPathComponent("Jobs/test-job")
        try Vault.write("audio", to: audio)
        try Vault.write("job output", to: jobDirectory.appendingPathComponent("report.json"))
        store.library.lectures.append(lecture)
        store.library.jobs.append(Job(courseID: course.id, lectureIDs: [lecture.id], directory: jobDirectory.path))
        store.archiveCourse(course.id, archived: true)

        store.forgetArchivedCourse(course.id)

        XCTAssertFalse(store.library.courses.contains { $0.id == course.id })
        XCTAssertFalse(store.library.lectures.contains { $0.courseID == course.id })
        XCTAssertFalse(store.library.jobs.contains { $0.courseID == course.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDirectory.path))
        XCTAssertNoThrow(try store.addCourse(code: "CS135", name: "Real Course"))
    }
    @MainActor func testCorruptLibraryIsNotOverwritten() throws {
        let file = root.appendingPathComponent("library.json")
        try Vault.write("broken input", to: file)
        let store = Store(root: root)
        XCTAssertTrue(store.fatalStorageError)
        store.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken input")
    }
    @MainActor func testCourseBatchWithFakeCodex() async throws {
        let store = Store(root: root)
        store.library.settings.vaultPath = root.appendingPathComponent("vault").path
        try store.addCourse(code: "CSC263", name: "Trees")
        let course = store.currentCourse!
        await store.importTextbooks([try makePDF(["Chapter 1 Trees", "AVL trees"])], courseID: course.id)
        XCTAssertEqual(Store(root: root).currentCourse?.textbooks?.count, 1)
        for number in [5, 6] {
            var lecture = Lecture(courseID: course.id, number: number, title: "Trees")
            lecture.segments = [Segment(start: 0, end: 2, text: "An AVL tree is balanced.")]
            store.library.lectures.append(lecture)
            try store.exportAndQueue(lecture.id)
        }
        let fake = root.appendingPathComponent("fake-codex")
        try Vault.write(#"""
        #!/usr/bin/env python3
        import json, sys, pathlib
        args = sys.argv[1:]
        assert args[args.index('--model')+1] == 'gpt-5.6-terra'
        assert 'model_reasoning_effort="medium"' in args
        schema = json.loads(pathlib.Path(args[args.index('--output-schema')+1]).read_text())
        assert schema['type'] == 'object'
        assert set(schema['required']) == {'completedLectureIDs', 'issues', 'summary'}
        prompt = sys.stdin.read()
        assert 'PHASE 1' in prompt
        assert 'Use textbooks sparingly' in prompt
        books = json.loads(pathlib.Path('textbooks.json').read_text())
        assert len(books) == 1
        assert pathlib.Path(books[0]['indexPath']).exists()
        assert 'PDF pages 1' in pathlib.Path(books[0]['indexPath']).read_text()
        backlog = json.loads(pathlib.Path('backlog.json').read_text())
        assert len(backlog) == 2
        for item in backlog:
            p = pathlib.Path('Lectures') / ('CSC263 LEC '+str(item['number'])+'.md')
            p.write_text('---\nlecture_id: '+item['id']+'\n---\n# Balanced trees\n\nA grounded explanation with source references and enough content for validation.\n')
        report = {'completedLectureIDs':[x['id'] for x in backlog], 'summary':'Two lectures completed in one course session.', 'issues':[{'id':'warning-1','lectureID':backlog[0]['id'],'severity':'warning','message':'Missing materials; please attach slides.','timestamp':'00:00:00','source':backlog[0]['transcript']}]}
        pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(report))
        print(json.dumps({'type':'thread.started','thread_id':'fake'}))
        """#, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        store.library.settings.codexPath = fake.path
        store.processCourse(course.id)
        store.processCourse(course.id) // duplicate click must not create a second session
        let deadline = Date().addingTimeInterval(15)
        while store.isProcessing(course.id) && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(store.isProcessing(course.id))
        XCTAssertEqual(store.library.jobs.count, 1)
        XCTAssertEqual(store.library.jobs[0].state, "completed", store.library.jobs[0].message)
        XCTAssertEqual(store.library.lectures.map(\.status), [.processed, .processed])
        XCTAssertEqual(store.library.jobs[0].issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: course.directory).appendingPathComponent("Lectures/CSC263 LEC 6.md").path))
    }
    @MainActor func testInvalidAgentReportDoesNotPublish() async throws {
        let store = Store(root: root)
        store.library.settings.vaultPath = root.appendingPathComponent("vault").path
        try store.addCourse(code: "MAT137", name: "Calculus")
        let course = store.currentCourse!
        var lecture = Lecture(courseID: course.id, number: 1, title: "Limits")
        lecture.segments = [Segment(start: 0, end: 1, text: "A limit.")]
        store.library.lectures.append(lecture)
        try store.exportAndQueue(lecture.id)
        let fake = root.appendingPathComponent("invalid-codex")
        try Vault.write(#"""
        #!/usr/bin/env python3
        import sys, pathlib, json
        args = sys.argv[1:]
        pathlib.Path('Topics/invalid.md').write_text('This should never reach the vault.')
        pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps({'completedLectureIDs':['unknown-id'], 'summary':'Invalid', 'issues':[]}))
        """#, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        store.library.settings.codexPath = fake.path
        store.processCourse(course.id)
        let deadline = Date().addingTimeInterval(15)
        while store.isProcessing(course.id) && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(store.library.jobs[0].state, "failed")
        XCTAssertEqual(store.library.lectures[0].status, .failed)
        XCTAssertTrue(store.library.jobs[0].message.contains("unknown lecture IDs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: course.directory).appendingPathComponent("Topics/invalid.md").path))
    }

}
