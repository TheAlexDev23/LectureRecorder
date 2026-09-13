# Lecture Recorder

A native SwiftUI macOS app for recording lectures, taking personal notes, exporting timestamped transcripts to Obsidian, and manually processing each course’s backlog through Codex.

**This Mac runs macOS 15.6.1. The app opens and records audio here, but Apple’s new SpeechAnalyzer requires macOS 26.** Upgrade macOS to use live transcription or transcribe the recordings you saved earlier. The macOS 26 path compiles against the installed Xcode 26.2 SDK; it cannot be runtime-tested on this OS.

## Open the app

Open `build/Lecture Recorder.app`. You can copy it to `~/Applications` or `/Applications` and launch it from Finder, Spotlight or the Dock. It is an ordinary locally built, ad-hoc-signed application, with no paid developer membership or provisioning profile needed for this workflow. It is not notarized for distribution. Rebuilding with ad-hoc signing can cause macOS to ask for permissions again; keep the bundle identifier and install location stable.

To rebuild:

```sh
./scripts/build-app.sh
```

Requirements: Xcode 26 or later, Apple’s compatible macOS 26 speech runtime for transcription, a microphone, and a current Codex CLI with access to `gpt-5.6-terra`. The build uses Swift Package Manager and Apple frameworks; there are no third-party app dependencies.

## First use

1. Open **Settings** (`⌘,`). Choose your Obsidian vault and a relative courses folder, such as `Courses` or `University/Courses`.
2. Check the Codex executable path. The initial value is `~/.local/bin/codex` expanded to your home directory. Run `codex login` once in Terminal if needed. The app reuses CLI authentication and explicitly chooses `gpt-5.6-terra` with medium reasoning. It does not silently substitute another model.
3. Add a course, for example `CSC263` / `Data Structures and Analysis`.
4. Choose **New Lecture**, enter its number and optional title, then **Start Recording**. Allow microphone access. On macOS 26, first use may download Apple’s language assets. If speech setup fails, audio recording can still continue; the app shows why.
5. Read finalized transcript passages on the left and type notes on the right. Attach slides, PDFs, readings, images or other files before stopping or later. **Stop & Save** finalizes speech and exports the transcript. Audio-only sessions show **Retry Transcription**.
6. Open **Processing Queue** and choose a course or **Process All Queued Courses**. This is the only action that starts Codex. Missing attachments show a warning and do not block processing.
7. Read summaries in Obsidian. Review uncertainties under **Job History & Issues**, or open the job’s logs and retained workspace. Attachments added after processing put that lecture back into the queue.

Enable Obsidian’s core **Bases** plugin to use the generated views. There are no Dataview or other community-plugin requirements.

## What to review

Read [the prompt and output walkthrough](docs/WORKFLOW.md) for the exact intended material, lecture and topic behavior, examples, report format and architecture choices. The actual prompt and JSON schema live in [AgentRunner.swift](Sources/LectureRecorder/AgentRunner.swift); each job also retains the exact `prompt.txt` it received.

## Data and recovery

- Local library: `~/Library/Application Support/LectureRecorder/library.json` (atomic JSON writes).
- Audio: `Recordings/<lecture UUID>.caf` under the same directory. Full-resolution PCM audio can take substantial disk space. Audio is not sent to Codex or copied into Obsidian automatically.
- Jobs: `Jobs/<job UUID>/` contains `Before/` (course snapshot), `Course/` (agent workspace), prompt, structured report, stdout event log and stderr log. These snapshots include materials and are retained until you remove them yourself.
- Courses are pinned to the directory selected when created. Changing Settings changes the destination for new courses; it does not silently move existing notes.
- Removing a course from the sidebar archives it. Files, recordings and lectures remain intact; restore the course in Settings.
- Interrupted recordings can be retranscribed from saved audio. Interrupted jobs become retryable failures. Nothing starts automatically on launch.
- The app prevents ordinary quitting while recording/transcription/processing is active. Force-quitting or a power loss can interrupt file publication; use the retained `Before/` snapshot if recovery is needed.
- Source transcripts, timing JSON, personal notes, original attachments and the manifest are protected from agent changes. Publication rejects deletions, changed protected files, symlinks and concurrent edits to output files. It validates the report and requires a nonempty lecture note containing the lecture UUID before marking that lecture complete. Source/link correctness is still an agent quality check, not a formal proof.
- Course jobs use a workspace-write Codex sandbox, never unrestricted execution. The prompt limits the agent to its course. This is not a filesystem read-isolation guarantee: the CLI sandbox primarily restricts writes.

## Verification and limits

`swift test` covers batch processing with a fake local Codex executable, duplicate-job prevention, surfaced issues, source block export, preservation of user edits, rejected deletions/input modifications, path traversal and symlinks, corrupt-library protection, and interrupted-recording recovery. No real model calls or credentials are used by those tests.

The macOS 26 SpeechAnalyzer code is compiled, but live recognition and hardware microphone capture need an acceptance test on the target OS. A real Codex run also needs account/model access; automated tests check the app protocol, not model quality. Unsupported attachment formats and image-only documents may require manual conversion or review; PDF text extraction is built in, while other formats depend on the agent’s available local tools.

Speech recognition is local after model asset installation. Codex processing sends the text and material content it reads to the configured OpenAI service. Speech timestamps retain Apple’s precise audio-relative ranges, including word/range timing in JSON; neither the wording nor alignment is guaranteed perfect. There is no speaker diarization, system-audio capture, audio editing, or pause/resume in this first version; recording uses the default microphone and its continuous audio clock.

## Current framework references

Verified on September 13, 2026 against official documentation and the installed SDK/CLI:

- [Apple: SpeechAnalyzer introduction and timing](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple: SpeechAnalyzer API](https://developer.apple.com/documentation/speech/speechanalyzer)
- [OpenAI: Codex non-interactive mode, JSON events and structured final reports](https://learn.chatgpt.com/docs/non-interactive-mode)
- [OpenAI: GPT-5.6 Terra model](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [Obsidian: Bases syntax](https://obsidian.md/help/bases/syntax)
