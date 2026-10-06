# Escalation: HOST_CAPACITY 1000: the value lives in richos-hq, not on my richos branch, so the one-line profile edit is not mine to commit

- id: `esc-20261006T101600Z-f8c504da`
- raised: 2026-10-06T10:16:00Z
- from: echo-opus-fbcopy
- worktree: `/Users/alex/ab/richos-wt/echo-opus-fbcopy` (branch `cc/echo-opus-fbcopy`)
- head: `1d0808314a45618cf64699f8cdc67683caf65696`
- state: **proceeding**
- for: lead

## The question

Who changes richos-hq/docs/operations/richos-connect-deployment.json line 6 from "capacity": 10 to "capacity": 1000 before the Worker redeploy? My workspace is richos only, and writing the richos-hq main checkout is off-limits to me.

## What was already tried

On cc/echo-opus-fbcopy the code no longer clamps capacity at 10 (connect-worker.mjs configured(), cli/connect.mjs managedArtifact). connect-service.test.js now asserts managedArtifact({capacity:1000}) uploads HOST_CAPACITY=1000 and a Worker bound with HOST_CAPACITY=1000 serves requests (main's clamp answers 503 there). 16/16 pass. The private profile is the only place the live number is set: managed-artifact copies profile.capacity into the HOST_CAPACITY binding.

## Proceeding meanwhile

Finishing items 3, 6 and 7. The redeploying Zach teammate can make the profile edit in its richos-hq workspace in the same pass (edit, managed-artifact, upload).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261006T101600Z-f8c504da`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261006T101600Z-f8c504da --disposition "<what you decided or did>"
