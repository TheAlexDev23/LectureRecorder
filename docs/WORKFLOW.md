# Prompt, Obsidian output and design decisions

The app records locally, publishes finalized source transcripts into your chosen course folder, and queues them. Nothing in the queue triggers an agent until you press a processing button.

## What each course agent is told

There is one Codex process per course per manual run, using `gpt-5.6-terra` at `medium`. All queued or retryable lectures in that course are listed in `backlog.json`, sorted by lecture number. The same agent handles all three phases below without delegation. Multiple selected courses run independently. Clicking Process twice cannot start two agents for the same course.

A separate immutable `textbooks.json` manifest lists class textbooks and their section indexes. The app extracts text once at upload using PDFKit and segments it by bookmarks, detected chapter/part headings, or labeled page ranges (maximum 20 pages per section). The agent consults these only for questions unresolved by lecture materials, reads relevant sections sparingly, and cites PDF pages for clearly labeled supplemental information. Textbooks are excluded from the mandatory attachment categorization phase.

Each backlog entry contains the lecture UUID, number, optional title, transcript path, attached material paths and personal-note path. The transcript frontmatter supplies the date. The agent sees a snapshot of the whole course, including prior topic notes, so it can build concepts across lectures.

The instructions are defined verbatim in `AgentPrompt.instructions` in `Sources/LectureRecorder/AgentRunner.swift`. Every job saves that exact text in `prompt.txt`. The key instructions, in execution order, are:

1. **Organize materials first.** Inspect every attachment for the full backlog. Identify slides, readings, assignments, examples, images or miscellaneous material. Preserve originals in `Materials/Inbox`, make descriptively named categorized copies, and write `Materials/Material Index.md` before drafting summaries. Document unreadable material rather than guessing what it says. PDF text sidecars include page numbers.
2. **Write grounded lecture and topic notes.** Read transcripts and useful materials, use personal notes only as secondary context, and create one lecture note per completed lecture. Reuse course-prefixed topic notes across lectures. Cite transcript block IDs and material pages. Preserve useful existing notes and personal edits. Update the course map and keep the Bases views usable.
3. **Check and report.** Check links, sources and completed files. Flag ambiguous speech, conflicting sources, missing attachments, extraction problems and other errors. Put unresolved academic uncertainties in note callouts as well as the app’s structured report. Do not invent transcript corrections, quotations, timestamps, page numbers or instructor intent. Only report a lecture as completed if its note is actually written.

Source files and attachment text are explicitly treated as data, not instructions. The agent is told not to browse the network, install tools, execute attachment code, modify original inputs, delete files, or access unrelated courses.

The launch is equivalent to:

```sh
codex exec --ignore-user-config --skip-git-repo-check \
  --sandbox workspace-write \
  -c 'approval_policy="never"' \
  -c 'model_reasoning_effort="medium"' \
  --model gpt-5.6-terra --json --color never \
  --output-schema report.schema.json \
  --output-last-message report.json - < prompt.txt
```

The app passes arguments directly to `Process`; filenames and user inputs are not interpolated into a shell command. The CLI authentication is reused, but user configuration is ignored to keep this workflow’s model, sandbox and reasoning choices predictable. Installed CLI versions must support these options; a launch failure appears in job history with stderr details.

## Intended vault layout

```text
Courses/
└── CSC263/
    ├── CSC263.md
    ├── Transcripts/
    │   ├── CSC263 LEC 5 - Transcript.md
    │   └── CSC263 LEC 5 - Timing.json
    ├── Lectures/
    │   └── CSC263 LEC 5.md
    ├── Topics/
    │   ├── CSC263 - AVL Trees.md
    │   └── CSC263 - Tree Rotations.md
    ├── Materials/
    │   ├── CSC263 L005 - Slides.pdf
    │   ├── Material Index.md
    │   └── Inbox/<lecture UUID>/<attachment UUID>-original.pdf
    ├── Textbooks/<book UUID>/
    │   ├── Original.pdf
    │   ├── Index.md
    │   └── Sections/0001.txt
    ├── Personal Notes/
    │   └── CSC263 LEC 5 - Personal Notes.md
    └── Views/
        ├── Lectures.base
        └── Topics.base
```

Original attachments enter the real vault immediately when attached. **Categorization and summaries happen in the course working copy**, with categorization first; both are published together after validation. This is a deliberate adjustment to the “save categorized material before summaries” wording: the agent has the categorized files before writing, but half-finished categorization does not appear in your live vault during a failed run. The job workspace remains available for inspection even if processing fails.

The extra `Personal Notes` directory separates your writing from the immutable machine transcript. Timing JSON preserves the fractional-second audio ranges supplied by Apple, including attributed word/range timing. Markdown shows readable `HH:MM:SS` passage timestamps and stable block IDs. The UI shows finalized passages, rather than revising individual words as you read.

## Example lecture output

This is an illustrative format, not a claim that these lecture statements or slide pages exist in your materials:

```markdown
---
type: lecture
course: CSC263
lecture: 5
lecture_id: "<actual lecture UUID>"
date: 2026-09-14
status: needs-review
topics:
  - "[[CSC263 - AVL Trees]]"
  - "[[CSC263 - Tree Rotations]]"
materials:
  - "[[CSC263 L005 - Slides.pdf]]"
tags: [university/lecture]
---
# CSC263 LEC 5 — AVL Trees

[[CSC263]] · [[CSC263 LEC 5 - Transcript]]

## Overview
The lecture connects binary-search-tree height to operation cost, then
introduces AVL balance and rotations.

## AVL balance
A node’s subtree heights differ by at most one. The height convention
used in this course should be stated here, with a source.

Source: [[CSC263 LEC 5 - Transcript#^t12]]

## Rotations
Explain the applicable rotation, why it preserves search ordering,
and the example that actually appears in the supplied sources.

See [[CSC263 - Tree Rotations]].
Material: [[CSC263 L005 - Slides.pdf#page=8]]

> [!warning] Check the deletion example
> The transcript is ambiguous at 00:42:18, and the supplied slides do not
> resolve which ancestor the instructor meant. Review the recording.

## Review questions
- Why does the balance invariant bound the height?
- Which subtree heights change after a rotation?
```

