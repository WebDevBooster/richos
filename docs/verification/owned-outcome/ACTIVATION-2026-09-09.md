# Claude Code owned-outcome activation, 2026-09-09

R7 and its four citation corrections were already landed at `f3f6a29b` when
activation began. Codex verified that landing instead of creating a duplicate
fix. The publication-completeness check and the R7 public evidence verifier both
pass on the stable main checkout. The reviewed adapter remains unchanged at
`e6c970d530ffbacb817a9abfef821160f56f6391a26d29a85e5a09ceda8df7db`.

## Installed configuration

The stable checkout is `/Users/alex/ab/richos`. The production engine installer
completed successfully there, refreshed matching sidecars for all three
owned-work libraries and verified its stable engine pointer and launchd
reconciler registration.

The runner was built from main with:

```sh
cargo build --manifest-path app/Cargo.toml -p richos-core --bin richos-run
```

Its SHA-256 is
`f50c2f9aaa41e93a647bda8f5f0bd20d66f12736886d4862a630130a4b50841d`.
A versioned copy is installed under the operator's local RichOS library directory,
outside disposable worktrees and Cargo build output. The real runner passed the
five scripted-transport lease checks. This is a new build of unchanged Rust
sources, not a claim that this binary reran the R7 paid trials.

Workspace installation is enabled in `richos`, `richos-hq` and `femcboost`, using
`--permission-policy native`. Each has ten owned-outcome hook entries referencing
the stable engine and a local ownership configuration referencing the installed
runner. Existing permissions and unrelated hook groups were checked unchanged.
The femcboost settings file is tracked: its installation change remains an
explicit local modification, with a private backup. Machine-specific adoption
paths were not committed into that repository.

## Verification and enrollment

Femcboost's by-reference engine integrity probe passes. The full engine probe
refuses the richos and richos-hq roots because neither declares a full-engine
`orchestration.config`; those failed probe outputs are retained. Installing the
standalone owned-outcome adapter does not enroll an unrelated full engine policy.
Its actual native SessionStart wiring is checked separately for all three roots.

All three corrected native startup checks pass: richos, femcboost and richos-hq.
Each initialized successfully, enrolled its actual native owner through the
installed SessionStart hook and exited with status zero. The probes sent zero
user messages, requested zero model turns and left no fixture processes alive.

The original initialization-only startup check looked for `request_id` at the
wrong response depth. All three actual SessionStart hooks enrolled their native
owners, but the checker reported failure after waiting for a handshake it had
misclassified. Those original false results and the original probe are retained.
The corrected probe reads `response.request_id`. No production runtime source
changed and no model turn was requested for either check.

The already-open femcboost conversation still needs its first SessionStart
capture under this installation. The CEO stated that he will restart it. Resume
the existing conversation so its actual assignment and history are captured;
a new empty session cannot invent obligations from unmanaged history. No existing user session
was killed or resumed by Codex. Terminal UI access was denied by computer-use
safety controls, and no alternate UI-control route was attempted.

Claude documents that settings changes are normally reloaded into running
sessions. That does not retroactively fire this adapter's SessionStart enrollment.
See the [settings reload contract](https://code.claude.com/docs/en/settings#when-edits-take-effect).

## Operational record

Settings backups, installer output, runner validation, failed and corrected
startup checks and exact configuration hashes are retained privately at:

`/Users/alex/.codex/artifacts/richos-owned-outcome-activation-20260909T165642Z`

The startup checks use actual Claude processes and installed workspace settings,
but redirect their ownership state to that private record. They send no user
message, request no model turn and do not enroll a production business assignment.
They are startup checks, not additional crash or completion trials. R7's original
crash results retain their original identities in [RESULTS-7.md](RESULTS-7.md).

Deferred review suggestions remain in [POST-R7-TODO.md](POST-R7-TODO.md).
