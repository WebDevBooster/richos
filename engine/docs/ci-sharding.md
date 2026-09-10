# The full verification pass runs where nobody is waiting for it

**2026-09-10.** `engine-self-verify` was a single job that took **123 minutes** and had not
fired on a push since 2026-09-01. This document is why it now fires on every push, what had
to exist first, and what each measurement here was measured with — every number below carries
the command or the run id that produced it.

> A read of the source tells you what a script says. Only a run tells you what it does.
> Where the two disagree, the run wins. — `ci-portability-notes.md`

## The state that had to be changed, measured rather than recalled

| Fact | How it was obtained |
|---|---|
| The workflow object is **`active`**, id 345224407 | `gh workflow list --all --repo <owner>/richos` |
| Only `push:` and `pull_request:` were missing from the YAML | read of the file at `4f01e5c7` |
| **95 of 98** pushes to `main` in the event feed had **no run at all** | `scripts/ci-run-record-check.sh --repo <owner>/richos --workflow engine-self-verify.yml` |
| The last full pass took **123.5 min** and was **117/121** | run `34396549904`, 2026-09-09, `workflow_dispatch` at `1bd9f688` |
| Four units were red in it | that run's own summary |
| **101 of 120** suites were created in the previous twelve days, 35 in one day | `git log --diff-filter=A` over `*.test.sh` |

The last row is the one that decided the design. **The problem is inflow, not a red list.** At
roughly eight new suites a day, none of them ever run on Linux before landing, fixing today's
four buys exactly one green run.

## What exists now

### 1. A fast gate that matches the inflow — `affected`

`scripts/ci-affected-units.sh` maps a diff to the units it can affect and the `affected` jobs
run those, sharded. A guard-plus-suite diff is two to five minutes, on Linux, on the push that
introduces it — so a new suite gets its first Linux execution from the person who wrote it,
while they still have the context to fix it.

The mapping is four rules, in order: the path IS a suite; a sibling `<stem>.test.sh` exists; a
suite NAMES its basename (`grep -lF`); the sectioned suite's individual SECTIONS name it.

**The third rule carries the mapping, and its premise was verified before being relied on:**
all 96 files under `scripts/hooks/` are named by at least one suite. That is not left as a
remembered fact — `ci-affected-units.test.sh` case **A5** re-derives it on every run and fails
the moment it stops being true.

**An unmapped executable is a failure, and that is the point.** The dangerous case is not a
diff that maps to too much; it is one that maps to NOTHING, because the gate then certifies
the push against an empty set. A changed `.sh`/`.py` that no suite names is named and, under
`--strict`, fails. The remedy is never "add it to an exclusion list here" — the list would
BE the untested surface. Give it a suite, or make a suite name it.

**The worst case was stated, and then the first real push produced it.** A change to the shared
fixture at the top of `contract-integrity.test.sh` maps to all 24 of its sections; the commits
in this very branch touch `contract-integrity-probe.sh`, which that suite's preamble names, and
they pull in `reconcile-terminal-worktrees.test.sh` at 940 s besides. Run `34422722682`, pushed
2026-09-10, selected **54 units costing ~100 minutes serial** — and the `affected` job was one
job with a 60-minute timeout. It would have been killed.

**So the affected set is sharded too, by the same planner.** `ci-units.sh --units-file` restricts
the inventory to a set of ids and packs exactly those; `ci-shard.sh --units-file --shard i/N`
runs shard *i* of it. Same discovery, same weights, same longest-first packing, same
determinism — the diff-scoped gate and the full pass are one mechanism at two scopes rather than
two that have to be kept in step. The same 54 units now pack into twelve shards whose longest is
940 s: **15.7 minutes, and the longest shard is exactly the largest indivisible unit**, so the
packing is not the limit.

The matrix carries only shards that HAVE units, so a two-unit diff is two small jobs rather than
twelve, ten of which would have nothing to run — and a shard that verifies nothing must never
exit 0.