A topic note such as `CSC263 - AVL Trees.md` should consolidate the definition, invariant, operations, complexity, related concepts and source links from all contributing lectures. It should not repeat a separate full summary for each lecture. Later lectures can extend the same topic note while preserving your edits.

The course map should link lectures and important topics and embed the two `.base` files. The Bases filter on `type` and `course`; notes appear automatically through their properties. Wikilinks create backlinks and graph connections. Transcript block references let you navigate from a summary claim to the original passage. Material page links point directly into PDFs where supported by Obsidian.

## Error report and app behavior

The final output must match a JSON schema. A typical report is:

```json
{
  "completedLectureIDs": ["<actual lecture UUID>"],
  "summary": "Completed lecture 5 and updated two shared topics.",
  "issues": [
    {
      "id": "lec5-unclear-deletion",
      "lectureID": "<actual lecture UUID>",
      "severity": "warning",
      "message": "The deletion example is unclear. Review the audio near 42:18.",
      "timestamp": "00:42:18",
      "source": "Transcripts/CSC263 LEC 5 - Transcript.md"
    }
  ]
}
```

Course-wide issues use an empty lectureID. Unknown lecture IDs cause validation failure. Completed lectures become Processed even when they have review warnings; warnings remain visible in job history. Lectures omitted from the completion list become retryable failures. An invalid report, CLI failure, source modification or publication conflict leaves the whole run unpublished and the lectures retryable. Failed or cancelled jobs preserve their logs, workspace and original snapshot.

Missing materials also produce a local queue warning before any model call, so you do not have to wait for the agent to notice. Attaching a material to a processed lecture requeues it; rerunning the course then updates its notes with the added evidence.

## Architecture choices

| Choice | Reason and consequence |
| --- | --- |
| SwiftUI with small AppKit bridges | Native windows, menus, Settings, file pickers and a simple `.app` bundle. No Electron or local web server. |
| Swift Package Manager plus a packaging script | Build locally without provisioning or a generated Xcode project. Open `Package.swift` in Xcode if desired. |
| macOS 15 UI, macOS 26 speech gated by availability | This Mac can use the app now for recording; upgrading unlocks the requested speech engine. No silent substitution with legacy/cloud transcription. |
| AVAudioEngine and PCM CAF recording | Continuous audio clock, saved while recording, format conversion for Apple speech. Files are larger than compressed audio. |
| Finalized speech passages and detailed timing JSON | Readable live transcript plus precise source timing; no guarantee of perfect recognition or alignment. |
| Atomic JSON library | Small single-user data model, easy inspection and recovery. No database service or sync account. |
| Course-scoped processing copies with original snapshots | One course job cannot publish another course’s files; failed runs retain recoverable work. This costs extra disk space. |
| Manual processing; one process per course | Matches your backlog policy and keeps model use under your control. Multiple course processes can run at once. |
| Categorize then summarize in the same agent session | Material context is available before summarization, without a second independent agent losing context. |
| Core Obsidian properties, links, callouts, math and Bases | Portable Markdown with useful built-in navigation and views. No community plugin setup. |
| Persistent original material copies and PDF text extraction | Preserve provenance, enable page citations, and make common slides readable. Unreadable formats must be reported. |
| Archive instead of deleting courses | “Remove course” is reversible and does not destroy lecture recordings or vault notes. |
| Explicit CLI model and medium reasoning | Keeps the requested model stable. Authentication/model-access failures are shown rather than triggering a fallback. |

## Remaining acceptance checks

The code compiles against Xcode 26.2. Automated tests exercise local storage and a fake two-lecture Codex job. Before relying on it for a full lecture, test a short microphone session and a real Codex run; after upgrading to macOS 26, verify live speech, stop/finalization and retry from an existing audio file with your chosen locale. Neither a live macOS 26 speech session nor a paid Codex run was performed while building this version.

Publication preflights all changed files and rolls back ordinary write errors. A power loss or force quit during the final multi-file write can still leave a partial publication; the retained `Before/` copy is the recovery source. Agent preservation of existing personal edits is a prompt requirement, while preservation against concurrent external edits is enforced by byte comparisons. A successful model response does not prove every academic claim or citation is correct.

## Math and CS notation

The agent is explicitly encouraged to use Obsidian's MathJax/LaTeX notation for formulas, asymptotic bounds, recurrences, matrices, sets, invariants, proofs and derivations. Inline math uses one dollar sign on each side (`$T(n) = O(n \log n)$`); display math uses double dollar signs on their own lines:

```markdown
$$
\begin{aligned}
T(n) &= 2T(n/2) + n \\
     &= O(n \log n)
\end{aligned}
$$
```

That example assumes the usual constant base case and the relevant recurrence conditions; the agent must state assumptions from the actual lecture. Generated equations are not wrapped in code fences (the fence above just illustrates Markdown). The agent must explain notation, cite formula/proof sources and flag uncertain spoken symbols instead of guessing. Parenthesis/bracket LaTeX delimiters are excluded in favor of Obsidian's dollar-sign syntax. See [Obsidian's official math documentation](https://obsidian.md/help/advanced-syntax).
