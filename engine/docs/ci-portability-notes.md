# CI portability notes — macOS (dev) vs. Linux (CI/adopter)

The engine is developed on macOS. `.github/workflows/engine-self-verify.yml` runs on
`ubuntu-latest`, and an adopter may run any of these scripts on Linux too.

**Everything below the "What the first execution found" section was written as an
AUDIT — a careful read of the shipped scripts, before any of them had ever run on
Linux.** On 2026-08-29 the workflow was moved to a repository-root
`.github/workflows/` and executed for the first time. Execution graded the audit.
The audit was mostly right and confidently wrong in three specific places, and
this section leads because that is the order in which the two kinds of evidence
deserve to be read.

> A read of the source tells you what a script says. Only a run tells you what it
> does. Where the two disagree, the run wins.

## What the first execution found (2026-08-29)

Reproduced locally in an `ubuntu:24.04` container (bash 5.2, git 2.43,
GNU coreutils) before the workflow was pushed, then confirmed on the real
`ubuntu-latest` runner. First result: **17 of 24 suites passed.** Seven failed,
across three distinct causes.

### 1. `BASH_CMDS` is a RESERVED variable in bash >= 4 — two hard gates misreported

`scripts/hooks/contract-integrity-probe.sh` collected the wired PreToolUse[Bash]
hook commands into an array it called `BASH_CMDS`. That is the name of **bash's
own command hash table**, and in bash >= 4.0 it is an **associative** array.
`BASH_CMDS=()` does not convert it to an indexed array, so `BASH_CMDS+=("$line")`
appends under an empty key and every element reads back as the empty string.

macOS ships **bash 3.2**, which has no such variable. The collision was therefore
invisible on the machine the engine was developed on, and the audit's
"Bash version features ... all bash >= 4 features, universally available" check
looked at the wrong end of the range: the risk here was not a feature MISSING on
an old shell, it was a name COLLIDING on a new one.

Effect on Linux: Layers **O** (Bash main-write guard) and **S** (worktree-removal
guard) found no Bash-matcher command and reported both guards **NOT WIRED** on a
checkout where both were correctly wired. Fail-closed, so nothing was let
through — but a hard gate that cries wolf on every Linux adopter is a gate people
learn to ignore. **Fixed:** renamed to `BASH_MATCHER_CMDS`, with the reasoning
recorded at the declaration so nobody renames it back. A repo-wide grep for
assignments to every other bash special variable found no second instance.

### 2. `mktemp -t <template-with-no-Xs>` — a HARD failure on GNU, not cosmetic

The audit found the `mktemp -t` BSD/GNU divergence and classified it as
"cosmetic, non-breaking". That classification held only for the templates it
looked at (`name.XXXXXX`, and the non-trailing `name.XXXXXX.py` form — both of
which GNU substitutes correctly). It missed five call sites whose template
contained **no `X` at all**:

```
mktemp: too few X's in template 'scan-secrets-codeaware'
```

BSD/macOS accepts an X-less template and appends its own random suffix. **GNU
refuses and exits 1.** The five sites, all now converted to the explicit
`mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"` form the audit already recommended:

| File | Sites | Consequence on Linux |
|---|---|---|
| `scripts/hooks/guard-workflow-ban.sh` | 3 | **A SHIPPED HOOK, not a test** — its self-test and its unadopted-repo path both died on any Linux host |
| `scripts/hooks/detect-nonnative-worktree.test.sh` | 2 | 2 ledger assertions failed; `chmod: cannot access ''` |
| `scripts/hooks/scan-secrets.test.sh` | 1 | 13 assertions failed (the whole code-aware opt-in block plus the allowlist case) |

The `guard-workflow-ban.sh` row is the one that matters beyond CI: that is
enforcement code an adopter runs, and it was broken on Linux the whole time.

### 3. A CI runner has NO git identity — and the probe degraded quietly over it

Several suites build throwaway git repositories in `$TMPDIR` and commit into
them. They deliberately do **not** set a local identity — see the comment in
`scripts/lib/resolve-roots.test.sh`, which explains that the fixtures inherit the
operator's real global identity because a machine-wide pre-commit identity guard
requires one. Every developer workstation has an identity. **`actions/checkout`
does not create one.**

