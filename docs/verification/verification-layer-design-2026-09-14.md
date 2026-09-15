# The verification layer: a design, and its first step walked

**COUNT: 104 → 103 today. Target 58.**

*(That one line is the only line anyone has to read. Everything below is for the engineers who
execute. Every number carries the command that produced it or the word `unverified:`.)*

---

## 0. Read this first: the first step was harder than the plan assumed, and that IS the finding

I was asked to design the layer and then walk the first step of my own migration rather than
propose it. I walked it. I deleted **one** hook — `reader-teammate-hint.sh` — for reasons argued
in §5.1.

**Removing one hook required editing seventeen files.**

```
$ git -C /Users/alex/ab/richos-wt/sage-opus-vdesign1 status --short | wc -l
17          # 15 modified, 2 deleted
```

Adding a hook costs one new file plus two registrations. Removing one costs seventeen edits, four
test suites and a real chance of taking `main` red. **That asymmetry is a ratchet, and a ratchet is
a complete explanation of why this layer only ever grew.** It is not negligence and it was not a
missing design review. Every single one of the 104 is individually well-argued — I read them — and
the layer is still unaffordable, because local justification plus one-way cost is exactly the
machine that produces an unaffordable thing out of correct decisions.

So the design below is not "delete the bad guards." There are no bad guards. It is: **make removal
cost the same as addition, then remove.**

---

## 1. What is actually there — re-derived

Every number in this section was produced by the command printed above it, run on branch
`cc/sage-opus-vdesign1` at parent `8a7ca1fa` (the pre-deletion state).

```
$ ls engine/scripts/hooks/*.sh | grep -v '\.test\.sh$' | wc -l
104
$ ls engine/scripts/hooks/*.sh | wc -l
167
```

The headline "104 guards" is **not 104 guards.** Decomposed:

| what | count | command |
|---|---|---|
| `*.test.sh` (test suites) | 63 | `ls engine/scripts/hooks/*.test.sh \| wc -l` |
| `*.mutation.sh` (mutation harnesses, 0 registered) | 29 | `ls engine/scripts/hooks/*.mutation.sh \| wc -l` |
| everything else | 75 | 167 − 63 − 29 |
| …of which registered as hooks | 71 | `unreg.py`, §App A |
| …of which not registered (probe, install, layer-EP, ref-forensics) | 4 | same |

So **`104` counts 29 test harnesses as guards.** The number the CEO is given is a directory
listing, and it is gameable by `git mv` — moving the 29 mutation harnesses to `scripts/mutations/`
would "reduce the guard count by 28%" tonight and change nothing. I considered that and rejected
it; it is named here so nobody else proposes it as progress.

### 1.1 The thing that actually runs

```
$ python3 -c "import json;h=json.load(open('engine/hooks/hooks.json'));print(sum(len(e.get('hooks',[])) for es in h['hooks'].values() for e in es))"
77
```

77 registered entries across 22 (event, matcher) slots, covering 71 distinct scripts
(`workspace-lifecycle.sh` is registered on six events). Distribution:

| event | entries | consequence |
|---|---|---|
| PreToolUse | 32 | 12 of them on `Bash` — **every shell call spawns 12 bash processes** |
| Stop | 19 | every turn end spawns 19 |
| PostToolUse | 9 | |
| SessionStart | 8 | |
| everything else | 9 | |

### 1.2 Volume

```
$ find engine/scripts -name '*.sh' -not -name '*.test.sh' -not -name '*.mutation.sh' | xargs wc -l | tail -1
   52838
$ find engine/scripts \( -name '*.test.sh' -o -name '*.mutation.sh' \) | xargs wc -l | tail -1
   62906
$ find engine/scripts -name '*.py' -not -name '*.test.py' | xargs wc -l | tail -1
   40190
$ find engine/scripts -name '*.test.py' | xargs wc -l | tail -1
    4090
```

**160,024 lines in `engine/scripts`. 67,000 of them (42%) are test and mutation apparatus.** In the
hooks directory alone, comment-to-code runs 0.97:1 (`loc.py`, §App A) — this layer is half prose by
line, and the prose is load-bearing documentation of incidents, not filler.

---

## 2. The invariant count — the number the brief called the most important one

I derived the invariant behind every one of the 71 registered scripts and collapsed duplicates. The
full mapping is §App B. The result:

