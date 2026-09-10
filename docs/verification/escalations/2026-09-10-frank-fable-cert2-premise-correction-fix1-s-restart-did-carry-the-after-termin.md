# Escalation: Premise correction: fix1's restart DID carry the after_terminal note; round-12 hooks ran live 4.5 min after landing

- id: `esc-20260910T200459Z-f466a70e`
- raised: 2026-09-10T20:04:59Z
- from: frank-fable-cert2
- worktree: `/Users/alex/ab/richos-wt/frank-fable-cert2` (branch `cc/frank-fable-cert2`)
- head: `891f8d967acd4df1cc8ed179d70d4d780e47b450`
- state: **proceeding**
- for: lead

## The question

Nothing to decide; correct the record before it reaches the CEO: the claim that fix1's restart-detection 'snapshots into the NEXT session' and that 'this incident will not carry an after_terminal note' is FALSE. a97f2c691c34e2c0f.json carries start 19:57:02.266Z (7 ms after WorkerStarted 19:57:02.259Z) and stop 19:57:51.407Z. richos main fast-forwarded to 891f8d96 at 19:52:35Z (reflog); the plugin root is the directory source /Users/alex/ab/richos, so hook SCRIPT content is read live at each event (only hooks.json registration snapshots). The cache copy at ~/.claude/plugins/cache/.../1.0.0 has no restart code (grep -c 'RESTART AFTER TERMINAL' = 0) and did not write it.

## What was already tried

Read the transaction JSON; grep both engine copies; git -C richos reflog show main --date=iso; settings.json extraKnownMarketplaces

## Proceeding meanwhile

Round-two review continues; the finding strengthens D1's resolution and will be in the committed verdict.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T200459Z-f466a70e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T200459Z-f466a70e --disposition "<what you decided or did>"
