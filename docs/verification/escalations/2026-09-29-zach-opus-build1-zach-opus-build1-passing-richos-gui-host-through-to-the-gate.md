# Escalation: zach-opus-build1: passing RICHOS_GUI_HOST through to the gates would make the nightly FAIL, not use the VM: testvm/run-suite.sh has never existed

- id: `esc-20260929T110927Z-49c07194`
- raised: 2026-09-29T11:09:27Z
- from: zach-opus-build1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-build1` (branch `cc/zach-opus-build1`)
- head: `f191e56d0ccaced19d68380801f9444481037f47`
- state: **proceeding**
- for: lead

## The question

Is the candidate's own signed bundle booted in the test VM (gui-proof-in-vm.sh, suite=shipped-bundle-boot, which publish already accepts) enough for 'the nightly puts its screen suites on the test VM', or do you also want gui-boot.test.sh itself (debug binary, checks B0-B8/C1-C5) runnable inside the guest? The second means writing testvm/run-suite.sh, which is a separate piece of work.

## What was already tried

Brief says the cause is GATE_PASSTHROUGH lacking RICHOS_GUI_HOST (nightly-local.py:769/856). That part is true. But run-tests.sh:735 only routes a host-screen suite to a guest through scripts/testvm/run-suite.sh, and that file is on no ref in the repository (git log --all -- richos/app/scripts/testvm/run-suite.sh prints nothing). With the variable passed through, run-tests.sh:744 exits 2 and gates/script-suites fails. front-door.test.sh is a declared host gap in every build anyway (it needs a published release). gui-boot.test.sh builds a debug binary with cargo from the checkout; the guest has no cargo and no repository.

## Proceeding meanwhile

Building: (1) `build` never uses the host screen by default (attempt 1 today ran gui-boot on the host display); (2) after the candidate is built, the build itself takes the VM boot proof with gui-proof-in-vm.sh, and publish finds it without --gui-proof; RICHOS_GUI_HOST, if set, names that guest; (3) the build refuses at start, in seconds, when the shell holds a RICHOS_*/RUN_TESTS_* setting it would otherwise drop before a gate. gui-boot.test.sh stays recorded NOT RUN (no screen), honestly. The README count fix is already committed (f191e56d).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260929T110927Z-49c07194`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260929T110927Z-49c07194 --disposition "<what you decided or did>"
