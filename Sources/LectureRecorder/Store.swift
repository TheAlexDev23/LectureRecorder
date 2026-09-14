import SwiftUI
import AppKit

@MainActor final class Store: ObservableObject {
    @Published var library = Library()
    @Published var selectedCourse: UUID?
    @Published var selectedLecture: UUID?
    @Published var recordingID: UUID?
    @Published var busyRecording = false
    @Published var banner: String?
    @Published var importingTextbooks: Set<UUID> = []
    @Published var fatalStorageError = false
    let root: URL
    let recorder = Recorder()
    let runner = AgentRunner()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var autosave: Task<Void, Never>?
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureRecorder")
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let file = self.root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) { library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file)) }
            for index in library.lectures.indices {
                if [.recording, .transcribing].contains(library.lectures[index].status) {
                    library.lectures[index].status = .needsTranscription
                    library.lectures[index].error = "Interrupted session. Retry transcription from the saved audio."
                } else if library.lectures[index].status == .processing {
                    library.lectures[index].status = .failed
                    library.lectures[index].error = "Processing interrupted. Review the retained job workspace, then retry."
                }
            }
            for index in library.jobs.indices where library.jobs[index].state == "running" { library.jobs[index].state = "interrupted" }
            selectedCourse = library.courses.first(where: { !$0.archived })?.id
            save()
        } catch { fatalStorageError = true; banner = "Could not load local library. Existing data has not been overwritten. \(error.localizedDescription)" }
    }
    var currentCourse: Course? { library.courses.first { $0.id == selectedCourse } }
    var currentLecture: Lecture? { library.lectures.first { $0.id == selectedLecture } }
    var activeWork: Bool { recordingID != nil || busyRecording || !tasks.isEmpty || !importingTextbooks.isEmpty }
    func save() {
        guard !fatalStorageError else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        } catch { banner = "Saving failed: \(error.localizedDescription)" }
    }
    func editLecture(_ id: UUID, _ change: (inout Lecture) -> Void) {
        guard let index = library.lectures.firstIndex(where: { $0.id == id }) else { return }
        change(&library.lectures[index]); save()
    }
    func notes(_ id: UUID, value: String) {
        guard let index = library.lectures.firstIndex(where: { $0.id == id }) else { return }
        library.lectures[index].notes = value
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
            if let lecture = library.lectures.first(where: { $0.id == id }), let course = library.courses.first(where: { $0.id == lecture.courseID }) {
                do { try Vault.exportNotes(lecture, course: course) } catch { banner = error.localizedDescription }
            }
        }
    }
    func addCourse(code: String, name: String) throws {
        guard !fatalStorageError else { throw AppFailure("Resolve the library loading error first.") }
        let code = try safeComponent(code.uppercased())
        guard code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw AppFailure("Course codes can contain letters, numbers, hyphens and underscores.") }
        guard !library.courses.contains(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) else { throw AppFailure("This course already exists. Archived courses can be restored in Settings.") }
        let settings = library.settings
        guard !settings.vaultPath.isEmpty else { throw AppFailure("Choose your Obsidian vault in Settings first.") }
        let courses = try containedURL(settings.coursesPath, root: URL(fileURLWithPath: settings.vaultPath))
        let directory = try containedURL(code, root: courses)
        let course = Course(code: code, name: name.isEmpty ? code : name, directory: directory.path)
        try Vault.initialize(course)
        library.courses.append(course); selectedCourse = course.id; selectedLecture = nil; save()
    }
    func archiveCourse(_ id: UUID, archived: Bool) {
        guard !isProcessing(id), !importingTextbooks.contains(id), !library.lectures.contains(where: { $0.courseID == id && $0.id == recordingID }) else { return }
        if let index = library.courses.firstIndex(where: { $0.id == id }) { library.courses[index].archived = archived }
        if archived && selectedCourse == id { selectedCourse = nil; selectedLecture = nil }
        save()
    }
    func forgetArchivedCourse(_ id: UUID) {
        guard let course = library.courses.first(where: { $0.id == id }), course.archived, !isProcessing(id), !importingTextbooks.contains(id),
              !library.lectures.contains(where: { $0.courseID == id && $0.id == recordingID }) else { return }
        library.lectures.removeAll { $0.courseID == id }
        library.jobs.removeAll { $0.courseID == id }
        library.courses.removeAll { $0.id == id }
        if selectedCourse == id { selectedCourse = nil; selectedLecture = nil }
        save()
    }
    func audioURL(_ id: UUID) -> URL { root.appendingPathComponent("Recordings/\(id.uuidString).caf") }
    func startLecture(number: Int, title: String) async throws {
        guard !fatalStorageError, recordingID == nil, !busyRecording, let course = currentCourse, !isProcessing(course.id) else { throw AppFailure("A recording or course job is already active.") }
        guard number > 0, !library.lectures.contains(where: { $0.courseID == course.id && $0.number == number }) else { throw AppFailure("Choose a positive, unused lecture number for this course.") }
        var lecture = Lecture(courseID: course.id, number: number, title: title)
        try FileManager.default.createDirectory(at: audioURL(lecture.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        busyRecording = true
        defer { busyRecording = false }
        library.lectures.append(lecture); selectedLecture = lecture.id; save()
        do {
            let id = lecture.id
            let warning = try await recorder.start(url: audioURL(id), locale: library.settings.locale) { [weak self] segments in
                self?.editLecture(id) { $0.segments.append(contentsOf: segments) }
            } onError: { [weak self] message in
                self?.editLecture(id) { $0.error = message }
                self?.banner = "Recording error: \(message). Stopping and preserving the available audio."
                Task { await self?.stopRecording() }
            }
            recordingID = id
            if let warning { banner = warning; editLecture(id) { $0.error = warning } }
        } catch {
            lecture.status = .needsTranscription; lecture.error = error.localizedDescription
            editLecture(lecture.id) { $0 = lecture }
            throw error
        }
    }
    func stopRecording() async {
        guard let id = recordingID, !busyRecording else { return }
        busyRecording = true
        let duration = recorder.started.map { Date().timeIntervalSince($0) } ?? 0
        defer { recordingID = nil; busyRecording = false; save() }
        do {
            try await recorder.stop()
            editLecture(id) { $0.duration = duration }
            guard let lecture = library.lectures.first(where: { $0.id == id }) else { return }
            if lecture.error != nil || lecture.segments.isEmpty {
                editLecture(id) { $0.status = .needsTranscription; if $0.error == nil { $0.error = "No speech was recognized. Retry transcription from audio." } }
            } else { try exportAndQueue(id) }
        } catch { editLecture(id) { $0.duration = duration; $0.status = .needsTranscription; $0.error = error.localizedDescription }; banner = error.localizedDescription }
    }
    func exportAndQueue(_ id: UUID) throws {
        guard let lecture = library.lectures.first(where: { $0.id == id }), let course = library.courses.first(where: { $0.id == lecture.courseID }) else { return }
        let path = try Vault.export(lecture, course: course)
        editLecture(id) { $0.transcriptPath = path; $0.status = .queued; $0.error = nil }
    }
    func retryTranscription(_ id: UUID) async {
        guard !busyRecording, recordingID == nil, let lecture = library.lectures.first(where: { $0.id == id }), !isProcessing(lecture.courseID) else { return }
        busyRecording = true
        editLecture(id) { $0.status = .transcribing; $0.error = nil }
        var fresh: [Segment] = []
        do {
            try await recorder.retry(url: audioURL(id), locale: library.settings.locale) { segments in fresh.append(contentsOf: segments) }
            guard !fresh.isEmpty else { throw AppFailure("No speech recognized. Check the saved recording and language setting.") }
            editLecture(id) { $0.segments = fresh }
            try exportAndQueue(id)
        } catch { editLecture(id) { $0.status = .needsTranscription; $0.error = error.localizedDescription }; banner = error.localizedDescription }
        busyRecording = false
    }
    func attach(_ urls: [URL], to id: UUID) {
        guard let lecture = library.lectures.first(where: { $0.id == id }), let course = library.courses.first(where: { $0.id == lecture.courseID }), !isProcessing(course.id) else { return }
        for url in urls {
            do {
                let material = try Vault.importMaterial(url, lecture: lecture, course: course)
                editLecture(id) { $0.materials.append(material); if $0.status == .processed { $0.status = .queued } }
            } catch { banner = "Could not attach \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }
    func importTextbooks(_ urls: [URL], courseID: UUID) async {
        guard !fatalStorageError, !isProcessing(courseID), !importingTextbooks.contains(courseID),
              let course = library.courses.first(where: { $0.id == courseID }), !course.archived else { return }
        importingTextbooks.insert(courseID)
        defer { importingTextbooks.remove(courseID) }
        var failures: [String] = []
        for url in urls {
            do {
                let book = try await Task.detached(priority: .utility) { try TextbookImporter.importPDF(url, course: course) }.value
                if let index = library.courses.firstIndex(where: { $0.id == courseID }) {
                    library.courses[index].textbooks = (library.courses[index].textbooks ?? []) + [book]
                    save()
                    if let warning = book.warning { failures.append("\(book.title): \(warning)") }
                }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { banner = failures.joined(separator: "\n") }
    }
    func isProcessing(_ courseID: UUID) -> Bool { tasks[courseID] != nil }
    func backlog(_ courseID: UUID) -> [Lecture] { library.lectures.filter { $0.courseID == courseID && [.queued, .failed].contains($0.status) && $0.transcriptPath != nil }.sorted { $0.number < $1.number } }
    func processAll() { for course in library.courses where !course.archived { processCourse(course.id) } }
    func processCourse(_ courseID: UUID) {
        let lectures = backlog(courseID)
        guard !fatalStorageError, !lectures.isEmpty, tasks[courseID] == nil, !importingTextbooks.contains(courseID), let course = library.courses.first(where: { $0.id == courseID }), !library.lectures.contains(where: { $0.courseID == courseID && [.recording, .transcribing].contains($0.status) }) else { return }
        let jobID = UUID()
        let directory = root.appendingPathComponent("Jobs/\(jobID.uuidString)")
        var job = Job(id: jobID, courseID: courseID, lectureIDs: lectures.map(\.id), directory: directory.path)
        job.message = "Categorizing materials, then writing notes"
        library.jobs.append(job)
        for lecture in lectures { editLecture(lecture.id) { $0.status = .processing; $0.error = nil } }
        tasks[courseID] = Task {
            defer { tasks[courseID] = nil; objectWillChange.send(); save() }
            do {
                for lecture in lectures { try Vault.exportNotes(lecture, course: course) }
                let source = URL(fileURLWithPath: course.directory)
                let baseline = try Vault.files(in: source)
                let workspace = directory.appendingPathComponent("Course")
                let backup = directory.appendingPathComponent("Before")
                for (path, data) in baseline {
                    for root in [workspace, backup] {
                        let target = try containedURL(path, root: root)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: target, options: .atomic)
                    }
                }
                var stagedCourse = course
                stagedCourse.directory = workspace.path
                try Vault.initialize(stagedCourse)
                let backlog = lectures.map { BacklogItem(id: $0.id.uuidString, number: $0.number, title: $0.title, transcript: $0.transcriptPath!, materials: $0.materials.map(\.relativePath), personalNotes: "Personal Notes/\(course.code) LEC \($0.number) - Personal Notes.md") }
                let textbookData = try JSONEncoder().encode(course.textbooks ?? [])
                try textbookData.write(to: workspace.appendingPathComponent("textbooks.json"))
                let backlogData = try JSONEncoder().encode(backlog)
                try backlogData.write(to: workspace.appendingPathComponent("backlog.json"))
                let report = try await runner.run(jobID: jobID, executable: library.settings.codexPath, directory: directory) {}
                guard Set(report.completedLectureIDs).isSubset(of: Set(lectures.map { $0.id.uuidString })) else { throw AppFailure("Agent report contains unknown lecture IDs.") }
                guard report.issues.allSatisfy({ issue in issue.lectureID.isEmpty || lectures.contains(where: { $0.id.uuidString == issue.lectureID }) }) else { throw AppFailure("Agent reported an issue for an unknown lecture.") }
                guard try Data(contentsOf: workspace.appendingPathComponent("backlog.json")) == backlogData else { throw AppFailure("Agent modified the job manifest.") }
                guard try Data(contentsOf: workspace.appendingPathComponent("textbooks.json")) == textbookData else { throw AppFailure("Agent modified the textbook manifest.") }
                try FileManager.default.removeItem(at: workspace.appendingPathComponent("textbooks.json"))
                try FileManager.default.removeItem(at: workspace.appendingPathComponent("backlog.json"))
                for lecture in lectures where report.completedLectureIDs.contains(lecture.id.uuidString) {
                    let note = workspace.appendingPathComponent("Lectures/\(course.code) LEC \(lecture.number).md")
                    guard let text = try? String(contentsOf: note, encoding: .utf8), text.count > 80, text.contains(lecture.id.uuidString) else { throw AppFailure("Agent did not produce a valid lecture note for LEC \(lecture.number).") }
                }
                try Vault.publish(workspace: workspace, destination: source, baseline: baseline)
                for lecture in lectures {
                    let completed = report.completedLectureIDs.contains(lecture.id.uuidString)
                    editLecture(lecture.id) { $0.status = completed ? .processed : .failed; $0.error = completed ? nil : "Agent did not complete this lecture. Review job issues and retry." }
                }
                if let index = library.jobs.firstIndex(where: { $0.id == jobID }) {
                    library.jobs[index].state = report.completedLectureIDs.count == lectures.count ? "completed" : "partial"
                    library.jobs[index].message = report.summary
                    library.jobs[index].issues = report.issues
                }
            } catch {
                for lecture in lectures { editLecture(lecture.id) { $0.status = .failed; $0.error = error.localizedDescription } }
                if let index = library.jobs.firstIndex(where: { $0.id == jobID }) { library.jobs[index].state = "failed"; library.jobs[index].message = error.localizedDescription }
                banner = error.localizedDescription
            }
        }
    }
}
