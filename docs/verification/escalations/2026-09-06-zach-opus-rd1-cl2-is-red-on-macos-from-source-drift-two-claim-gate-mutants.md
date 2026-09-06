# Escalation: CL2 is red on macOS from source drift: two claim-gate mutants no longer match, so two properties are unproven

- id: `esc-20260906T001709Z-2e884e21`
- raised: 2026-09-06T00:17:09Z
- from: zach-opus-rd1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-rd1` (branch `zach-opus-rd1`)
- head: `8715eae628d36f89d5d971e66ececaa74d1d9eb9`
- state: **work-complete**
- for: lead

## The question

Who applies the two one-line mutant-string corrections to engine/scripts/hooks/claim-roles.mutation.sh, which is inside zach-opus-mr2's declared scope while it is live in that directory?

## What was already tried

Re-derived contract-integrity.test.sh on macOS at 04307e6. Its two documented red cases both PASS here: case 54 (reconciler suite) and, expected, IN2. The suite is red at a case NOT in the recorded list: CL2.claim-gate-mutations-all-load-bearing, 18 killed / 2 survived or misfired. Both misfires are 'the mutation did not apply', which is a string that no longer exists in the source, so it is deterministic drift and not the load flake the header warns about. Reproduced identically twice standalone at load 11.03 and 7.14. Mutant no-state-block: its target moved from 12-space to 16-space indentation when an 'if pol == "positive":' wrapper was introduced; the corrected old-string is the two lines '                if v[0] == "violation":' and '                    bad_states.append((kind, sha, sentence, v[1], v[2]))', which occurs exactly once. Mutant state-claim-needs-no-verb: its target '(integrated or published)' is gone entirely, renamed to '(mi or mp)' in state_claims(); the corrected old-string is '        if not (mi or mp):' plus '            continue', which occurs exactly once. Until both are corrected the claim gate's state-violation arm and its verb requirement are NOT proven load-bearing, and the harness is correctly refusing to claim they are.

## Proceeding meanwhile

provision-claude-md.test.sh is fixed and green 37/37; IN2's fix is proven and raised separately as esc-20260905T235915Z-f3690aa9.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T001709Z-2e884e21`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T001709Z-2e884e21 --disposition "<what you decided or did>"
