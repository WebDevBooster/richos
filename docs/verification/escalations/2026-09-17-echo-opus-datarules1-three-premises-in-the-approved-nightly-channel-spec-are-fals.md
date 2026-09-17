# Escalation: Three premises in the approved nightly-channel spec are false as written; the data-rules slice is built and green, but point 25 inherits them

- id: `esc-20260917T133346Z-6019cf86`
- raised: 2026-09-17T13:33:46Z
- from: echo-opus-datarules1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-datarules1` (branch `cc/echo-opus-datarules1`)
- head: `476a0c504105bd99ad9a9770df6f476dce246f54`
- state: **work-complete**
- for: lead

## The question

Should the spec page be amended with these three corrections before the point-25 publisher-gate slice is briefed from it?

## What was already tried

Built all seven brief items; re-derived every file:line the spec cites (all correct) and every behavioral premise (three wrong). (1) POINT 17's assertion cannot be written: 'no shipped path inside Contents/ is owner-writable' is false of every correct macOS bundle - measured 2163 of 2163 paths owner-writable across RichOS.app, Calculator.app and Safari.app; 0 of 2163 group/world-writable. Built the group/other check plus a shipped-state-path check instead; 54/54 packaging cases pass. (2) POINT 20's recorded defect is not at the sites it names: correction.rs was fixed 2026-09-05, staging.rs never had it, and journal.rs uses split() not lines() - split yields io::Result<Vec<u8>> so a bad byte was never able to end the iterator. Wrote the brief's test first against unchanged code and it PASSED. The real defect there is worse and different: map_while(Result::ok) swallowed a genuine IO error, and an EISDIR mid-shard answered ThreadMachinery::NothingRecorded - the app telling him nothing was ever recorded about a file sitting right there. Fixed and pinned. (3) THE SEQUENCING TABLE row 2 justifies launch.rs <= with the wrong direction and this one has a product consequence.

## Proceeding meanwhile

All seven brief items landed in 8 atomic commits on cc/echo-opus-datarules1; richos-core 1104 passed / 0 failed, src-tauri 109/0, package-app.test.sh 54/54, lint-banned clean. Corrections are recorded at the source in ledger.rs's survey and in docs/architecture/data-migration.md so they cannot launder onward, but the spec page itself is unchanged - it is richos-hq and not mine to edit.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T133346Z-6019cf86`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T133346Z-6019cf86 --disposition "<what you decided or did>"
