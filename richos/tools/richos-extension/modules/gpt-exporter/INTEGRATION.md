# GPT Exporter integration into RichOS Helper

Status: historical design, implemented for Helper 1.1.0. See README.md for the
current module layout and actual verification evidence. The owner confirmed that the first
integration must preserve current functionality and defaults. Preserve the manual
export workflow; automatic sync and RichOS ingestion are outside this milestone.

## Source and parity

Use the owner's standalone `/Users/alex/ab/gpt-exporter` checkout at
`3f832818` (GPT Exporter 2.2.1) as the port baseline. The copy under
`richos/engine/tools/gpt-exporter` has 18 identical tracked files; its
`export/markdown.js` differences are documentation examples only. Several source
and test-support files are absent from the bundled copy, including the test runner
and JSZip loader. Do not treat the bundled directory alone as a complete test baseline.

Keep Markdown frontmatter, conversation links, project folders/tags, stable
filenames, Unicode handling, branch trimming with the checkbox default off,
JSON export, current/new/all selection, limits, slow pacing and batch pauses.
Capture exact expected output from reviewed fixtures before moving the implementation.
Preserve license notices. Establish one maintained implementation for the integrated
module rather than two independently edited copies.

## Recommended shape

Register `chatgptExport` with the existing module registry. The Helper popup
presents Call capture and ChatGPT export as separate sections. Core settings render
the module's options. Export jobs, settings, messages, storage and errors have
their own namespace. The user's call status remains visible during an export.

Extract the formatter and selection logic before wiring authenticated requests.
Use the signed-in ChatGPT tab for export requests. Keep session tokens ephemeral
and remove raw API-response logging from the port. Grant access only to the
ChatGPT origins when enabling export. Load the exporter bridge on demand so an
always-enabled call recorder does not impose the standalone exporter's recommended
disable-after-use workflow on every ChatGPT page.

## Shared offscreen document and recording protection

Both existing extensions own an offscreen document. Helper's recorder keeps streams
and the audio graph there, while GPT Exporter creates blob URLs and ZIPs there.
They must use the core-owned document and routed handlers.

Add explicit ownership/lifetime tracking. Finishing or cancelling an export must
not close the recorder's document; recorder recovery must invalidate or retry
export work truthfully. Export ZIP generation and long fetch jobs must not block
audio writes or the watchdog. Benchmark bounded ZIP work and durable staging
before allowing a large export during a call. If measured limits require scheduling
large packaging after a call, surface that waiting state and retain the job.

Use core alerts with per-module status arbitration. Export progress must not clear
a call failure badge or masquerade as successful recording.

## Durable export jobs and completion

The standalone background worker holds export progress and fetched conversations
in memory. Persist job inputs, fetched output, cursor, next permitted request time
and pending save state so popup closure and worker eviction do not lose hours of work.
Keep deliberate pacing and pauses; resume the same job rather than refetching it
from the start.

The standalone download-completion defect was fixed in 2.2.1. The port likewise
updates incremental history only after a successful
terminal download or an acknowledged local-host write. Cancellation/interruption
retains staged files and leaves affected conversations eligible for retry.

The existing core already requires explicit user-initiated downloads. A bulk export
must preserve the existing individual-file/ZIP behavior and use a bounded explicit
save workflow rather than a stream of background Save As dialogs. Preserve the
Obsidian-compatible file/folder names; core path validation
must not silently normalize them into different names.

## Existing installation and optional RichOS ingestion

Chrome storage is scoped to the installed extension ID. Helper cannot automatically
read the standalone exporter's settings or exported-history map. Provide an explicit
export/import migration for non-secret settings/history or document that the initial
Helper export starts fresh. Preserve existing Helper storage keys so the rename
does not discard recordings or settings.

The first release preserves the existing download workflow and output formats.
RichOS ingestion is future work. The current native protocol is for call sessions;
ChatGPT files need an explicit artifact contract, path validation and write
acknowledgements before claiming automatic ingestion. Downloads and RichOS ingestion
can share the formatter without being conflated. Automatic sync is opt-in work
after manual parity and recovery are proven.

## Acceptance evidence

1. Formatter parity against reviewed standalone fixtures, including branches,
   Unicode, projects, JSON and stable filenames.
2. Browser integration for current/new/all exports, pagination, limits, token
   refresh, workspace/account changes, failed requests and deliberate pacing.
3. Cancelled/interrupted saves do not advance history; successful terminal saves do.
   Jobs recover after popup closure and worker eviction without duplicate completion.
4. Existing settings/history import and missing-native-host fallback.
5. A real two-party Zoom call while ChatGPT export runs. Independently decode both
   recorded channels, inspect recorder health, verify the exported files and confirm
   that export completion/cancellation does not stop recording or hide an incident.
6. A real signed-in ChatGPT test using agreed conversations. Mock endpoint fixtures
   cannot prove that ChatGPT's current backend still accepts the authenticated requests.

Keep the standalone tool usable during development. A release milestone is actual
export parity and coexistence evidence, not merely copying its files into Helper.

