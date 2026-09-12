# Escalation: Six committed reviewer probe cases are obsolete premises, and only Frank and Sage can retire them

- id: `esc-20260912T132131Z-fda1ccda`
- raised: 2026-09-12T13:21:31Z
- from: zach-opus-g3
- worktree: `/Users/alex/ab/richos-wt/zach-opus-g3` (branch `cc/zach-opus-g3`)
- head: `bac187f31b705a723b5a8367ec3a90bdc8443a16`
- state: **work-complete**
- for: lead

## The question

Frank and Sage each need to say, of their own probes, which cases are retired: does frank-c3 retire floor-timing and re-record its serial-* fixture, and does sage retire S2 and S10 and re-record the S3/S9 and c2-probe fixtures?

## What was already tried

Ran every case of both c3 probes twice - as committed, and against a /tmp copy whose fixture records an integration branch, which is what point 14 requires before a first spawn. The committed probes were not modified. Output and the classifier are committed at docs/verification/workspace-probe-regression-2026-09-12-logs/. Result: floor-timing, serial-stray, serial-side, serial-rename, S3, S9 and every scenario of the c2 sage probe are red ONLY because their fixture records nothing - a premise the previous round deleted with both reviewers' approval. S2 raises TypeError because integration_record() is None, so its premise IS the deleted floor. S10's predicate was superseded by Sage's own c4 case A. outside-stray and S5 are red both ways and are out of this round's scope by the brief.

## Proceeding meanwhile

Items 0-4 are complete. Both c4 reviewer probes went from 1/6 and 4/8 to 6/6 and 8/8; the three tree probes and both frank -12 probes stay green; workspaces 58/58 with 43/43 mutants load-bearing; e2e 47/47; the three named guard suites green. Nothing merged, pushed, installed or deployed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260912T132131Z-fda1ccda`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260912T132131Z-fda1ccda --disposition "<what you decided or did>"
