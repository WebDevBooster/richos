# The reclaim decision table

**What may this engine remove, and why.** Every reachable combination of the
observable inputs, each with exactly one outcome. Written 2026-09-10, on the
CEO's instruction, after eleven rounds of this problem.

**Why it did not exist before, which is the whole reason it exists now.** Every
round started from the existing code asking *"what is wrong with this"* rather
than from the decision asking *"what are the cases"*, so each round inherited
the previous round's shape and added to it. And round 11's central premise —
that the platform's first stop means an agent can never run again — survived
because nobody ran the one command that disproves it. **The table comes first;
the code is held against the table; the test suite IS the table.**

---

## 1. The inputs, and which of the proposed five survived

The brief proposed five: ours, ancestor-of-main, uncommitted, holding, present.
**Three of them are not booleans, one of them is not observable in the form
proposed, and one input is missing.** That is the most useful thing in this
document, so it is first.

| # | Input | Values | Observable from |
|---|---|---|---|
| A | **Whose workspace is it** | `ceo-owned` · `ours` · `not ours` | branch prefix / path (§31); transaction membership |
| B | **Directory present** | `present` · `absent` | `os.lexists` |
| C | **What is holding it** | `nothing` · `platform lock` · `process` · **`CANNOT TELL`** | `git worktree list` porcelain; `lsof`/`ps` |
| D | **Uncommitted content** | `clean` · `tracked-dirty or untracked` · `ignored residue` | `git status` / `ls-files --others` |
| E | **Integration** | `ancestor` · `unlanded` · `squash-landed` · **`unanswerable`** | `merge-base --is-ancestor`; `git cherry`; trunk name |
| F | **Owner still able to act** | `provably gone` · `mid-run` · **`unknown`** | session pid table; post-terminal lifecycle record |

