# Escalation: The regression runner can be made to ignore a probe by the person failing it, and this repository's copy of the spec is missing the sentence this round implements

- id: `esc-20260912T140145Z-1991041b`
- raised: 2026-09-12T14:01:45Z
- from: sage-opus-c5
- worktree: `/Users/alex/ab/richos-wt/sage-opus-c5` (branch `cc/sage-opus-c5`)
- head: `1762240365cc36cea5f878b717c5657903c491fb`
- state: **work-complete**
- for: lead

## The question

Does a round's 'runner green' count as evidence while a file can stop being a probe by carrying one unauthored line, and which of the three copies of the workspace spec in play is the one agents are meant to read?

## What was already tried

Certified 4c70bfc2 against /Users/alex/ab/richos-hq/docs/plans/worktree-spec-2026-09-11.md. Items 1-4 hold and I re-derived each, including the consumer enumeration. Item 0: I hid a red probe from the runner twice, with matched controls, and both runs printed 'every discovered probe ran, and every one of them is green' and exited 0 -- once with '# not-a-probe: superseded elsewhere' added by the person failing it (no author check, while the documented retirement route IS author-checked), once with a probe that drives the library through sys.argv without spelling the literal 'workspaces.py'. --show-all, offered as the answer to both, names 0 of the 242 it counts. Reproduction committed: docs/verification/certification-sage-runner-round-2026-09-12-logs/hide-a-probe-from-the-runner.sh. Separately: this repository's docs/plans/worktree-spec-2026-09-11.md is missing point 14's closing paragraph -- the sentence item 4 exists to satisfy and quotes verbatim in four docstrings -- and the pin recorded in docs/verification/workspace-spec-implementation-2026-09-11.md (b3fd6cd33b8c1135) matches neither the mirror (6d190cdde551ac30) nor the canonical page (957d21a4e76262c2).

## Proceeding meanwhile

Nothing. The review is complete and committed on cc/sage-opus-c5: verdict NOT CERTIFIED, both of my red probes retired by me with reasons, and their live half carried forward as a green 10/10 replacement probe. Nothing merged, pushed, installed or deployed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T140145Z-1991041b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T140145Z-1991041b --disposition "<what you decided or did>"
