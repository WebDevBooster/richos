# Reproducible Rust builds — the proof, 2026-09-04

**Captured at `51b1d1b44ee00a9b256f556b3e9df59c2bfcd2d4` on branch `zach-opus-p2`,
one commit before this record was added.** `fresh-clone-proof.log` is the
transcript exactly as it came out; `prove.sh` is the script that produced it, so
anybody can run it again.

## What was being proven

`app/.gitignore` carried a bare `Cargo.lock` rule until this day, so neither
`app/Cargo.lock` nor `app/src-tauri/Cargo.lock` was tracked and no build of
RichOS could be reproduced. The pre-publication audit's §7 asked for four
things. Each has a numbered step in the transcript rather than an assurance.

| Asked for | Steps | Result |
|---|---|---|
| Stop ignoring the two application lockfiles | 1, 2 | `git ls-files` lists all three tracked lockfiles; `git check-ignore` exits 1, meaning no rule hides either |
| Regenerate and commit both lockfiles | 3, 6 | sha256 recorded for all three; 108 third-party packages in the app workspace, 498 in the Tauri workspace |
| Change CI build and test commands to use `--locked` | 7, 8 | `app-spine-ci` now passes `--locked` on both cargo steps; the same commands are run here |
| Confirm a second fresh clone resolves no package versions dynamically | 4, 5, 7 | `cargo metadata --locked --offline` succeeds in both workspaces, and the test run emits no `Updating`, `Locking` or `Adding` line |

`--offline` is the strong form of the fourth question. `--locked` alone proves
cargo did not *choose* to change the lockfile; `--offline` proves it never
reached the registry index at all, so the graph is fully determined by the
committed files.

Steps 8, 9 and 10 go past what was asked: a release build of the spine, a
`--all-targets` check of the whole detached Tauri workspace, and the generated
dependency inventory re-verified against the lockfile digests it claims.

## What the run also found, which was not the point of it

**Step 11 fails in a fresh clone and passes in a working checkout, and the
difference is a private sibling repository.**

`engine/scripts/publication-completeness.sh` reports:

```
1. [STALE-EXEMPTION] .publication-completeness
   INSTANCE_MECHANISMS entry
   `richos-hq/docs/briefs/norm-deletion-detection-2026-08-29-assets/tools/pubcheck.sh`
   suppresses nothing any more.
```

The exemption is at `.richos/publication-completeness`, last line. It names a
path inside `richos-hq`, which is a **private** repository. On the machine that
wrote it, `richos-hq` is a sibling checkout and the path resolves, so the
exemption suppresses something and the check is green. In a clone that has only
this repository — which is every GitHub runner and every reader — the path
resolves to nothing, the "an exemption that suppresses nothing FAILS" rule
fires, and the gate goes red for a reason that has nothing to do with the tree
being checked.

This is the same defect class the pre-publication audit recorded against
`engine/scripts/hooks/ceo-ruled.test.sh` in its §8: *"A test whose result
changes with an undeclared private sibling is not hermetic."* It is recorded
here rather than fixed because the fix is a decision about the engine's own
contract — the "an exemption that suppresses nothing fails" rule is deliberate
and load-bearing, so teaching it to tolerate an unresolvable private path is
not a one-line change to be made in passing.

It matters before the flip for one specific reason: the audit's "Checks that
passed" list records `publication-completeness.sh --root .` as passing, and that
pass is true only on the owner's machine.

## Environment

```
cargo 1.95.0 (f2d3ce0bd 2026-03-21)
rustc 1.95.0 (59807616e 2026-04-14)
macOS, aarch64-apple-darwin
```

The transcript contains absolute paths from the machine it ran on. That
exposure was reviewed and accepted before publication for verification evidence
generally; nothing here is a credential.