With none, `git commit` inside a fixture exits 128, the fixture never gets a
branch, and the failures surface far from their cause: `resolve-roots.test.sh`
reported a worktree-normalization mismatch, `session-start-reap-worktrees.test.sh`
reported `reaped=0 skipped=1`, and `by-reference.test.sh` and
`contract-integrity.test.sh` simply exited 128 having printed every case as PASS.

The worst of it was not a failure at all. The integrity probe's **Layer Q**
downgraded to:

```
⚠ Q. FUNCTIONAL CANARY DID NOT RUN — the throwaway git sandbox could not be
     built, so nothing here proves the reaper actually reaps a clean tree or
     refuses a dirty one. Wiring and hashes are verified; BEHAVIOR IS NOT.
```

Honest, self-naming, and still exactly the shape of defect this repository spent
2026-08-29 eliminating: a check that reports something reassuring over an
assertion that never executed. **Resolved by requirement, not by patch:**
`scripts/ci-verify.sh` REFUSES to start when no git identity is visible outside a
repository, and names the two lines that fix it; both workflows declare one on
the ephemeral runner. The suites were left alone — setting a fake local identity
in the fixtures would contradict the documented reason they inherit one.

### Not a divergence, worth recording anyway

- `ps -o command= -p <pid>` (`detect-nonnative-worktree.sh`) — GNU `ps` accepts
  `command` as an alias for `args`. Works on both.
- `pgrep -f` — present and behaves the same. (`procps` is installed on
  `ubuntu-latest`; the reaper already guards with `command -v pgrep` regardless.)
- `timeout` — absent on stock macOS, present on Linux. The engine never calls it.
- The `/var` -> `/private/var` symlink physicalization is a macOS-only hazard;
  the `pwd -P` normalization that exists for it is harmless on Linux, where
  `/tmp` is already real.
- Wall-clock: the 24 suites take ~7 min on the dev Mac and are the dominant cost
  of the run. The job's `timeout-minutes: 45` is set with room, not to the mark.

### After the three fixes

**24/24 suites, install.sh, the integrity probe and `demo.sh` (7/7 beats) all
green on Linux.** See the run linked from the branch that landed this.

## What CI cannot cover, named rather than skipped

The integrity probe's **BY-REFERENCE layer set (BR1-BR10)** does not run in CI.
Those layers verify that an operator's user-scope `~/.claude` plugin registration
resolves to *this* engine — a property of a workstation, not of a repository, and
there is no honest way to synthesize it on a runner. In CI the engine is its own
subject, so the probe runs its **SEATED** layer set (A-S, plus R).

That is a stated exclusion, not a silent one, and it is not a coverage hole:
`scripts/hooks/by-reference.test.sh` builds the entire two-root by-reference
topology from scratch — plugin manifest, hook table, entity settings, a fake
`~/.claude` registration — and drives all ten BR layers through 34 negative
cases. It is discovered and run by `scripts/run-all-tests.sh`, so it runs in CI
like everything else. A suite that silently no-ops on CI is worse than one that
is honestly excluded, because it reports green over nothing.

## What the audit checked (and found clean) — still true

Grepped every shipped script (`scripts/`, `reference/`) for the classic
BSD-vs-GNU trip-wires. Everything in this section survived execution unchanged.