**An id in the restriction that is not a unit is FATAL** (`ci-units.test.sh` case U13). A
restriction that silently dropped one would plan over less than it was asked for and still exit
0, which is this document's whole subject wearing a diff filter.

`affected-coverage` then proves the affected shards covered exactly the set the diff selected —
checked against the RESTRICTED plan, never the whole inventory, which would report 94 false
absences and teach everyone to ignore the job. `ci-shard.test.sh` case S17 checks both
directions: the restricted plan certifies, and the same receipts against the whole inventory
correctly fail.

**`affected-coverage` is the job to mark required**, not `affected`. It is the one that both
waits for every affected shard and proves the union, and it is the only one of the two that
still reports on a docs-only diff, where `affected` is correctly skipped and the absence of a
required check would otherwise leave the commit ungated.

### 2. The full pass, sharded, with its coverage PROVEN

`scripts/ci-units.sh` derives the inventory; `scripts/ci-shard.sh` runs a shard of it.

**A unit is not a suite.** Sharding buys nothing past the largest indivisible unit, and one
suite dominated everything:

| unit | Linux, run `34396549904` |
|---|---|
| `scripts/hooks/contract-integrity.test.sh` | 2335.9 s (39 min) |
| `scripts/reconcile-terminal-worktrees.test.sh` | 939.7 s (16 min) |
| the other 119 suites together | 4133.4 s |

`contract-integrity.test.sh` already takes `--only <section>` and carries 24 sections, so it
contributes **24 units** instead of one. That moves the floor from 39 minutes to
`reconcile-terminal-worktrees` at 16, which is a verdict somebody will wait for. Twelve shards
sit below that floor already, so **more shards cannot improve the wall clock**.

**A scoped section is green at exit 3, and its exit 0 is a FAILURE.** That suite exits 3 when
scoped-and-green precisely so nothing can read a partial run as a full one. The shard runner
therefore expects 3 — and treats 0 as `SCOPE-LOST`, because 0 from a scoped invocation means
the `--only` selector did not apply and the unit ran something other than what its id says.

**Sharding introduces a failure the serial runner never had: a shard that runs FEWER units
than it was given still exits 0.** A selector that stopped matching, a matrix entry that never
started, a job stopped by a concurrency rule — each is a green tick over an unverified commit,
and twelve green jobs is not the same claim as "121/121". So every unit writes a **receipt**
(unit id, exit code, verdict, wall clock, shard, **and the commit**), and the `coverage` job
refuses unless:

- the union of units run **equals** the planned inventory exactly — a missing one is named, an
  unplanned one is named;
- every receipt carries the **same commit**, so a union across two trees certifies neither;
- no unit is duplicated;
- and every verdict is green.

`ci-shard.test.sh` proves each of those by execution, including S11 (drop one receipt → the
unit is named) and S14 (no receipts at all → refuse rather than certify a plan against
nothing).

**The leak canary is not lost.** `run-all-tests.sh` takes a per-suite baseline so a suite that
writes outside its sandbox is NAMED rather than bisected — the 2026-09-05 `escalations.test.sh`
finding. `ci-shard.sh` takes the same per-unit baseline through the same
`lib/leak-canary.sh`; case S15 proves it fires.

**`run-all-tests.sh` was not modified.** The sharded reading is a second, independent
implementation of the same discovery rule, and `ci-units.test.sh` case **U1** asserts by
execution that its suite set is byte-identical to `run-all-tests.sh --list`. A shared helper
would have made them agree by construction, and then nothing would have noticed when one
started missing a directory.

### 3. A check for runs that never happened — `engine-run-record.yml`

Every other check asks "did it pass?". This one asks "did it RUN?"

GitHub Free allows **20 concurrent jobs account-wide**, shared here with six other active
workflows, and per GitHub's documentation an exceeded limit **DROPS** runs rather than queueing
them. A dropped run leaves no cross, no yellow dot, no `gh run list` entry — so every tool that
answers "is main green?" from the latest run answers with the **previous** commit's verdict,
indefinitely. That failure is invisible by construction.

