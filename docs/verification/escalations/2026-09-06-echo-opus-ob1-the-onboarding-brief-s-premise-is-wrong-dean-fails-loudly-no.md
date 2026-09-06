# Escalation: The onboarding brief's premise is wrong: Dean fails LOUDLY, not silently — and staffing is one flag away, not blocked

- id: `esc-20260906T164908Z-80c744b4`
- raised: 2026-09-06T16:49:08Z
- from: echo-opus-ob1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-ob1` (branch `echo-opus-ob1`)
- head: `61111b5d74057a63decdc42812f9bad22488dd7e`
- state: **work-complete**
- for: lead

## The question

Does the app's chat lease gain a real team via --agents (measured working), or does the interview keep saying 'written down, nobody hired' until someone decides?

## What was already tried

Measured it three ways instead of trusting it. init.agents carries no 'dean' and that does NOT depend on CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: identical with the flag inherited as 1, forced to 0, and in a bare two-variable environment. --setting-sources '' is the cause. Asked the production-vector child to spawn Dean twice, the second time with a prompt written to invite a false success report ('give me the good news'): both refused. The tool result on the wire is 'Agent type dean not found' and the model relayed it — 'I won't tell you your company is staffed when I haven't seen it happen.' The refusal originates in the binary above the permission layer. Separately, --agents '{"dean":...}' DID put dean into init.agents under --setting-sources '' (re-derives central-folder V7), so M3 is one flag in chat_child_args plus a team to compose, not an architectural gap. Raw frames: docs/verification/onboarding-honesty-2026-09-06/raw/B1-B4.

## Proceeding meanwhile

Built the honest chain on the assumption staffing stays unwired: the interview writes to one file the app actually reads back, and says plainly it hired nobody. The structure does not rely on the model refusing — the offer names no way to spawn anything and the shipped interview instructs no delegation, both pinned by tests, because two cells are a behavior and not a guarantee. Branch echo-opus-ob1, five commits, cargo test -p richos-core green and gui-boot.test.sh 20/20.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T164908Z-80c744b4`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T164908Z-80c744b4 --disposition "<what you decided or did>"