> **71 registered scripts express 36 distinct invariants. Ratio 1.97.**

**The lead's hypothesis was that the 104 express "far fewer" invariants. It is true and the factor
is about two, not about ten.** There is no pile of duplicated invariants to collapse. I looked hard
for one and it is not there.

The reason the ratio is ~2 and not ~1 is structural, and it is not waste:

**One invariant needs enforcing at more than one EVENT, and the host's hook API is one script per
(event, matcher) tuple.** The pairs that look like duplicates are not duplicated logic — the
predicate already lives once, in a shared library, and both halves call it:

- `guard-publication-writes.sh` (PreToolUse[Write]) and `guard-publication-commits.sh`
  (PreToolUse[Bash]) both call `scripts/lib/publication-boundary.sh`. The write half sees content
  an agent authors; the commit half sees the staged index, where provenance stops mattering. The
  file's own header records why both exist: of the 2026-08-29 leak, 3 files were agent-authored and
  **137 were tool output that no Write hook ever saw.**
- `guard-named-persons-writes.sh` / `guard-named-persons-commands.sh` both call
  `scripts/lib/named-persons.py`. The second exists because the commit that scrubbed a name from a
  file put the full name in the commit message.

```
$ python3 pairs.py     # §App A
SHARED PREDICATE LIBRARIES used by 2+ hook scripts: 40
```

So: **the predicates are already factored. The scripts are registrations, not copies.** Any plan
that assumes "collapse the duplicate logic" is planning against a codebase that does not exist.

### 2.1 What the scripts *do* duplicate

Not predicates — **chassis**. Measured across the 75 non-test non-mutation scripts (`chassis.py`):

| repeated idiom | files |
|---|---|
| parses JSON (jq or python) | 71 |
| resolves the engine / main checkout | 62 |
| delegates to a `.py` predicate library | 40 |
| can block (`exit 2`) | 40 |
| sources `unevaluated-notice.sh` | 38 |
| carries a prose escape hatch | 23 |
| writes its own ack/waiver log | 15 |

```
$ python3 boot.py
files carrying the root-resolution bootstrap block: 59
total lines of that block across the engine: 885
block size (min/median/max): 15 / 15 / 15
```

**59 byte-identical copies of a 15-line bootstrap**, plus ~45 lines of identical comment each. The
probe has a whole layer (Layer R) whose only job is to assert the 59 copies have not diverged — a
check that exists *solely* because of the duplication it polices.

---

## 3. The real axis — refuting the three buckets I was given

The brief's hypothesis was three buckets: **designed-out / enforced-by-construction /
genuinely-checked**, and asked me to refute it if wrong. It is wrong, and here is why.

That axis asks a question about the INVARIANT: *can this property be made impossible?* For almost
every one of the 36, the honest answer is no. The actor is a language model, its output is prose,
and its failures are semantic. You cannot design out *"the lead reported a merge that never ran"*
or *"a brief carried a number nobody measured."* Applying the three buckets yields "34 of 36 are
genuinely-checked," which is true, useless, and would have produced a document recommending nothing.

**The axis that actually predicts cost is the SUBJECT of the check.**

| class | n | subject | who solves it normally | where the cost is |
|---|---|---|---|---|
| **A. Artifact checks** | 16 | the tree, the index, a config, a ledger | a normal test suite + a pre-commit runner | cheap, deterministic, no waivers |
| **B. Prose/process checks** | 13 | what the agent wrote, claimed, deferred or waived | **nothing off the shelf. This is real and new.** | every waiver in the engine |
| **C. Self-shape checks** | 7 | the enforcement layer's own wiring and inventories | nobody, because normal layers are small | **100% self-inflicted; it is what is red tonight** |

Class C is not in the lead's three buckets at all, and it is the answer.

### 3.1 Class C is what is breaking, measured

CI on `main`:

```
$ gh run list --workflow=engine-self-verify.yml --branch main --limit 200 --json conclusion,createdAt,headSha
  window 2026-08-29 → 2026-09-14, 173 runs: 116 failure, 31 cancelled, 25 success, 1 in_progress
  decided (success+failure): 141 — green 25, red 116 — GREEN RATE 18%
```

> **Correction to the brief.** The brief stated "6 green of 34 decided runs, 2026-09-10 to
> 2026-09-14." I measure **9 green of 57 decided** in that window (16%) and 25 of 141 (18%) over
> the full history. Same conclusion, different arithmetic; recorded because the brief asked me to
> re-derive rather than inherit.