It compares **pushes**, not commits: `on: push` fires once per push, so five commits pushed
together correctly produce one run and a commit-based check would cry wolf on every batch.

It lives in a **separate workflow on a schedule**, and that is not tidiness: if
`engine-self-verify`'s run was the one dropped, a job inside it did not run either. A check for
absence cannot be hosted by the thing that might be absent.

`--since 2026-09-10` bounds it to pushes made after the trigger came back. Without that bound
it would be red on its first execution over 95 historical pushes that correctly have no run,
and a check that is red on arrival is a check nobody reads. Deriving the date from the run
history would be circular — if every run had been dropped there would be no history to derive
it from.

## The four red units, and what was done with each

Each was reproduced on Linux locally first, in an `ubuntu:24.04` container built to the
2026-09-04 record's specification (bash 5.2.21, git 2.43.0, python3 3.12.3, unprivileged uid
1001, `rsync`/`procps`/`lsof` present, the clone alone in its directory so `../richos-hq` does
not resolve), and each was also run on macOS. **That second run is what separated two
completely different problems**, and the brief's framing — inflow, not portability — turned out
to be even more right than it claimed.

### FIXED — `contract-integrity.test.sh` case 33 (Linux only)

Case 33 asserts that Layer N **warns** rather than hard-fails when `settings.local.json` is
untracked but not ignored, so it expects the probe to exit 0. On Linux it got 2.

The cause was not Layer N. The case points `GIT_CONFIG_GLOBAL` at a throwaway config to make
the gitignore answer deterministic, and points `GIT_CONFIG_SYSTEM` at `/dev/null` — which
between them leave **no `user.name` and no `user.email` anywhere**. The probe's own Layer Q
fixture then cannot `git commit`, Q reports `FUNCTIONAL CANARY DID NOT RUN`, and the probe
exits 2 for a reason with nothing to do with the case.

It survived on macOS **by accident of the host**: git falls back to
`user@<canonicalized-hostname>` and refuses only when that has no domain part. A Mac's
hostname canonicalizes to something with a dot; a container's (`dec5b7ba7942`) does not.
Measured on both.

Case 32 was worse than case 33: it EXPECTS exit 2, so it kept passing while testing two
unrelated things at once — a negative test passing for the wrong reason.

Two fixes, each correct on its own:

- **the suite** — the throwaway config now carries an identity, so it replaces only what it
  means to replace and case 33 tests only what it names;
- **the probe** — Layer Q's fixture sets a local identity, as layers AL and IL already did.
  This is the operational half and is not a test artifact: on **any** host where git cannot
  auto-detect an email — every container, every runner without a declared global identity —
  Layer Q silently degraded to `DID NOT RUN` and the worktree reaper went unverified in a probe
  that otherwise looked complete.

Verified: `--only N` exits 3 on Linux and on macOS; `--only Q,Qscope,base,worktree` exits 3
with 46 cases passing on Linux.

### FIXED — `legacy-workspace-orphan.acceptance.test.sh` (Linux only)

`FileNotFoundError: [Errno 2] No such file or directory: '/Library'`, three errors, from
`terminal-branch-shadow.py:51`.

`TRUSTED_GIT` named `/Library/Developer/CommandLineTools/usr/bin/git` and nothing else, so off
macOS the default resolved to a path that does not exist and
`Path(...).resolve(strict=True)` raised before `_authority` could reach any of its own
refusals.

**The platform policy already existed — copied by hand into five test files.**
`legacy-workspace-expiry`, `legacy-workspace-retirement`, `terminal-branch-shadow`,
`terminal-recovery-shadow` and `legacy-workspace-operator-integration` each write
`shadow.TRUSTED_GIT if sys.platform == 'darwin' else '/usr/bin/git'` at their call sites. The
answer was decided; it just was not written where the DEFAULT is taken from, and the one
acceptance suite that did not copy the incantation is the one that went red.

