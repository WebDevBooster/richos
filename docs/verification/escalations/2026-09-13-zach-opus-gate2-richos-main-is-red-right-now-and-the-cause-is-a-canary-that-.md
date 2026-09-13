# Escalation: richos main is RED right now, and the cause is a canary that is green on this machine and red in CI (Layer MT)

- id: `esc-20260913T211138Z-a854221f`
- raised: 2026-09-13T21:11:38Z
- from: zach-opus-gate2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-gate2` (branch `cc/zach-opus-gate2`)
- head: `6593048e159b59d506260db23fd1a4009e2656e9`
- state: **work-complete**
- for: lead

## The question

Who owns Layer MT's spawn-guard canary, given it passes 9/9 locally and fails in GitHub Actions on the same commit?

## What was already tried

Found while verifying the new CI turn gate: pointed at the real record it refused a turn and named engine-self-verify.yml run #171 on richos 2ed41109 (main's tip, from another landing an hour before mine). `gh run view 34779300562 --repo WebDevBooster/richos --log-failed` names one root cause: Layer MT's canary reports 'the spawn guard REFUSED a SAME-TIER override (opus-default teammate on fable: exit=2, expected 0)'. That one layer fails the whole probe, which is also what fails contract-integrity.test.sh:P case 34 in shard 7 - one defect, two red jobs. On this machine: 'bash scripts/hooks/contract-integrity.test.sh --only MT' -> passed: 9, failed: 0; and '--only base' -> 1.committed-source-passes PASS, which runs the whole probe over committed source. So it is environment-dependent, and nothing on my branch touches model-tiers or the spawn guard.

## Proceeding meanwhile

The turn gate is finished and committed on cc/zach-opus-gate2 with 25 passing canaries. Once landed, this exact failure is what would have held the turn that pushed it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260913T211138Z-a854221f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260913T211138Z-a854221f --disposition "<what you decided or did>"