The most recent failing full pass (`34890800113`, 2026-09-14T20:05Z) failed **seven units**:

```
scripts/hooks/by-reference.test.sh          scripts/hooks/engine-status.test.sh
scripts/hooks/hook-staleness.test.sh        scripts/hooks/session-evidence.test.sh
scripts/hooks/unevaluated-payload.test.sh   scripts/demo.test.sh
scripts/brief-scope.test.sh
```

**Six of the seven are class C, and all six failed for one reason: a ninth guard
(`guard-brief-scope.sh`) was registered that day, and six hand-typed inventories of the hook set
did not know.** Quoted from the run log:

> `✗ BR2. PreToolUse[Agent] chain ORDER wrong. want: [8 names] got: [the same 8] guard-brief-scope.sh`
> `✗ C. PreToolUse[Agent] hook chain has 9 entries wired, expected 8`

The seventh, `brief-scope.test.sh`, fails for a different and equally structural reason: it asserts
against `/Users/alex/ab/richos-hq/docs/plans/round9-brief-2026-09-13.md` — **an absolute path into
another repository on the operator's laptop. That suite can never be green on a CI runner.**

### 3.2 How many places must agree when one hook changes

```
$ python3 positions.py
guard-stale-staging.sh       named in  8 files ( 7 non-markdown),  13 occurrences
guard-owned-state.sh         named in  6 files ( 5 non-markdown),   8 occurrences
guard-brief-scope.sh         named in  6 files ( 6 non-markdown),  10 occurrences
guard-model-ceiling.sh       named in 16 files (13 non-markdown),  26 occurrences
guard-dialect.sh             named in 17 files (15 non-markdown),  35 occurrences
scan-secrets.sh              named in 25 files (21 non-markdown),  76 occurrences
```

A guard's name must appear, correctly, in **5–7 non-markdown files outside its own implementation
and tests**: two registration surfaces, plus the probe's spec table, plus `BR_EXPECTED`, plus Layer
R's `R_ROOTED_HOOKS`, plus `engine-status.test.sh`'s acknowledged set, plus the README table.

The engine knows. `contract-integrity-probe.sh` L400, unedited:

> *"is the cost of a typed list. It is worth paying — a derived list would have nothing to say when
> a hook quietly stops sourcing the library — but it is a cost, and whoever adds the next hook
> should expect the same two steps."*

And `engine-status.test.sh` L646, unedited:

> *"on 2026-09-14 that prose cost five CI units red on main at once, three hooks landing within two
> hours, each missing a different subset, three engineers hitting it independently."*

**This is an N² cost in disguise: N guards × k typed positions, and adding guard N+1 breaks a
subset of them.** It is the single largest driver of the repair burden the CEO measured.

### 3.3 Independent corroboration of the CEO's 46%

His figure came from task-completion metadata. I re-derived a comparable number from git, which
knows nothing about that:

```
$ python3 churn2.py
commits since 2026-09-01: 1546
  touch the verification apparatus at all : 698 (45%)
  touch NOTHING BUT the apparatus         : 353 (23%)
```

**45%, from an unrelated source. His number holds.**

---

## 4. The waivers — 2,007 of them, and what they prove

```
$ python3 waivers.py
data-contract-bypasses.log    917 uses, 276 distinct (70% repeats)
ceo-todos-defers.log          407
resume-acks.log               234
ci-red-acks.log               116
worktree-remove-acks.log      112
model-ceiling-acks.log         75
main-checkout-runs.log         46
… 10 more ledgers
TOTAL WAIVERS RECORDED       2007
```

The brief said "a guard with many waivers is a guard the design should remove." I disagree with the
generality and agree with the instance. Look at what the waivers *say*:

```
$ sed -E 's/.*data-contract-bypass:[[:space:]]*//' .claude/state/data-contract-bypasses.log | sort | uniq -c | sort -rn | head -3
  34 convex-only UDF unit test, no local app touched
  26 convex-only UDF unit test, no installed app touched
  26 convex-only mutation test against staging UDFs
```

917 times, the waiver reason is *"this dispatch does not touch the app."* **The gate's default is
wrong for the overwhelming majority of its traffic. It is installed on the wrong side of its own
predicate** — it should require a citation only when the dispatch touches the app, not require a
denial when it does not. That is a mis-specified gate, not a discipline problem, and it costs a
paragraph of typed justification on nearly every dispatch this project makes.