**A is three-valued, not two.** `ceo-owned` is not a kind of "not ours" — it
must be *reported by name* (`ceo-decisions.md` §31: "never silently skipped
... never absent from the report"), and §31 says explicitly that the record
hole must not BE the protection. Collapsing it into "not ours" is what let the
shipped preview print six holds and zero Codex workspaces while nine stood on
the machine.

**C has a fourth value and it is the one that bites.** *"Is anything holding
it"* reads as a boolean and is not: the probe can FAIL. Until 2026-09-10
`processes_using()` swallowed every `lsof`/`ps` exception and returned an empty
list, so *a failure to look* arrived at the decision wearing the costume of *a
clean answer*. Any table that writes C as yes/no re-creates that defect.

**E has four values.** `unlanded` and `squash-landed` are both "not an
ancestor" and need opposite actions from a person — one lands, the other can
never land and must be retired deliberately. And on a repository whose trunk is
not `main` the question is **unanswerable** by this lane, which is a refusal
with a reason rather than a `False`.

**F is the missing input, and it is only PARTLY observable — this is the
finding the brief should carry away.** The platform provides no event meaning
*"this worker is finished"*. Its entire vocabulary here is three event types:

```
$ python3 engine/scripts/restart-after-terminal-measure.py --census
  session-d0eef867
    WorkerRunEnded   rows=1765  distinct payload ids=1756  of which registration ids=27
    WorkerStarted    rows=45    distinct payload ids=36    of which registration ids=36
    WorkerUpdated    rows=14    distinct payload ids=14    of which registration ids=11
```

`worker-ended-handoff.sh` has always said so in its own header: *"`run_ended`
means this RUN ended, never 'this worker is gone'."* So F is answerable in
exactly two directions and unknown in the third:

- **`provably gone`** — every recorded pid of the owning session is gone or
  reused and no running registration names it. Positive evidence, expensive,
  and true only after a session ends.
- **`mid-run`** — the platform started this agent again after its terminal
  record and no stop has closed that run. Positive evidence from two platform
  events, recorded since 2026-09-10.
- **`unknown`** — everything else, **including an agent that has stopped and
  will be given another turn in six hours.** Measured: 10 of 66
  workspace-owning terminal transactions on this machine were started again
  after their terminal record, the earliest 2026-09-08.

**READ THAT LAST LINE BEFORE READING THE TABLE.** The common case is `unknown`,
and no amount of design changes that. So the table cannot be built on "is the
agent finished" — the answer is not available — and the safety argument has to
be that **a removal cannot destroy work**, never that the agent will not
return.

**The proposed input "is the work an ancestor of main" is doing more work than
its name suggests, and it is the right instinct.** Git is outside the agent and
permanent. A woken agent cannot un-merge its own commits. That is why E, not F,
is the load-bearing input.

---

## 2. The table

**ORDERED. The first row that matches decides.** That is not a presentational
choice — it is how the code short-circuits, and it is what collapses 3·2·4·3·4·3
= 864 raw combinations into fifteen rows. Each row states what it collapses.

Outcomes are exactly three:

- **REMOVE** — the workspace goes, its branch is resolved by compare-and-set.
- **REFUSE** *(reason)* — a decision, stated. It may be permanent.
- **RETRY** *(holder)* — not a verdict. Something transient is in the way and
  it is NAMED. The hold clears by itself.

| # | Condition | Outcome | Collapses | Code | Test |
|---|---|---|---|---|---|
| 1 | **A = ceo-owned** — branch `codex/…` or path under `~/.codex/worktrees` | **REFUSE** "EXCLUDED BY CEO RULING (§31)", and REPORT it by name | every other input. §31 admits no flag and no reason string | `ceo_owned_workspace`, first gate of `owner_check` | `…EXCLUDED_BY_CEO_RULING_at_every_door` |
| 2 | **A = not ours** — no transaction member names this path | **REFUSE**, never reached, and REPORTED under NOT EXAMINED | every other input. Half the raw table dies here | not enumerated; `preview()` reports it | reconciler preview, `not-examined` count |
| 3 | Ownership is contested — another transaction reserves this scope, or a preparation row is unbound | **REFUSE** "active or unbound preparation reservation" | everything below | `owner_check` | `…unbound_preparation_refuse` |
| 4 | The ledger row that would bind this by NAME was not written by an engine writer | **REFUSE**, and the row still RESERVES | — | `row_may_bind_by_name` | `…hand_written_ledger_row_RESERVES_but_never_BINDS` |
| 5 | **F = mid-run** — a post-terminal start with no stop after it | **RETRY** "the platform started this agent again" | everything below | `running_after_terminal` in `owner_check` | `…restart_after_terminal…HOLDS…` |
| 6 | The owner is ALIVE by its native lock, or liveness is INDETERMINATE | **RETRY** "native owner is live or unknown" | everything below | `agent-liveness.resolve` veto | `…lock_naming_a_live_pid_refuses…` |
| 7 | No platform stop was ever recorded for this agent | **REFUSE** "not a candidate" | — | `platform_recorded_a_stop` | `…engine_derived_terminal_fact_stays_platform_owned` |
| 8 | **B = absent** and **E = ancestor** | **REMOVE (branch only)** by CAS on the tip checked | C and D are moot — there is no tree | `_absent_native_without_receipt` | `…absent_native_without_receipt…` |
| 9 | **B = absent** and **E ≠ ancestor** | **REFUSE**, naming `unlanded` vs `squash-landed` | C, D moot | same | `…keeps_an_unintegrated_branch` |
| 10 | **C = platform lock** | **REFUSE** "the platform is holding its own lock", naming the operator remedy | D, E — a locked tree is not ours to inspect or remove, and `git worktree remove` refuses one anyway | `platform_lock_is_absent` | `…names_nobody_is_STILL_A_LOCK…` |
| 10a | *…unless* **F = provably gone** and the lock names a dead pid | release that one lock, then continue | — | `session_gone` + `_release_dead_lock` | `…provably_gone_session…dead_lock_released` |
| 11 | **C = CANNOT TELL** — the process probe did not answer | **RETRY** "could not determine whether any process is standing in this" | D, E | `processes_using` fails closed | `…probe_that_cannot_look_HOLDS…` |
| 12 | **C = process** | **RETRY**, naming pid and command | D, E | `describe_processes` | `…process_standing_in_the_tree…` |
| 13 | **D = tracked-dirty or untracked** | **REFUSE** — work nobody committed | E | `clean_tree` | `…dirty_staged_and_untracked_refuse` |
| 14 | **E = unanswerable** (trunk is not `main`) | **REFUSE**, naming the condition and saying nothing is broken | — | `direct()` | `…trunk_is_not_main_is_HELD_and_says_why` |
| 15 | **E ≠ ancestor** | **REFUSE**, naming `unlanded` vs `squash-landed` | — | `verify_member_proof` | `…squash_landing…` / `…genuinely_unlanded…` |
| 16 | **D = ignored residue** | archive + verify digest by digest, then fall through | — | `archive_residue` | `…residue_is_archived_verified_then_reclaimed` |
| 17 | Everything above passed | **REMOVE** — re-verify E and C immediately before the removal, non-force `git worktree remove`, CAS branch delete | — | `reconcile` | `…reclaims_worktree_and_branch` |

Fifteen rows plus one exception (10a) and one non-terminal step (16).

### Why 864 collapses to this

- **Row 2 kills half of everything.** "Not ours" is not a case with sub-cases;
  it is a case with none.
- **Rows 8–9 kill C and D entirely for absent directories.** Nothing can hold
  or dirty a tree that is not there.
- **Row 10 kills D and E.** A locked tree is the platform's; we do not read
  its contents to decide, and git refuses the removal regardless.
- **Rows 11–12 kill D and E.** A holder is transient; there is nothing to
  decide about content until it leaves.
- **C's four values × D's three × E's four never multiply out**, because each
  is a short-circuit, not a coordinate.

### What is NOT in this table, and therefore should not be in the code

Held against the table, three things in the shipped code are not rows:

1. **`reconcile(..., immediate=…)` is a dead parameter.** Its only branch was
   the unattributable-lock release, deleted 2026-09-10. It is declared, passed
   and never read. **Delete it.**
2. **`lock_names_nobody` / `_release_unattributable_lock`** — already deleted.
   They were a second door past row 10, and row 10 admits no second door.
3. **`_held_by_nobody_over_a_terminal_agent`** — already deleted. It was a
   second door past row 6.

`session_gone` (row 10a) **stays**, and the distinction from the deleted
`_release_unattributable_lock` is the point: 10a requires POSITIVE evidence
that the owning session is gone AND a lock naming a dead pid. The deleted route
required only that a lock said nothing, over a session that was still running.
One is "the owner is provably dead"; the other was "the lock is uninformative,
so I will decide on the platform's behalf."

---

## 3. The row a reviewer should attack

**Row 17, when F = `unknown`.** A merged, clean, unlocked workspace of an agent
that has stopped and *may be given another turn in six hours* is REMOVED. That
is not an oversight; it is the design, because F is not answerable and pretending
otherwise is what round 11 did.

The claim that makes it acceptable is deliberately small and is the only one
made:

> A removal cannot destroy work, because a workspace is removed only when its
> tracked bytes are byte-identical to a commit `main` already contains
> (verified before the removal and again before the branch delete), its ignored
> bytes are archived and verified first, and nothing holds it. A restart after
> a removal is a **disruption** — an agent waking in a directory that is gone —
> not a loss, and it is detected, recorded on the transaction, and announced.

Two facts hold the race shut, and both are measured rather than reasoned:

- The platform writes its lock **before** a run begins — `agent-a2de3c7d8d8590224`
  lock mtime `16:07:26.643Z` against `WorkerStarted 16:07:26.692Z` (−49 ms),
  and `agent-a97f2c691c34e2c0f` `17:43:41.993Z` against `17:43:42.036Z` (−43 ms).
- Non-force `git worktree remove` **refuses a locked worktree** — `fatal: cannot
  remove a locked working tree`, exit 128, git 2.52.0 — and refuses a dirty one.

So a restart that begins between the check and the removal makes the removal
FAIL rather than race. What it does not prevent is a restart *after* a
successful removal, and that case is a disruption by the claim above.

**If a reviewer can show a path where a removal under `F = unknown` loses work
that git does not already hold, the table is wrong and row 17 must become a
REFUSE.** That is the falsifier for this round, stated the way round 11 stated
its own, and it is measurable rather than rhetorical.

---

## 4. Falsifiers, and the commands that answer them

| Claim | Command | Answer today |
|---|---|---|
| A terminal agent never runs again | `restart-after-terminal-measure.py` | **FALSE** — 10 of 66 |
| The platform emits a "finished" event | `restart-after-terminal-measure.py --census` | **FALSE** — three event types, none of them |
| The platform releases its lock within a second | the immediate-reclaim journal | **FALSE** — 3 of 3 own-event attempts deferred; one held 77 min |
| A locked worktree can be removed non-force | `git worktree remove` on a locked tree | **FALSE** — exit 128 |
| The lock is taken before the run | admin-dir mtime vs `WorkerStarted` | **TRUE** — −49 ms, −43 ms |
| Codex workspaces are reported | `reconcile-terminal-worktrees.py --preview \| grep -c EXCLUDED` | **9** (was 0) |

Every number here carries the command that produced it. A number that cannot be
re-derived from its own command does not ship.

---

## 5. Two rules this document is written under

**A LINE NUMBER IS A CLAIM WITH A DATE ON IT. Cite the symbol.** The brief that
commissioned this work said deletion happens only on a proven ancestor
"(`daily-workspace-cleanup.py:853`)"; line 853 was inside `assess()`, the
read-only twin that removes nothing. Round 10's `daily-workspace-cleanup.py:57-60`
had drifted to a different construct within a day. The claims were true and the
citations were not, which is worse than no citation, because a reader who checks
one and finds the wrong thing stops checking. Every reference in the table above
names a FUNCTION. Functions get renamed too — but a rename is greppable and a
line shift is silent.

**A CONTROL THAT REPORTS IS A PASSING OUTCOME; A CONTROL THAT BLOCKS MUST BE
MEASURED FIRST.** Three guards died in one day (`g11`, `g12`, `g13`) by being
broad enough that waiving became habitual, one reaching 251 waivers. Nothing in
this table blocks a turn. The refusals here refuse a DELETION, which is the safe
direction by construction: the cost of a wrong refusal is a directory that
survives a night.
