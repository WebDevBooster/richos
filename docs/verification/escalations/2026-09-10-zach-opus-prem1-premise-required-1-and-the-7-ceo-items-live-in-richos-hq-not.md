# Escalation: PREMISE_REQUIRED=1 and the 7 CEO items live in richos-hq, not in the richos worktree I was given

- id: `esc-20260910T083055Z-6b532c90`
- raised: 2026-09-10T08:30:55Z
- from: zach-opus-prem1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-prem1` (branch `zach-opus-prem1`)
- head: `5a24ab4a1d29d21d8a897f1f1d58415df7907372`
- state: **proceeding**
- for: lead

## The question

Do you want a richos-hq worktree created for me (scripts/create-teammate-worktree.sh richos-hq zach-opus-prem1), or should I hand you the 7 drafted premises + the one-line .ceo-todos change for you to land in richos-hq yourself?

## What was already tried

Located the declaration and the record: /Users/alex/ab/richos-hq/.ceo-todos (PREMISE_REQUIRED=0, line 'PREMISE_REQUIRED=0') and /Users/alex/ab/richos-hq/wiki/open-items.md items 1.4, 1.5, 2.1-2.5. Confirmed by running engine/scripts/row-currency-lint.sh /Users/alex/ab/richos-hq: 'PREMISE CENSUS sections=1,2 items=8 evaluated=1 pinned=1 unstated=7' and the PREMISE-NOT-STATED note naming exactly those 7. Nothing in /Users/alex/ab/richos carries a .ceo-todos declaration, so part 1 of my brief cannot be done in the worktree I was given. I will not hand-roll a cross-repo worktree myself (CLAUDE.md: Rich creates every one) and will not write into the richos-hq main checkout while zach-opus-rec1 has a richos-hq branch open.

## Proceeding meanwhile

Part 2 (the AskUserQuestion gate, its corpus, tests and mutation harness) is entirely inside engine/ in the richos worktree and is proceeding now. I will also draft the 7 premises in full so that whichever way you answer, the landing is mechanical.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260910T083055Z-6b532c90`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260910T083055Z-6b532c90 --disposition "<what you decided or did>"