`notice-waiver-repetition.py` already says this, in the engine, in its own words — *"why 251
waivers in one day is a broken-guard report and not a discipline problem."* **That hook is the most
valuable thing in the layer and it is being ignored.** §6 promotes it rather than deleting it.

---

## 5. A guard cannot protect the session that lands it

This landed on `main` at `de525f19` while I was working. I verified it independently before using
it, because the brief says not to trust the record.

```
$ ps -eo pid,lstart,command | grep '[c]laude'
75476 Sun 13 Sep 23:59:44 2026   claude --dangerously-skip-permissions
$ git log --since=2026-09-13T23:00 --diff-filter=A --format='COMMIT %cI' --name-only -- 'engine/scripts/hooks/*.sh'
  guard-brief-scope.sh                2026-09-14T20:25
  notice-claim-capability.sh          2026-09-14T08:46
  guard-hook-registration-commits.sh  2026-09-14T08:09
  notice-protected-ref-moves.sh       2026-09-14T02:17
  handoff-facts-annotate.sh           2026-09-14T02:08
  ref-transaction-forensics.sh        2026-09-14T01:08
  contract-integrity-layer-ep.sh      2026-09-14T00:53
```

**Confirmed. Seven non-test hooks landed after this session's OS process started, and the host
reads the plugin hook table once, at process start.** All seven have been inert for their entire
lives so far. `guard-hook-registration-commits.sh` — the guard that exists to refuse a
half-registered hook — was absent from the table of the very session whose subagent then landed a
half-registered hook.

> The lead reports "eight." I count **seven** non-test hook scripts by the command above; the
> eighth is presumably a `.test.sh` or a same-second second commit. The conclusion is identical.

**And it is worse than reported.** The proposed consolation is that the second surface,
`engine/.claude/settings.local.json`, hot-reloads. It does — and it governs nothing:

```
$ python3 -c "import json;d=json.load(open('/Users/alex/ab/femcboost/.claude/settings.local.json'));h=d['hooks'];print(sum(len(e.get('hooks',[])) for es in h.values() for e in es))"
9
```

**Nine hooks, and not one of them is an engine hook** — they are femcboost's own (the memory
notice, five ECS adapters, `notice-long-agent`, `guard-unfinished-land`,
`guard-brief-verification-scope`). All real work happens in sessions rooted at
`/Users/alex/ab/femcboost`. `engine/.claude/settings.local.json` governs sessions rooted at
`/Users/alex/ab/richos/engine`, of which there are none doing work.

So the second registration surface — **inventory #1 in the completeness predicate, one of the four
places that owed tonight, maintained by hand by every hook author** — is enforcing nothing, for
anyone, ever.

I verified the two surfaces are mechanically redundant:

```
$ python3 transform.py
entries where the pure transform reproduces the other surface: 75
entries where it does NOT: 1        # a stray `bash ` prefix on shell-evidence.sh
```

**Design consequences, stated rather than assumed:**

1. **Every count of "guards protecting us" is a count of guards protecting the NEXT session.** A
   design with 103 guards inherits a 103-guard blast radius on this property. A design with 58
   inherits 58. This is an independent argument for a smaller layer that has nothing to do with
   maintenance cost.
2. **Nothing may be treated as proof a guard is live except the host's own behavior.**
   `enforcing-hooks-<session>.snapshot` is *not* such proof: its writer re-fires on `/clear` and on
   compaction within the same process and does an unconditional `mv -f`, so an inert guard silently
   joins the baseline and the staleness notice then reports no drift. The lead believed that file
   twice today and told the CEO something false both times. **Step 2 of the migration is the only
   fix that does not depend on remembering this.**
3. **The defect applies to its own fix.** Any repair to this is itself a hook change and is
   therefore inert until the next restart. That is the cleanest available argument for the
   structural answer over the repair, and I agree with it.

### 5.1 What I deleted, and why it was safe

`reader-teammate-hint.sh` — a **blocking** `PreToolUse[Agent]` guard that redirected
reading/ingest work to `reed` when it was handed to a generic agent type.

**Why it goes:**

1. **It is not an invariant of any artifact.** It encodes a staffing preference. Every other
   control in the census decides about a commit, a workspace, a payload, a claim or a ledger; this
   one decides about the lead's choice of teammate.
