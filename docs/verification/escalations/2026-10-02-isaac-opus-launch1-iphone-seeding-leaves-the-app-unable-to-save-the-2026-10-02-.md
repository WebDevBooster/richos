# Escalation: iPhone seeding leaves the app unable to save: the 2026-10-02 benchmark ran with a save-failure banner, and the test phone's app still cannot save

- id: `esc-20261002T073020Z-960700b7`
- raised: 2026-10-02T07:30:21Z
- from: isaac-opus-launch1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-launch1` (branch `cc/isaac-opus-launch1`)
- head: `8d08b6003a84c84f814a343f644a8c19b5b32c2e`
- state: **proceeding**
- for: lead

## The question

None needed to proceed: I will try to give the directory back to the app with devicectl copy to --user mobile (same bytes) and verify ownership; if that cannot work, the only other fix I see is a reinstall of the app, which is the CEO's call (he ruled the phone's app is never reinstalled). Please know the benchmark premise is affected.

## What was already tried

perf.py ios --device seeds and restores Library/Application Support/RichOS with `devicectl device copy to --remove-existing-content true`. Read-only `devicectl device info files` on the phone now shows that directory and its parent owned by uid 0 (root), mode 0755, while the app runs as uid 501: the app cannot create files there. Evidence: the series2 on-screen check screenshot of the benchmark run (/Volumes/E1TB/reports/2026-10-02-iphone-perf-benchmark/series2/ios-seed-iapg25an/screen-check/run/attachments/FF443876-0688-4125-907A-202218BD4E1F.png) shows the app's banner 'This iPhone could not save your latest changes. Free storage to keep your work safely.' So the benchmarked launches (cold p95 1012.6 ms, warm p95 536.0 ms) included a failed save and that banner, and the restore put the phone's own state back byte for byte but into a root-owned directory: drafts, outbox and history on the test iPhone cannot be saved until the directory is the app's again. My launch-timing lines failed for the same reason (the app wrote nothing next to the marker); the same build writes them on a simulator.

## Proceeding meanwhile

Fixing the ownership on the phone with devicectl --user mobile (same bytes), then making perf.py's seed and restore use it and check the owner, then re-measuring under a writable seeded state; the transcript and font fixes are committed (bfb8a7887, 6096d8223).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T073020Z-960700b7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T073020Z-960700b7 --disposition "<what you decided or did>"
