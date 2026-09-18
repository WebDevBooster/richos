# Escalation: Row 1 is fixed and the job now takes its turn; the very next thing it hits is that its brief never names the obligation it is working on

- id: `esc-20260918T115854Z-852c5f9c`
- raised: 2026-09-18T11:58:54Z
- from: echo-opus-worklease1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-worklease1` (branch `cc/echo-opus-worklease1`)
- head: `ddc4fbd05c01c1c53c755670bc91b8031fb00ca1`
- state: **work-complete**
- for: lead

## The question

Who owns telling the work lease its obligation_id: work_host.rs brief_for, or the work scope that richos_work already reads?

## What was already tried

Fixed Ray candidate-.8 row 1 (the work lease held an action grant over an onboarding scope nothing writes; native.rs grant list and mcp_config were not role-gated). Reproduced it at the production seam and probed both ways. Then ran the whole flow for real on a work lease against a real claude, a real delivered runtime, the real engine tree and a real ECS obligation. It now reaches Running at t+2.486s on the back end's own first stream item, with work_session written down. All three of Ray's failures were at 6.280s, 8.639s and 6.317s with work_session null, so that class is cleared. What it then hit, from captured evidence: brief_for (work_host.rs:1601-1610) tells the back end the repositories and the title and never the obligation id. The back end called richos_work.inspect first, still invented obligation_id 'obl-add-notes-line' where the real one was 'qa-notes-line', and mcp__richos_work__prepare refused it in 8 ms with 'item is absent or outside the active scope'. No work receipt was ever written. The turn then ended and the settle reading wrote 'The work connection's records could not be read, so this counts as still running' at t+350.207s, so the assignment sits in Running indefinitely and NO notice reaches the CEO. That silent hang is worse for him than a failure card. It is outside my brief (rows 1, 8, 9) and the fix lands in work_host.rs, which echo-opus-screenwait1 is in.

## Proceeding meanwhile

Rows 8 and 9 are done and committed. Row 8 split: the truncated-title collision was live and is fixed; the 'cognition io:' half was already fixed on main at 8926fd93 (09:24:43Z, after the binary Ray walked was built), so that half is a stale assertion and needs no work. Record and commits on cc/echo-opus-worklease1.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T115854Z-852c5f9c`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T115854Z-852c5f9c --disposition "<what you decided or did>"
