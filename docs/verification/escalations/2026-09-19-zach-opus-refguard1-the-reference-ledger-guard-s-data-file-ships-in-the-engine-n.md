# Escalation: The reference-ledger guard's data file ships in the engine, not in richos-hq/docs/research as the brief prescribed

- id: `esc-20260919T234138Z-882f8935`
- raised: 2026-09-19T23:41:38Z
- from: zach-opus-refguard1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-refguard1` (branch `cc/zach-opus-refguard1`)
- head: `f19e8e6643cc534e2aae7c57ff3aa254f9d923e1`
- state: **work-complete**
- for: lead

## The question

Do you want adoption-ledger.surfaces moved into richos-hq/docs/research, knowing the guard then stands down silently on any machine where that checkout is absent?

## What was already tried

Checked for a richos-hq locator in the engine: there is none. guard-row-currency-commits.sh and guard-completeness-commits.sh only MENTION richos-hq in comments; no script resolves it. I also had no richos-hq workspace in this dispatch, so the prescribed path was not writable by me.

## Proceeding meanwhile

Shipped at <engine>/scripts/hooks/adoption-ledger.surfaces with a documented three-place lookup (RICHOS_REFERENCE_LEDGER_SURFACES, <entity>/.richos/, then the engine's copy). The LEDGER DOCUMENT stays in richos-hq and is named by the data file; only the SIGNALS ship with the code that reads them, which is how every other guard datum in this engine works (ci-known-red.tsv, dialect-en-US.dict, dispatch-pretooluse.manifest). Deviation is stated in the guard's own header, not buried.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T234138Z-882f8935`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T234138Z-882f8935 --disposition "<what you decided or did>"
