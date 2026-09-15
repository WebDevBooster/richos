# Installed metadata acceptance and native cleanup observation

The inactive protected release
`a5bd44263ad8b54b7a4579cb854fe7004b13ef78b5f816e6afab682a8ed31a2b`
from source `f2a2520` passed all 41 installed managed lifecycle and metadata
checks and all 24 interrupted-creation checks. Both disposable namespaces were
removed after strict attachment checks. The exact phase receipts are saved in
[managed metadata](managed-metadata-installed-2026-09-07.json) and
[interrupted creation](interrupted-metadata-installed-2026-09-07.json).

The real Claude run bound and sealed its actual native and managed members,
received SubagentStop, reclaimed the managed active image and merged its exact
delivered commit into the generated source. Its original acceptance result is
**failed** because the native assertion additionally required a recorded
WorktreeRemove event. That original result has not been relabeled as passing.

Independent read-only inspection found the native path absent, a successful
complete NUL worktree inventory containing only the canonical session checkout,
ordinary branches restored to the initial `master` baseline and the exact
Claude-owned member recorded as `removed` with `closed: platform-removed`.
No quarantine was created. Both transaction members and the transaction itself
were removed. The native cleanup correction therefore worked in this run.

The settings contained the WorktreeRemove hook but no matching event record
was captured. The wrapper writes its event record after invoking the hook, so
this evidence alone cannot distinguish non-emission from an invocation that
failed before persistence. Absence of that record must be reported separately
from actual cleanup. The acceptance correction must retain strict registry,
filesystem, transaction and branch checks, without treating missing telemetry
as proof of either success or failure.

The [original result and independent observations](claude-native-cleanup-event-assumption-2026-09-07.json)
include the installed manifest identity and root receipt path. The live
production plist, public client configuration and broker socket were each
verified absent. The canary namespace remains as evidence with no remaining
image attachments. Installed testing of the later orphan-registration changes
and the corrected complete canary is still pending.