2. **Its precondition is refused by an earlier guard in the same chain.** It fires only when
   `subagent_type` is generic (`Explore` / `Plan` / `general-purpose` / `claude`). Clause 5 of
   `guard-worktree-isolation.sh` — registered **first** in the same `PreToolUse[Agent]` chain —
   `exit 2`s on exactly that condition (`guard-worktree-isolation.sh:572`). So the hint is reachable
   only behind an accepted `generic-agent:` hatch.
3. **That hatch has been used once, ever**, and not for a reading task:
   ```
   $ wc -l < /Users/alex/ab/femcboost/.claude/state/generic-agent-dispatches.log
   1
   ```
4. Its own header claims it is *"first in the PreToolUse[Agent] chain, wired ahead of
   guard-worktree-isolation.sh."* `hooks.json` puts it third. **The file's self-description was
   wrong about its own position** — which is what a check nobody can reach looks like from the
   inside.

**What makes the error impossible afterwards:** clause 5 of `guard-worktree-isolation.sh`, which
refuses the generic dispatch outright and names the roster teammate to use instead. The residual
risk is a reading task sent to a generic agent *behind an accepted hatch* — one occurrence in the
ledger's lifetime, and the hatch already requires a written justification the CEO can read.

**Verification of the deletion (all run on this branch, post-change):**

```
$ bash engine/scripts/hooks/install.sh                                   → rc 0, 76 sidecars
$ RICHOS_ENTITY_ROOT=<engine> bash engine/scripts/hooks/contract-integrity-probe.sh
                                                                          → rc 0, 29 layers ✓, 0 ✗
$ bash engine/scripts/hooks/engine-status.test.sh                        → rc 0, 18/18
$ bash engine/scripts/hooks/root-contract.test.sh                        → rc 0, 29/29 + 11 mutants
$ bash engine/scripts/hooks/contract-integrity.test.sh                   → rc 0, 180/180
$ python3 engine/scripts/check-census.py --engine-root engine
    CONTROL 36 (was 37), INSTRUMENT 29, RECORD 6, total 71 (was 72)
```

The census moving 37 → 36 is the independent confirmation: an instrument that does not know what I
did agrees the layer is one control smaller.

**One more finding, produced by doing this rather than by reading about it.** My first removal was
incomplete — I left the hook's name in a stale-inventory fixture — and the thing that caught it was
`engine-status.test.sh` case 3a, a negative control, five minutes later. `hook-registration-
completeness.sh`, the guard whose job is to name every inventory owing an edit, **returned
`NOT APPLICABLE`**: it diffs the registration surface for *additions* only. **The completeness
guard is one-directional. It cannot see a removal.** That is not a bug to file — it is the ratchet,
implemented.

---

## 6. The target: 58, argued

I was asked to state a number and defend it, and told that 40 is a better answer than 15 if 40 is
true. My answer is **58 hook scripts** (from 103), of which **~31 controls** (from 36).

It is not 15. Getting to 15 means deleting protections the CEO specifically asked for, and I will
not dress that up as an architecture win.

| step | scripts removed | running total | what makes the error impossible |
|---|---|---|---|
| baseline | — | **104** | |
| **0 (done)** `reader-teammate-hint.sh` | 1 | **103** | clause 5 of `guard-worktree-isolation.sh` |
| **1** derive every typed inventory from `registered-hooks.sh` | 0 | 103 | *no count change — this is the step that makes the rest cheap* |
| **2** generate surface 2, or delete it | 1 | 102 | a generated file cannot disagree with its source |
| **2 (done 2026-09-15)** surface 2 GENERATED by `install.sh` | **0** | **103** | a generated file cannot disagree with its source — but deleting it was measured to fail (12 probe layers), and generating it removes a hand-maintained inventory, not a script. See the note under §8 Step 2. |
| **3** move 29 mutation harnesses out of `scripts/hooks/` | 29 | **73** | nothing — see below |
| **4** retire the 4 self-shape scripts the derivation obsoletes | 4 | 69 | derivation + CI |
| **5** collapse 11 Stop-time notices into the turn manifest | 11 | **58** | one notice, same facts, one process |