- **`sed -i`** — zero occurrences. (BSD `sed -i` requires a backup-suffix
  argument, even if empty (`-i ''`); GNU `sed -i` doesn't. This engine never
  uses in-place `sed` editing at all, so the incompatibility doesn't arise.)
- **`date -v` / `date -j` (BSD-only) / `gdate`** — zero occurrences. Every
  timestamp in the engine is produced by `date -u +%Y-%m-%dT%H:%M:%SZ}` (POSIX)
  or Python's `datetime`, both identical on any platform.
- **`stat -f` (BSD) vs. `stat -c` (GNU)** — zero occurrences of the `stat`
  command at all (the one grep hit was the English word "stat" inside a
  comment, not the command).
- **`pbcopy` / `pbpaste` / `osascript`** — zero occurrences (these would be
  macOS-only with no Linux equivalent at all).
- **Hashing** — every hook that needs a content hash already tries
  `shasum` (present on GitHub's `ubuntu-latest` runners via the bundled
  Perl) → falls back to `sha256sum` (GNU coreutils, present on every Linux
  distro) → falls back to a `python3 hashlib` one-liner. This fallback chain
  was already in place before B3, not added for it — confirmed by reading
  `sha256_of()` in `contract-integrity-probe.sh` and the equivalent block in
  `install.sh`. Confirmed by execution: no hashing layer failed on Linux.
- **`awk` field-separator usage (`awk -F'\t'`)** — only basic, POSIX-portable
  `-F`/`print`/pattern-action usage appears anywhere; nothing that depends on
  `gawk`-only or BSD-`awk`-only extensions.
- **Bash version features** (arrays, `${var//pattern/repl}`, `local`,
  `[[ ]]`) — all bash >= 4 features, universally available on any Linux distro
  GitHub Actions ships (`ubuntu-latest` runs a modern bash 5.x) and on modern
  macOS bash/Homebrew bash alike. **But see finding 1:** this check asked
  whether new features were available and never asked whether a chosen NAME
  collides with one the newer shell reserves. It does not generalize to
  "bash version differences are handled".
- **`git rev-parse --path-format=absolute --git-common-dir`**
  (`scripts/lib/resolve-main-checkout.sh`) — requires git >= 2.31 (Feb 2021).
  `ubuntu-latest` ships a much newer git; this is a documented minimum
  version, not a portability bug.

## The `mktemp -t` divergence in full

Every hook that needs a scratch temp file/dir uses `mktemp`. `mktemp -t
prefix` behaves **differently by design** on BSD/macOS vs. GNU/Linux:

- **BSD/macOS** (`man mktemp`, read in full): `-t prefix` builds an internal
  template from `prefix` + the platform's temp-dir convention, and treats
  any `X`s you embedded in `prefix` as **opaque literal characters** — it
  does **not** substitute them. Uniqueness comes entirely from BSD mktemp
  appending its **own** random suffix after your whole string. Verified by
  running `mktemp -d -t "name.XXXXXX"` on the dev machine: the output was
  `.../name.XXXXXX.<8-random-chars>` — the literal `XXXXXX` survived
  unchanged, with real randomness bolted on afterward. **An X-less template is
  therefore perfectly valid on BSD**, which is why five of them survived
  review.
- **GNU/Linux** (coreutils mktemp): substitutes any run of `X`s of length >= 3,
  trailing or not (`mktemp -t foo.XXXXXX.py` -> `/tmp/foo.FOU0Xy.py`, verified),
  and **hard-fails** on a template with none: `mktemp: too few X's in template`.

Both behaviors are correct on their own platform. The consequences split three
ways, and the first two were already applied before the first CI run while the
third was found BY that run:

1. **Cosmetic, fixed:** `scripts/demo.sh`'s `SAMPLE_ROOT`, whose value is
   narrated straight to the CEO running the demo. On macOS the un-fixed form
   produced an ugly double-suffixed path like
   `.../richos-engine-demo.XXXXXX.k3ryLSxK9V`. Swapped for
   `mktemp -d "${TMPDIR:-/tmp}/richos-engine-demo.XXXXXX"`.
2. **Left alone deliberately:** three internal (never user-narrated)
   scratch-file `mktemp` calls — `scripts/hooks/verify-agent-prompt.sh`,
   `scripts/hooks/scan-secrets.sh`, and `scripts/hooks/contract-integrity-
   probe.sh` each mktemp a `NAME.XXXXXX.py` file to hold an embedded Python
   script. The `X`s are **not** trailing (a literal `.py` follows them), and on
   BSD, dropping `-t` for a non-trailing `X` run performs no substitution at
   all — a real uniqueness regression. Keeping `-t` is correct on both: BSD
   appends its own suffix after the `.py`, GNU substitutes the run in place.
   Every call site invokes the file as `python3 <path>`, and Python does not
   care about the extension for direct execution. Confirmed working on Linux.
3. **A hard break, found by running:** the five X-less templates in finding 2
   above.

## Net result

The audit's headline claim — "Linux is fine" — was **directionally right and
insufficiently earned**. Three real defects survived it, one of them in shipped
enforcement code (`guard-workflow-ban.sh`) rather than in a test. All three were
found within an hour of actually executing the suites on Linux, and none of them
would have been found by reading harder.

The standing answer is no longer this document. It is the workflow: every push
re-runs all 24 suites, `install.sh`, the integrity probe and the demo on
`ubuntu-latest`. This file records what that first run cost, so the next person
tempted to grade a portability question by reading knows what that is worth.
