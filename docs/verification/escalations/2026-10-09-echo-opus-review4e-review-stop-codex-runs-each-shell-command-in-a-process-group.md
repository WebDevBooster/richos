# Escalation: Review stop: Codex runs each shell command in a process group of its own, so one group kill does not end the whole chain (measured)

- id: `esc-20261009T054753Z-400c68b3`
- raised: 2026-10-09T05:47:53Z
- from: echo-opus-review4e
- worktree: `/Users/alex/ab/richos-wt/echo-opus-review4e` (branch `cc/echo-opus-review4e`)
- head: `9cd131c4b826188d3b129a49400e26b2454b681c`
- state: **proceeding**
- for: lead

## The question

Should a review stop also end the reviewer's own tool commands? The fix with no window: SIGSTOP the review's group, wait until it is stopped (it can no longer fork), read the process table once for the groups below it, then end all of them. That is about 20 lines in review_watch.stop_all. Or is a leftover tool command that runs to its own end acceptable?

## What was already tried

Built the brief's design on cc/echo-opus-review4e (5f8083139): the reviewer stays in second-review's process group and the scans are gone. The reviewer's fork race is closed (W18 red on b5ff41f02, green here). Then I measured the real Codex (codex-cli 0.162.0-alpha.2). (1) In a real review, codex-code-mode-host and each command Codex ran (the reviewer's python fixtures) ran with pgid equal to their own pid, outside the review's group. (2) Probe: an isolated, ephemeral codex exec told to run `sleep 45`. SIGTERM to the codex group gave codex rc=-15, but its sleep (own group) was still running 2 s later. Codex does not end its shell commands when it is stopped. So on a quit, a supersede or an overrun, a command the reviewer is running (for example a cargo test) runs to its own end. The removed scans reached such a command when it existed at their read. The Claude reviewer (the app's) was not measured.

## Proceeding meanwhile

The handover is committed without it, and the report states the gap plainly.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261009T054753Z-400c68b3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261009T054753Z-400c68b3 --disposition "<what you decided or did>"