**Step 3 is the one I said I would not do, and here is the condition under which I will.** Moving
the mutation harnesses out of `scripts/hooks/` is cosmetic *by itself* and I reject it as a
standalone move. It becomes legitimate only once the headline metric changes from
`ls scripts/hooks/*.sh | wc -l` to something that means something (§7) — at which point the move is
simply putting test apparatus where test apparatus goes. **Do not do step 3 before §7.** If the
count metric is not changed, the honest target is **87**, not 58, and the CEO should be told that
number instead.

**What survives and why it is not negotiable:** the 13 class-B prose/process controls. Nothing
off the shelf does this. A linter does not catch *"reported a merge that never ran"*; a type checker
does not catch *"the brief carried a number nobody measured."* These are genuinely new problems
created by putting language models on an engineering team, and shrinking their count to make the
headline prettier would be the exact dishonesty this document exists to avoid.

---

## 7. What normal practice already solves, and what it does not

Be specific and unsentimental, the brief said.

**Reimplementations of standard tooling, in bash (Class A, 16 invariants, ~24 scripts).** These are
pre-commit content linters wearing a hook costume: dialect, secrets, personal names, publication
boundary, vendoring, row currency, land completeness, CEO-TODOs well-formedness. A normal
team runs these as `pre-commit` / `lint-staged` hooks with one runner and N rules.

**What replacing them with the standard tool would cost — and why I am not recommending it:** this
engine's guards intercept the *tool call* (`PreToolUse[Bash]` on `git commit`), not the git hook. A
git `pre-commit` hook is bypassed by `--no-verify` and is not installed in a fresh worktree; the
tool-call interception is neither. Given 48-of-53 hand-rolled cross-repository worktrees on this
machine, `pre-commit` would be un-installed in most of them. **Keep the interception point; adopt
the runner shape.** One `PreToolUse[Bash]` dispatcher that loads N rule modules replaces 12
independent bash processes per shell call with one — which is the latency win, and it is worth more
than the file count.

**`shellcheck` and `bats` are the two genuinely missing standard tools.** 160k lines of bash with
zero static analysis, and a hand-rolled `ok`/`bad` harness reimplemented in 63 suites. `unverified:`
I did not measure what `shellcheck` would report on this tree; settle it with
`shellcheck engine/scripts/hooks/*.sh | wc -l` before committing to it.

**What has no off-the-shelf answer, stated without shrinking it.** All 13 class-B invariants, and I
will not pretend otherwise: a stated action was taken; a claim is resolved before the turn ends; a
brief is in scope of the CEO's spec; the model is the one the name declares; the definition is not a
stale snapshot; a waiver is not the 917th of its kind; a deferral of his ask is put to him; a row
his record says is started is started; the agent's state claim matches the authoritative check.
**These are new, they are real, and they are the part of this engine worth keeping and worth
selling.** The rest is scaffolding around them.

---

## 8. The migration, in landable order

Each step is independently landable and leaves the engine working. The order is set by the CEO's
constraint that a design paying off only at the end is a design that never finishes — **steps 1 and
2 pay the biggest fraction and come first**, even though step 1 moves the count by zero.

**Step 1 — derive every typed inventory. (No count change. Highest value.)**
`scripts/lib/registered-hooks.sh` already exists and is already used by six scripts. Use it in the
remaining seven typed positions: the probe's `BR_EXPECTED`, `R_ROOTED_HOOKS` and Layer-M `CANON`
lists; `engine-status.test.sh`'s `ACKNOWLEDGED_SCRIPTS`; `session-evidence.mutation.sh`;
`unevaluated-payload.test.sh`; `demo.sh`. **Add nothing** — the library exists.
*Done when:* adding a throwaway hook and running the full local suite produces zero failures with
no second edit. That is `wire_extra_guard()` in `engine-status.test.sh` generalized to the other
six suites. **Expected effect: six of the seven units red tonight go green.**

