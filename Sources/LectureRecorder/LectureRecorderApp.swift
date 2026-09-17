import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.save()
        guard store?.activeWork == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Work is still active"
        alert.informativeText = "Wait for textbook imports to finish, stop the recording, or cancel processing jobs before quitting so all work can finish saving."
        alert.addButton(withTitle: "Keep Open")
        alert.runModal()
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct LectureRecorderApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Lecture Recorder") {
            ContentView().environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1220, height: 790)
        SwiftUI.Settings { SettingsView().environmentObject(store) }
    }
}
struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var addCourse = false
    @State private var newLecture = false
    @State private var queue = false
    @State private var textbooks = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Label("LECTURE RECORDER", systemImage: "waveform.circle.fill").font(.caption.bold()).foregroundStyle(.secondary).padding(20)
                List(selection: $store.selectedCourse) {
                    Section("Courses") {
                        ForEach(store.library.courses.filter { !$0.archived }) { course in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(course.code).font(.headline)
                                Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 5).tag(course.id)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: course.directory)) }
                                    Button("Remove from sidebar") { store.archiveCourse(course.id, archived: true) }.disabled(store.isProcessing(course.id) || store.recordingID != nil)
                                }
                        }
                    }
                }
                Button { addCourse = true } label: { Label("Add Course", systemImage: "plus") }.buttonStyle(.plain).padding(20)
                Divider()
                Button { queue = true } label: {
                    HStack { Label("Processing Queue", systemImage: "tray.full"); Spacer(); Text("\(store.library.lectures.filter { [.queued, .failed].contains($0.status) }.count)").monospacedDigit() }
                }.buttonStyle(.plain).padding(20)
                SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 20)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if let banner = store.banner {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(banner).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(.orange.opacity(0.1))
                }
                if let course = store.currentCourse {
                    courseHeader(course)
                    Divider()
                    HSplitView {
                        lectureList(course).frame(minWidth: 185, idealWidth: 215, maxWidth: 270)
                        if let lecture = store.currentLecture, lecture.courseID == course.id {
                            LectureView(lecture: lecture, course: course).frame(minWidth: 480)
                        } else {
                            ContentUnavailableView("Ready for your next lecture", systemImage: "waveform", description: Text("Select a lecture or start a new recording.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("A home for every lecture", systemImage: "books.vertical")
                    } description: {
                        Text("Choose your Obsidian vault in Settings, then add a course.\nRecord, take notes, and process lectures when you’re ready.")
                    } actions: {
                        SettingsLink { Text("Choose Vault") }
                        Button("Add Course") { addCourse = true }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: store.selectedCourse) { _, _ in store.selectedLecture = nil }
        .sheet(isPresented: $addCourse) { CourseSheet().environmentObject(store) }
        .sheet(isPresented: $newLecture) { LectureSheet().environmentObject(store) }
        .sheet(isPresented: $textbooks) { if let course = store.currentCourse { TextbooksView(courseID: course.id).environmentObject(store) } }
        .sheet(isPresented: $queue) { QueueView().environmentObject(store) }
    }
    private func courseHeader(_ course: Course) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.code).font(.title.bold())
                Text(course.name).foregroundStyle(.secondary)
            }
            Spacer()
            if store.recordingID != nil {
                Button("Return to Recording") {
                    if let lecture = store.library.lectures.first(where: { $0.id == store.recordingID }) { store.selectedCourse = lecture.courseID; DispatchQueue.main.async { store.selectedLecture = lecture.id } }
                }
            }
            Button { textbooks = true } label: { Label("Textbooks (\((course.textbooks ?? []).count))", systemImage: "books.vertical") }
            Button { newLecture = true } label: { Label("New Lecture", systemImage: "mic.fill") }
                .buttonStyle(.borderedProminent).disabled(store.recordingID != nil || store.busyRecording || store.isProcessing(course.id) || store.fatalStorageError)
        }.padding(22)
    }
    private func lectureList(_ course: Course) -> some View {
        List(selection: $store.selectedLecture) {
            ForEach(store.library.lectures.filter { $0.courseID == course.id }.sorted { $0.number > $1.number }) { lecture in
                VStack(alignment: .leading, spacing: 6) {
                    Text("LEC \(lecture.number)").font(.headline)
                    if !lecture.title.isEmpty { Text(lecture.title).lineLimit(2) }
                    Text(lecture.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    StatusPill(status: lecture.status, paused: store.recordingID == lecture.id && store.recordingPaused)
                }.padding(.vertical, 7).tag(lecture.id)
            }
        }
    }
}
struct StatusPill: View {
    let status: LectureStatus
    var paused = false
    var body: some View {
        Text(paused ? "Paused" : label).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
    }
    var label: String {
        switch status {
        case .needsTranscription: "Needs transcription"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .queued: "Queued"
        case .processing: "Processing"
        case .processed: "Processed"
        case .failed: "Needs attention"
        }
    }
    var color: Color { status == .recording ? .red : status == .processed ? .green : [.failed, .needsTranscription].contains(status) ? .orange : .blue }
}
struct LectureView: View {
    @EnvironmentObject var store: Store
    let lecture: Lecture
    let course: Course
    @State private var followTranscript = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(course.code) · LEC \(lecture.number)").font(.title2.weight(.semibold))
                    Text(lecture.title.isEmpty ? "Lecture workspace" : lecture.title).foregroundStyle(.secondary)
                }
                Spacer()
                if store.recordingID == lecture.id {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Label(timestamp(store.recorder.duration), systemImage: store.recordingPaused ? "pause.circle.fill" : "record.circle.fill").foregroundStyle(store.recordingPaused ? .orange : .red).monospacedDigit()
                    }
                    Button(store.recordingPaused ? "Resume" : "Pause") { store.toggleRecordingPause() }.disabled(store.busyRecording)
                    Button("Stop & Save") { Task { await store.stopRecording() } }.buttonStyle(.borderedProminent).tint(.red).disabled(store.busyRecording)
                } else {
                    StatusPill(status: lecture.status, paused: store.recordingID == lecture.id && store.recordingPaused)
                    if lecture.status == .needsTranscription {
                        Button("Retry Transcription") { Task { await store.retryTranscription(lecture.id) } }.disabled(store.busyRecording || store.recordingID != nil)
                    }
                }
            }.padding(20)
            if let error = lecture.error { Text(error).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12).textSelection(.enabled) }
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Label("TRANSCRIPT", systemImage: "text.alignleft").font(.caption.bold()); Spacer(); Toggle("Follow", isOn: $followTranscript).toggleStyle(.checkbox).font(.caption) }.foregroundStyle(.secondary).padding(16)
                    if lecture.segments.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(lecture.status == .recording ? (store.recordingPaused ? "Paused — press Resume to continue" : "Listening…") : "No transcript yet").font(.headline)
                            Text("Finalized speech appears here with audio timestamps. On macOS 15, audio is saved for transcription after upgrading.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    ForEach(lecture.segments) { segment in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(timestamp(segment.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 67, alignment: .leading)
                                            Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.id(segment.id)
                                    }
                                }.padding(16)
                            }.onChange(of: lecture.segments.count) { _, _ in if followTranscript, let id = lecture.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                        }
                    }
                }.frame(minWidth: 240, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Label("YOUR NOTES", systemImage: "square.and.pencil").font(.caption.bold()); Spacer(); Text("Autosaved").font(.caption) }.foregroundStyle(.secondary).padding(16)
                    TextEditor(text: Binding(get: { store.library.lectures.first(where: { $0.id == lecture.id })?.notes ?? "" }, set: { store.notes(lecture.id, value: $0) }))
                        .font(.body).scrollContentBackground(.hidden).padding(.horizontal, 12).disabled(store.isProcessing(course.id))
                }.frame(minWidth: 210, maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Materials", systemImage: "paperclip").font(.headline)
                    Text("\(lecture.materials.count) attached").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Attach Files…") {
                        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
                        if panel.runModal() == .OK { store.attach(panel.urls, to: lecture.id) }
                    }.disabled(store.isProcessing(course.id))
                    if FileManager.default.fileExists(atPath: store.audioURL(lecture.id).path), store.recordingID != lecture.id {
                        Button("Play Audio") { NSWorkspace.shared.open(store.audioURL(lecture.id)) }
                    }
                    if let path = lecture.transcriptPath {
                        Button("Open Transcript") { NSWorkspace.shared.open(URL(fileURLWithPath: course.directory).appendingPathComponent(path)) }
                    }
                }
                if lecture.materials.isEmpty {
                    Label("No supporting materials. Processing can proceed, but uncertainty may be higher.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    ScrollView(.horizontal) { HStack { ForEach(lecture.materials) { material in
                        Button(material.originalName) { NSWorkspace.shared.open(URL(fileURLWithPath: course.directory).appendingPathComponent(material.relativePath)) }.buttonStyle(.link)
                    } } }
                }
            }.padding(16)
        }
    }
}
struct CourseSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a course").font(.title2.bold())
            TextField("Course code, e.g. CSC263", text: $code)
            TextField("Course name", text: $name)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Create Course") { do { try store.addCourse(code: code, name: name); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction) }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 430)
    }
}
struct LectureSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var number = 1
    @State private var title = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New lecture · \(store.currentCourse?.code ?? "")").font(.title2.bold())
            TextField("Lecture number", value: $number, format: .number)
            TextField("Title (optional)", text: $title)
            Text("Recording starts when you press Start. You can attach slides and take notes while recording.").foregroundStyle(.secondary)
            if store.busyRecording { ProgressView("Preparing microphone and speech assets…") }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { dismiss() }.disabled(store.busyRecording); Spacer(); Button("Start Recording") { Task { do { try await store.startLecture(number: number, title: title); dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(.borderedProminent).disabled(store.busyRecording) }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 440)
            .interactiveDismissDisabled(store.busyRecording)
            .onAppear { number = (store.library.lectures.filter { $0.courseID == store.selectedCourse }.map(\.number).max() ?? 0) + 1 }
    }
}
struct QueueView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Processing Queue").font(.title.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Starts only when you choose. One GPT-5.6 Terra agent at medium reasoning handles each course’s complete backlog.").foregroundStyle(.secondary)
            HStack {
                Button("Process All Queued Courses") { store.processAll() }.buttonStyle(.borderedProminent).disabled(store.library.courses.allSatisfy { store.backlog($0.id).isEmpty || store.isProcessing($0.id) })
                Text("Transcripts, materials, and any textbook sections the agent reads are sent to Codex during processing.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.library.courses.filter { !$0.archived }) { course in
                        let backlog = store.backlog(course.id)
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(course.code).font(.headline); Spacer()
                                    if store.isProcessing(course.id) { ProgressView().controlSize(.small); Text("Processing…") }
                                    else { Button("Process \(backlog.count) Lectures") { store.processCourse(course.id) }.disabled(backlog.isEmpty) }
                                }
                                ForEach(backlog) { lecture in
                                    HStack { Text("LEC \(lecture.number) · \(lecture.title)"); Spacer(); if lecture.materials.isEmpty { Label("Missing materials", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }.font(.callout)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    Text("Job History & Issues").font(.title3.bold())
                    if store.library.jobs.isEmpty { Text("No jobs yet.").foregroundStyle(.secondary) }
                    ForEach(store.library.jobs.reversed()) { job in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("\(store.library.courses.first(where: { $0.id == job.courseID })?.code ?? "Course") · \(job.state)").font(.headline)
                                    Spacer()
                                    Text(job.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    if job.state == "running" { Button("Cancel") { store.runner.cancel(job.id) } }
                                    Button("Logs & Files") { NSWorkspace.shared.open(URL(fileURLWithPath: job.directory)) }
                                }
                                Text(job.message).font(.callout).textSelection(.enabled)
                                ForEach(Array(job.issues.enumerated()), id: \.offset) { _, issue in
                                    HStack(alignment: .top) {
                                        Image(systemName: issue.severity == "error" ? "xmark.octagon" : "exclamationmark.triangle").foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(issue.message)
                                            Text([issue.timestamp, issue.source].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        }.textSelection(.enabled)
                                    }
                                }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }.padding(26).frame(width: 850, height: 640)
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var courseToForget: Course?
    var body: some View {
        Form {
            Section("Obsidian") {
                HStack {
                    TextField("Vault", text: $store.library.settings.vaultPath)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { store.library.settings.vaultPath = url.path; store.save() }
                    }
                }
                TextField("University courses folder (relative to vault)", text: $store.library.settings.coursesPath)
                Text("For example: Courses or University/Courses. Existing courses keep their original directory; changing this setting affects new courses.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech & Codex") {
                TextField("Speech locale", text: $store.library.settings.locale)
                TextField("Codex executable", text: $store.library.settings.codexPath)
                Text("Model: gpt-5.6-terra · Reasoning: medium\nRun codex login once in Terminal. SpeechAnalyzer requires macOS 26 and supported hardware/language; language assets may download on first use.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local Library") {
                Button("Show Recordings, Jobs & Backups") { NSWorkspace.shared.open(store.root) }
                Text("Audio stays in Application Support. Transcripts, personal notes and material copies are saved in your course folder. Removing a course archives it in the app and keeps all files.").font(.caption).foregroundStyle(.secondary)
                ForEach(store.library.courses.filter(\.archived)) { course in
                    HStack {
                        Text(course.code)
                        Spacer()
                        Button("Restore") { store.archiveCourse(course.id, archived: false) }
                        Button("Forget…", role: .destructive) { courseToForget = course }
                    }
                }
            }
        }.formStyle(.grouped).padding(12).frame(width: 640, height: 560)
            .alert(item: $courseToForget) { course in
                Alert(
                    title: Text("Forget \(course.code)?"),
                    message: Text("This removes the course, its lectures, and its job history from Lecture Recorder. Course files, recordings, and job folders stay on disk."),
                    primaryButton: .destructive(Text("Forget Course")) { store.forgetArchivedCourse(course.id) },
                    secondaryButton: .cancel()
                )
            }
            .onDisappear { store.save() }
            .onChange(of: store.library.settings.vaultPath) { _, _ in store.save() }
            .onChange(of: store.library.settings.coursesPath) { _, _ in store.save() }
            .onChange(of: store.library.settings.locale) { _, _ in store.save() }
            .onChange(of: store.library.settings.codexPath) { _, _ in store.save() }
    }
}

struct TextbooksView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let courseID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let course = store.library.courses.first(where: { $0.id == courseID }) {
                HStack {
                    Text("\(course.code) Textbooks").font(.title2.bold())
                    Spacer()
                    Button("Done") { dismiss() }
                }
                Text("Shared across this class. Lecture notes and slides usually suffice; the agent consults textbooks only when a question remains unresolved.").foregroundStyle(.secondary)
                Text("PDF text is extracted once into chapter or section files. Books without detectable chapters use page ranges. Scanned PDFs need OCR before upload.").font(.caption).foregroundStyle(.secondary)
                if let banner = store.banner {
                    Text(banner).font(.caption).foregroundStyle(.orange).lineLimit(3).help(banner)
                }
                List(course.textbooks ?? []) { book in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.headline)
                        Text("\(book.sectionCount) extracted sections").font(.caption).foregroundStyle(.secondary)
                        if let warning = book.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button("Open PDF") { open(book.relativePath, course: course) }
                            Button("Open section index") { open(book.indexPath, course: course) }
                        }.buttonStyle(.link)
                    }.padding(.vertical, 5)
                }
                HStack {
                    Button("Upload Textbook PDFs…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.pdf]
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK {
                            let urls = panel.urls
                            Task { await store.importTextbooks(urls, courseID: courseID) }
                        }
                    }.disabled(store.isProcessing(courseID) || store.importingTextbooks.contains(courseID) || store.fatalStorageError)
                    if store.importingTextbooks.contains(courseID) { ProgressView().controlSize(.small); Text("Extracting textbook text…").font(.caption) }
                }
                Text("Available on the next manual processing run. Existing processed lectures are not automatically requeued.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 620, height: 460)
    }
    private func open(_ path: String, course: Course) {
        do { NSWorkspace.shared.open(try containedURL(path, root: URL(fileURLWithPath: course.directory))) }
        catch { store.banner = error.localizedDescription }
    }
}
