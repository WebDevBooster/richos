# Escalation: run.sh --engine has never worked: the engine lands one directory too deep, which is why .7 and .8 both reported 'the guest has no engine'

- id: `esc-20260920T065307Z-e3d64f90`
- raised: 2026-09-20T06:53:07Z
- from: ray-opus-vm9
- worktree: `/Users/alex/ab/richos-wt/ray-opus-vm9` (branch `cc/ray-opus-vm9`)
- head: `b5007ab08cb5ca39616a686e72ed82bf825e25e1`
- state: **work-complete**
- for: lead

## The question

Who fixes run.sh's tar to add --strip-components 1, and does the heavy-window gate get a load-average condition before the next timing walk?

## What was already tried

Reproduced in the guest: tar -tzf richos-engine-1.2.0.tar.gz | awk -F/ '{print $1}' | sort -u prints exactly 'engine', and run.sh untars with -C $PAYLOAD/engine and no --strip-components, so $RICHOS_ENGINE_DIR contains only engine/ and setup.rs::engine_looks_valid fails. Lifted it by hand, relaunched, and the app logged 'first-run setup: nothing missing.' The Mac-to-phone walk then completed with six real model turns.

## Proceeding meanwhile

The full audit is committed on cc/ray-opus-vm9: Mac-to-phone reply under a second on all five turns, phone-to-Mac 689.3 ms, and a HIGH finding that the CEO's own typed message takes 1.3-6.1 s to reach the phone. The host's Claude login survived the run.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T065307Z-e3d64f90`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T065307Z-e3d64f90 --disposition "<what you decided or did>"