`/usr/bin/git` is the right non-darwin value and this is not a loosening: `_authority` already
refuses `/usr/bin/git` **`if sys.platform == 'darwin'`**, because there it is the
developer-selection shim rather than a binary. Off darwin it is the real binary. The refusal
was always darwin-gated; only the default was not.

Second fix, independent of the platform question: a missing trusted binary now raises
`ShadowError` like every other refusal in that function, instead of `FileNotFoundError` with a
traceback pointing at `posixpath`.

Verified: 7/7 on Linux, 7/7 on macOS.

### DECLARED, not skipped — `shell-worktree-sparse.test.sh` and `terminalize-agent-worktrees.test.sh`

**Both are red identically on macOS and on Linux, so neither is a portability finding, and
neither was ever a CI problem.** Both are contract regressions, and the attribution was proven
by execution rather than argued:

| unit | at the suspect's parent | at `4f01e5c7` | broken by |
|---|---|---|---|
| `shell-worktree-sparse.test.sh` | **21/21 pass** at `6472bb60^` | 6 fail | `6472bb60` (2026-09-07) |
| `terminalize-agent-worktrees.test.sh` | **42/42 pass** at `2afb9703^` | 11 fail | `2afb9703` (2026-09-08) |

`6472bb60` made every native member carry `cleanup_owner=claude-code` and taught
`shell-worktree-sparse.eligible()` to refuse such a member, so no shell is sparsified any more.
`2afb9703` introduced `cleanup_policy=integrated-daily`, and `terminalize()` now takes the
save_ref+quarantine route only for a member carrying neither marker. **Neither commit updated
the suite it invalidated**, and both suites still assert the old contract.

Re-specifying them means deciding what the new contract IS, which belongs to the engineer who
changed it and not to whoever is turning CI on. **The lead ruled on that on 2026-09-10: a
dedicated engineer owns both fixes, and neither suite — nor `shell-worktree-sparse.py`,
`terminalize-agent-worktrees.sh` or `worktree-transactions.py` — is to be edited from the CI
side.** Both commits DID update some suites (`worktree-transactions`, `reap-stale-worktrees`,
`reconcile-terminal-worktrees`) and left these two behind, which is why the bisect is
unambiguous. Leaving them red would put a cross on every
commit for a reason unrelated to that commit; deleting their assertions would hide two real
defects. So they are declared in `scripts/lib/ci-known-red.tsv` with the commit, the failing
cases, a sentence saying what would un-skip them, and an **expiry**.

**This is not a skip list, and the difference is enforced rather than asserted:**

1. a declared unit that fails is reported `KNOWN-RED`, printed every run with its expiry, and
   does not fail the job;
2. **a declared unit that PASSES fails the job** — the defect is fixed and the row is now a
   lie. This is the negative control, and without it the table would silently outlive
   everything in it, which is how every skip list everywhere becomes permanent;
3. **an entry past its expiry fails the job** — the tolerance was time-boxed when it was
   granted, so a decision is forced rather than deferred indefinitely.

`ci-shard.test.sh` cases S6, S7 and S8 prove all three.

## Re-packing the shards against measured cost

`scripts/lib/ci-unit-weights.tsv` is one measurement per line, each carrying the run it came
from. A unit with no recorded weight is packed at `DEFAULT_WEIGHT` — never at zero, or a batch
of new suites all lands in one shard and that shard becomes the wall clock.

To re-measure: read the per-unit durations out of a real run's receipts and update that file.
The plan changes; nothing else does. `ci-units.sh plan` prints what the current weights
produce, longest shard included, which is the number `timeout-minutes` should be re-promised
against.

## What a CI run still cannot cover

The integrity probe's **BY-REFERENCE layers, BR1–BR10**. They verify that an operator's
user-scope `~/.claude` plugin registration resolves to this engine — a property of a
workstation, not of a repository, with no honest way to synthesize it on a runner. They are
exercised instead by `scripts/hooks/by-reference.test.sh`, which builds that two-root topology
from scratch and which the unit inventory discovers automatically. Named here rather than
skipped silently; see `ci-portability-notes.md`.
