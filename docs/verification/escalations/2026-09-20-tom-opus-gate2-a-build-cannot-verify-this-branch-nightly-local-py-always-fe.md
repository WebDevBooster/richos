# Escalation: A build cannot verify this branch: nightly-local.py always fetches origin/main, so the new UI gate first runs inside a build only after it lands

- id: `esc-20260920T060720Z-ac83d300`
- raised: 2026-09-20T06:07:20Z
- from: tom-opus-gate2
- worktree: `/Users/alex/ab/richos-wt/tom-opus-gate2` (branch `cc/tom-opus-gate2`)
- head: `299a452cadfa57f4e9421a9bb7ab24d18f253bee`
- state: **work-complete**
- for: lead

## The question

Land these five commits, then run one real build on main to see the gate inside a build for the first time - or should the gate stay unexercised in a build until the next nightly anyway?

## What was already tried

The brief asked for ONE real build --no-host-screen on my branch. checkout() hard-codes a fetch of origin main and builds the fetched sha, with no override. Confirmed live: check printed Source dd6fb3050c64. That tree has no --shards flag, so a build started from my branch would run MY gate against MAIN's tree and fail with unknown argument --shards=4, a red unrelated to the gate. Instead I drove the gate end to end on my branch with a real Runner, real subprocesses and a real phase table: gates/ui-suite 583.7s, PASSED, 55/55 suites, 863 checks. I also ran check for real, exercising the new environment allowlist over ssh fetch, gh api, the keychain and runtime-verify: exit 0 in 12.3s.

## Proceeding meanwhile

All five commits are on cc/tom-opus-gate2, tests green: nightly-local.test.py 44/44 and run-tests.test.sh 28/28 including E1.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260920T060720Z-ac83d300`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260920T060720Z-ac83d300 --disposition "<what you decided or did>"
