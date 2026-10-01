# Escalation: Env-parity brief: tonight's merges never ran the merge gate, and the proof-run failure is not an environment failure

- id: `esc-20261001T021125Z-c3a494e1`
- raised: 2026-10-01T02:11:25Z
- from: zach-opus-envparity1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-envparity1` (branch `cc/zach-opus-envparity1`)
- head: `3f811bfebd58a61991aa1fb5689b70f91e9842d8`
- state: **proceeding**
- for: lead

## The question

Two premises in my brief are false. (1) The brief says each failing suite had passed the merge checks. It did not: none of tonight's merges ran the land checks. The autocheck bypass log (richos main checkout, git-common-dir richos-autocheck/bypass.log) records a8391dd8c, cfe26d6b4, 3cc968052, 256274488 and 3f811bfeb as 'main moved ... without the land checks (git commit --no-verify)', and there is no land receipt for any of their trees under richos-autocheck/land/. (2) The proof-run.test.sh failure at 25627448 does not depend on the environment. proof-evidence.test.py test_production_recipes_reject_known_shared_and_fixture_tool_omissions fails in a plain shell with no RICHOS_MUTATION_PASSES or RICHOS_FOURTEEN_MUTANTS set (19 errors, 'input qualification omits environment: RICHOS_FOURTEEN_MUTANTS, RICHOS_MUTATION_PASSES'). It is a static mismatch: d50a51860 added the two names to verification-input-qualifications.json, but the recipes in proof-inputs.json do not declare them. Any merge gate that selected proof-run.test.sh would have caught it. The gate never ran. Question for the lead: should merges keep landing with --no-verify? While they do, no merge-gate parity change can catch anything before the nightly.

## What was already tried

Reran the failing proof-evidence test on main 3f811bfe in my plain shell: it fails the same way. Reran cargo-cache-env.test.sh from 31d7e6c2 in my plain shell (TMPDIR /var/folders/.../T/, the macOS default, the same one the nightly passes through): it fails with 'path must be shorter than SUN_LEN', so a merge gate started from a default shell would have caught it too. merge-check-scope.test.sh at cfe26d6b is the one genuine environment-only failure: it fails only when RICHOS_IOS_POOL_WAIT is set, which the nightly's script-suites gate does.

## Proceeding meanwhile

Building the parity mechanism anyway, because two of the three classes are real: nightly-local.py exposes the environment its script-suites gate hands a suite (derived from the same code the gate runs), and proof-run.py applies it, including the nightly's TMPDIR shape, to every app suite it runs for the merge gate and for an engineer's proof. The proof-run replay will be reported as 'caught in any environment once the gate runs', not as an environment catch. qualify_recipe and the recipes are left to zach-sonnet-qualenv1.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T021125Z-c3a494e1`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T021125Z-c3a494e1 --disposition "<what you decided or did>"