**Step 2 — settle surface 2 (§5).** Either generate `engine/.claude/settings.local.json`'s `hooks`
key from `hooks/hooks.json` at install time (75 of 76 entries are already a pure transform), or
register the engine's hooks where the governing session actually reads — `/Users/alex/ab/femcboost/
.claude/settings.local.json`, which hot-reloads and would end the "inert until restart" class
permanently. **The second is strictly better and is a subtraction either way.** Retires
`guard-hook-registration-commits.sh` and `scripts/hook-registration-completeness.sh`.
*Done when:* a hook added mid-session fires in that same session, demonstrated live.

> **WALKED 2026-09-15 (`zach-opus-surface2`, branch `cc/zach-opus-surface2`). Three of the five
> claims in that paragraph are true, two are not, and the two that are not change the step.** Every
> measurement below was taken live in session `b7d89f44`, OS process 75476, started
> `Sun 13 Sep 23:59:44` (`ps -eo pid,lstart,command | grep '[c]laude'`).
>
> **TRUE — the settings surface hot-reloads.** A probe hook appended to
> `/Users/alex/ab/femcboost/.claude/settings.local.json` fired on the very next Bash call and on
> twenty calls after it, same process, no restart. **TRUE — the plugin surface does not.** The same
> probe appended to `engine/hooks/hooks.json` fired zero times across two calls; the file was
> restored byte-identically (`sha256 1c53f4c8…`). **TRUE — the transform is pure**: 74 of 76 entries
> reproduce exactly *including timeouts*, 75 of 76 ignoring one stray timeout, so the 75 above holds.
>
> **FALSE — "strictly better".** The host does NOT deduplicate a hook registered on two surfaces.
> Registering the expanded form of a live plugin hook (`shell-evidence.sh`) on the settings surface
> produced **two** copies of its `additionalContext` on a single tool call. So "register where the
> session reads" is not an addition to the plugin path, it is a migration off it — and
> `scripts/hooks/install.sh`'s own header records this exact bug from the `settings.json` era:
> *"Claude Code reads BOTH files and MERGES their hook arrays additively — so every hook fired TWICE
> per matching tool event."* The lead ruled on the measurement: **subtraction only, no re-plumb.**
>
> **FALSE — the retirement.** `hook-registration-completeness.sh` derives **four** inventories by
> unanimity: `hooks/hooks.json`, `.claude/settings.local.json`, the probe's `BR_EXPECTED`, and
> `engine-status.test.sh`'s `ACKNOWLEDGED_SCRIPTS`. Surface 2 is **one** of them. **Step 2 takes the
> predicate from 4 inventories to 3 and retires NEITHER guard.** The other two are typed on purpose:
> `contract-integrity-probe.sh` L392–406 states the rule — *"A derivation is a CROSS-SURFACE CHECK
> when the side it is derived from and the side it is checked against are DIFFERENT FILES. It is a
> TAUTOLOGY when they are the same file"* — and `BR_EXPECTED` is compared against `hooks/hooks.json`,
> so deriving it from `hooks/hooks.json` would leave it checked against itself. Deriving those two is
> Step 1's job, not this one. (`tom-opus-derive1` reached the same conclusion independently. The rule
> is stated at L392–406; it is *applied* at L2161 and L2257, which is where a line reference of
> "L2108–2116" was pointing.)
>
> **AND "or delete it" IS NOT AVAILABLE.** Deleting the `hooks` key was tried first and measured:
> **12 probe layers go red** (B, C, K, T, IL, O, IP, P×2, Q, S, R) plus `hook-staleness` case 11.
> Surface 2 is not dead weight — it is the registration the probe's Layers A–Q audit in **seated**
> mode (`ENGINE_ROOT == REPO_ROOT`, i.e. whenever the subject repository is the engine itself, which
> is what CI does). §5's "enforcing nothing, for anyone, ever" is right about *sessions* and wrong
> about the probe.
>
> **WHAT WAS DONE, therefore: generation — the first option, not the second.** `install.sh` now
> derives the `hooks` key from `hooks/hooks.json` by the stated transform. The regeneration changed
> exactly the two entries that had drifted and nothing else. Nobody hand-edits 500 lines of JSON
> again; the completeness predicate's demand for that surface is now satisfied by running a command.
> **Registered-script count is unchanged at 71** — this step moves positions-per-rule, not the count,
> and reporting it as a count reduction would be reporting a number that moved for a different reason
> than the reader thinks.

**Step 3 — the runner shape (§7).** Collapse the 12 `PreToolUse[Bash]` guards into one dispatcher
with 12 rule modules; same for the 5 `Write|Edit` guards. Predicates already live in shared
libraries, so this moves call sites, not logic. *Done when:* one bash process per shell call.

**Step 4 — fix the mis-specified gates before deleting any of them.** Invert the data-contract
gate's default (§4). Delete `brief-scope.test.sh`'s absolute path into `richos-hq` — that suite
cannot pass on a runner and its red is pure noise. Re-measure the waiver ledgers after two weeks;
any gate still waived >50 times is re-specified or removed, and `notice-waiver-repetition.sh`
becomes the standing instrument that says which.

**Step 5 — the count steps.** Mutation harnesses out of `scripts/hooks/` (**only after §7 changes
the metric**); the four obsoleted self-shape scripts; the eleven Stop notices into the turn manifest.

---

## 9. Change the number he is shown

The CEO's stated metric is the guard count, and I have to tell you it is the wrong number: it
counts test harnesses as guards and it moves under `git mv`. Report these four instead — each is one
command, each means something, and each can be put in one line:

```
blocking controls        python3 engine/scripts/check-census.py --engine-root engine | grep -c CONTROL
positions per rule       the median of positions.py — how many files must agree to change one rule
waivers this week        wc -l on the ledgers in .claude/state/*.log
CI green rate            gh run list --workflow=engine-self-verify.yml --branch main
```

**Today: 36 controls, 6 positions, 2,007 lifetime waivers, 18% green.**
**Target: 31 controls, 2 positions, <50 waivers/week, >90% green.**

The middle number is the one that actually predicts the repair burden he measured, and it is the
one this design is built to move.

---

## Appendix A — reproducing every number

Every measurement in this document was produced by a short script run from
`/Users/alex/ab/richos-wt/sage-opus-vdesign1`; each is described inline where its output appears, so
it can be re-derived without the script. Pre-deletion counts are at parent commit `8a7ca1fa`;
post-deletion counts are at this commit.

## Appendix B — the 71 registered scripts → 36 invariants

Workspace and work preservation (5): I01 a file-writing agent writes only in its own registered
workspace · I02 committed work is not destroyed before it is landed · I03 a live agent is not
interrupted, nor resumed into a dead workspace · I04 agent lifecycle state is recorded from events
· I05 a state claim matches the authoritative check.
Dispatch (6, was 7 before §5.1): I06 model tier/ceiling · I07 definition currency · I08 spawn-prompt
completeness · I09 brief in spec scope · I10 no routing around a standing owned system · I11 not
against stale staging.
CEO channel (6): I12 open with his prepared question · I13 do not re-ask what he ruled · I14 his
input files committed unmodified · I15 a deferral is put to him · I16 a started row is started ·
I17 an escalation reaches him.
Record and content (8): I18 American English · I19 no credentials · I20 no third-party names · I21 no
private material in a publication-bound repo · I22 vendored material carries its license · I23 a
row's premise is current · I24 a land is complete across its surfaces · I25 CEO-TODOs well-formed.
Turn truthfulness (4): I26 a stated action was taken · I27 a claim is resolved before turn end ·
I28 a mechanical finding is surfaced · I29 a repeated waiver is surfaced as a broken guard.
Land and CI (3): I30 nothing lands on red CI · I31 in-flight agents are told when main moves · I32
staging is current before product work.
Tooling (2): I33 the Workflow tool is banned · I34 no interactive command.
Engine self-shape (2): I35 the layer is wired and current · I36 a hook is registered on every
surface — ~~**retired by step 2.**~~ **CORRECTED 2026-09-15: not retired.** Step 2 made the second
surface DERIVED, so I36's fix became a command instead of an edit; the invariant still has to hold
across `BR_EXPECTED` and `ACKNOWLEDGED_SCRIPTS`, both typed on purpose, both Step 1's work. Guards
retired by Step 2: **none**. Registered-script count after Step 2: **71**, unchanged.

## Appendix C — verification log for the step-0 deletion

| check | result |
|---|---|
| `install.sh` | rc 0, 76 sidecars minted |
| `contract-integrity-probe.sh` | rc 0, 29 layers ✓, 0 ✗ |
| `engine-status.test.sh` | rc 0 — 18/18 |
| `root-contract.test.sh` | rc 0 — 29/29 + 11 mutants load-bearing |
| `contract-integrity.test.sh` | rc 0 — **180 passed, 0 failed**, including every case whose specimen I changed (14a, 14b, 14c, 14d, 18) and `WTI1.staffing-gate-mutations-all-load-bearing`, the harness for the clause 5 this deletion relies on |
| `check-census.py` | CONTROL 37 → 36, total 72 → 71 |
| `hook-registration-completeness.sh` | `NOT APPLICABLE` — cannot see a removal (§5.1) |
