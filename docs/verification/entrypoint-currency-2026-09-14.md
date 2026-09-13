# How many more times: the measured exposure to failure type V, and the mechanism that ends it

**Date:** 2026-09-14
**Measured at:** `richos` main `082ef5cd`, `femcboost` main `53fae74c1`
**Re-measured at:** `richos` main `953b0369` (see §0.1 — main moved mid-task and one of
these findings was fixed under me)
**Scope:** `/Users/alex/ab/richos` and `/Users/alex/ab/femcboost`, the 14 days ending 2026-09-14

---

## 0.1 Main moved under this work, and it changed one of the answers

This brief was measured against `082ef5cd`. While it was being written, `richos` main moved
to `953b0369`, and `engine/scripts/hooks/engine-status.sh` was corrected there: it now names
`spawn.sh` five times, ahead of the commands it supersedes.

**So the engine half of the finding in §1.3 is FIXED, by someone else, while this was being
written.** The measurement is kept exactly as it was taken, because a record that quietly
rewrites itself to match the present is worth nothing — and because the fix does not change
what the measurement was for. Every fact below was true at `082ef5cd`. What changed:

| | at `082ef5cd` (as measured) | at `953b0369` (re-run) |
|---|---|---|
| `engine-status.sh:229` | stale — 2 findings | **fixed** — 0 findings |
| `femcboost/CLAUDE.md:203` | stale — 1 finding | **still stale** — 1 finding |
| Layer EP on the engine | FAIL (exit 2) | **PASS (exit 0)** |

**This is the argument for the mechanism, not against it.** The instruction was corrected by
hand, once, by a teammate who happened to be looking at that file — which is exactly how the
six clean rows in §1.3 got clean, and exactly what failed on 2026-09-13. The check is what
makes the next one not depend on somebody happening to look.

---

## 0. The question, and the answer in one line

He asked how he can know this will not keep coming up in new sessions. He is owed a
number and a mechanism, not a reassurance, because a promise is what he already had
and it is what failed.

**The number: ONE. One recently-landed capability is not named by the instruction that
should send someone to it — and it is the one he already found. It is stale at TWO
sites, in two repositories. Everything else measured clean.**

**The mechanism: supersession is now data.** `ENTRYPOINTS` in `orchestration.config`
names, for each task, the command today and what it replaced;
`scripts/entrypoint-currency-lint.sh` refuses a standing instruction that names a
superseded entrypoint and never names its replacement; Layer EP of the integrity probe
runs that lint plus a two-sided canary at every land. It is the `MODEL_TIERS` shape,
copied rather than invented.

---

## 1. Part 1 — the number, and the commands that produced it

### 1.1 What was counted, and why that population

A "capability" here is an **operator-invocable entrypoint**: a script somebody is told
to run. Hook scripts, libraries under `lib/`, test suites and measurement tools are
excluded — nothing routes a person to them, so none of them can carry a stale
instruction. The window is 14 days: 2026-08-31 through 2026-09-14.

```
# richos — run from /Users/alex/ab/richos
git log --since=2026-08-31 --diff-filter=A --name-only --pretty=format:'' \
    -- 'engine/scripts/*.sh' 'engine/scripts/*.py' \
  | grep -v '^$' \
  | grep -v -E '/(lib|hooks|owned-state-checks)/' \
  | grep -v -E '\.(test|mutation|selftest|acceptance)\.' \
  | sort -u | wc -l
# -> 39

# femcboost — run from the femcboost checkout
git log --since=2026-08-31 --diff-filter=A --name-only --pretty=format:'' \
    -- 'scripts/*.sh' | grep -v '^$' | sort -u
# -> scripts/preflight-agent-spawn.sh   (the only one; the rest are hooks/ and tests)
```

**M = 40** operator-invocable entrypoints landed in the window.

### 1.2 Which of them SUPERSEDE something

Type V is not "a new capability nobody documented". It is "a capability replaced the
right way to do a task, and the instruction still routes people to the old way". So the
40 were reduced to those that changed an existing route. The reduction was derived, not
recalled:

```
# for each new entrypoint: what its landing commit NAMES, and what it DELETED
for f in <the 39>; do
  c=$(git log --since=2026-08-31 --diff-filter=A --format='%H' -- "$f" | head -1)
  git log -1 --format='%B' "$c" | grep -oE '[a-z0-9][a-z0-9._-]*\.(sh|py)' | sort -u
  git show --diff-filter=D --name-only --format='' "$c" | grep -E '\.(sh|py)$'
done
```

Seven supersessions came out of that, and each was then checked by hand against the
standing-instruction surfaces. **Thirty-three of the forty replaced nothing** — a new
capability with no predecessor route cannot be stale by omission.

### 1.3 The table

Instruction surfaces checked: SessionStart announcements
(`engine/scripts/hooks/engine-status.sh`), `CLAUDE.md` in all three repositories,
`engine/CLAUDE.md.template`, every `skills/*/SKILL.md`, every `.claude/agents/*.md`, and
each helper's own printed advice.

| Capability (landed in window) | What the instruction that should send someone to it currently names | Superseded? |
|---|---|---|
| `engine/scripts/spawn.sh` — starting one teammate | SessionStart announcement `engine-status.sh:229` names **`prepare-agent-spawn.py`** and **`create-teammate-worktree.sh`**; `femcboost/CLAUDE.md:203` names **`create-teammate-worktree.sh`**. Neither names `spawn.sh`. Its only mention anywhere is `engine/README.md:218`, a reference table nobody is routed through. | **YES — 2 sites** |
| `engine/scripts/workspaces.sh` — deleting an agent workspace | `engine/README.md:217`; the two retired deleters (`remove-agent-worktree.sh`, `reap-agent-worktrees.sh`) are gone from disk and named in no instruction surface | no |
| `engine/scripts/agent-liveness.sh` — is this agent alive | `femcboost/CLAUDE.md` names it directly, with the ALIVE / NOT-ALIVE / INDETERMINATE contract | no |
| `engine/scripts/escalate.sh` — raising a blocker | installed into every agent definition by `install-escalation-protocol.sh`; the superseded `BLOCKED.md` doctrine is named only as the thing that failed | no |
| `engine/scripts/staging-record.sh` — staging staleness | `engine/README.md:226`; the paragraph it replaced is gone, not stale | no |
| `engine/scripts/loro-capitalization-check.sh` — the tool kept after its guard was unwired | no instruction claims the guard still enforces | no |
| `femcboost/scripts/preflight-agent-spawn.sh` — the spawn pre-flight | itself superseded by `spawn.sh` and **deleted** at `e0db3e03d`; no repository file still names it | no |

**N = 1 of 40.** One capability, two stale sites, both for the same supersession, and it
is the one he found by paying for it.

### 1.4 One site outside version control, named because it is real

`~/.claude/projects/.../memory/MEMORY.md` still carries *"Preflight EVERY spawn — run
`scripts/preflight-agent-spawn.sh` before calling Agent"*. That file was deleted from
femcboost at `e0db3e03d`. No check in any repository can see an operator's memory file;
it is named here so the correction is not forgotten, and it is not counted in N because
it is not a repository artifact.

### 1.5 What the small number means, and what it does not

It means the exposure today is narrow — **not** that the practice is sound. Every one of
the six clean supersessions was clean because somebody remembered, in the same commit,
to change the instruction too. That is exactly the thing that failed once already, and
remembering does not scale with the landing rate: 40 operator entrypoints in 14 days is
roughly three a day.

---

## 2. Part 2 — the mechanism

### 2.1 The shape, and why it is not a new one

`MODEL_TIERS` exists because an orchestrator inferred a capability order from alias
names and was wrong. The fix was not more care: the order became **data** in
`orchestration.config`, with one parser, one quotation site, and a probe layer refusing
drift between the prose and the declaration. `MODEL_CEILING` followed the same shape a
day later.

This is that shape applied to routing.

| | `MODEL_TIERS` | `ENTRYPOINTS` |
|---|---|---|
| The fact nobody may guess at | which model is stronger | which command is current |
| Declared once, as data | `orchestration.config` | `orchestration.config` |
| One parser, nothing else may parse it | `scripts/lib/model-tiers.sh` | `scripts/lib/entrypoints.sh` |
| Probe layer refusing drift | MT | **EP** |
| Two-sided canary | refuses a lower tier, silent on an equal one | refuses a stale instruction, passes a corrected one |

### 2.2 The declaration

```
ENTRYPOINTS="starting a teammate | scripts/spawn.sh | scripts/prepare-agent-spawn.py scripts/create-teammate-worktree.sh; deleting an agent workspace | scripts/workspaces.sh | scripts/remove-agent-worktree.sh scripts/reap-agent-worktrees.sh"
```

Three fields per record: **the task a person is trying to do**, **the command today**,
**what it replaced**. Paths are matched by basename, so an instruction naming the same
script through `$ENGINE_ROOT`, a tilde or a bare relative path is the same instruction.

Two rows, both derived in §1.3 rather than assumed. Row 2 is currently green and still
earns its place: it is what refuses the reintroduction of a retired path into an
instruction two months from now.

### 2.3 The scope, declared beside it

```
INSTRUCTION_SURFACES="CLAUDE.md AGENTS.md CLAUDE.md.template .claude/agents/*.md skills/*/SKILL.md skills/*/*/SKILL.md scripts/hooks/engine-status.sh"
```

**The narrowness is the design.** A reference table, a measurement, an architecture note
and a failure record all name superseded commands legitimately and constantly; a check
that swept them would be waived on the day it landed, and `CLAUDE.md` records three
instances of that pattern in a single day. What made type V expensive was one class: the
instruction that **arrives before any work and is read as current by construction**.

A pattern matching nothing is silent, so one list serves the engine and every governed
repository.

### 2.4 The rule, stated so it can be argued with

> A file declared in `INSTRUCTION_SURFACES` may name a superseded entrypoint only if it
> also names the one that replaced it — or the line carries a substantive
> `entrypoint-exempt: <reason>`.

It is **not** a language check. It does not decide whether a sentence is imperative,
does not grade tone, and has no opinion about prose. A migration note, a release note
and a "we used to do X, now do Y" all name the replacement by construction and pass with
no marker at all.

### 2.5 It changes no guard's behavior

Every superseded path keeps working, keeps its tests, and is in both rows **called by**
the canonical one — `spawn.sh` creates its workspace through
`create-teammate-worktree.sh` and builds its payload through `prepare-agent-spawn.py`.
Breaking the old path would break the new one. This governs what we TELL people.

---

## 3. The completion evidence

### 3.1 The check fails on today's defect (pristine `main`, `082ef5cd`)

```
$ engine/scripts/hooks/contract-integrity-layer-ep.sh --root <engine>
Layer EP (standalone)
  [FAIL] EP. A STANDING INSTRUCTION IN .../engine STILL NAMES A SUPERSEDED ENTRYPOINT. 2 site(s). ...

.../engine/scripts/hooks/engine-status.sh:229: STANDING INSTRUCTION NAMES A SUPERSEDED ENTRYPOINT.
    names:      prepare-agent-spawn.py
    superseded by: scripts/spawn.sh  (task: starting a teammate)
    and 'spawn.sh' appears NOWHERE in this file — so a reader following this instruction
    takes the replaced path and never learns there is another one.
    declared in: .../engine/orchestration.config (ENTRYPOINTS)
    fix: change the instruction to name scripts/spawn.sh. Mentioning prepare-agent-spawn.py
    alongside it is fine — spawn.sh calls the commands it supersedes — and a genuinely
    historical mention takes 'entrypoint-exempt: <reason>' on the line.

.../engine/scripts/hooks/engine-status.sh:229: STANDING INSTRUCTION NAMES A SUPERSEDED ENTRYPOINT.
    names:      create-teammate-worktree.sh
    superseded by: scripts/spawn.sh  (task: starting a teammate)
    [...]

entrypoint-currency-lint: 2 finding(s) across 33 instruction surface(s).
EXIT=2
```

Both superseded entrypoints are named in **one** report. That is deliberate: the failure
class next door (type N) is a check that names one of the two things it enforces, so the
reader fixes that one and is refused again by a rule nobody told them about.

The same lint run against femcboost finds the second site:

```
$ entrypoint-currency-lint.sh --root <femcboost>
.../CLAUDE.md:203: STANDING INSTRUCTION NAMES A SUPERSEDED ENTRYPOINT.
    names:      create-teammate-worktree.sh
    superseded by: scripts/spawn.sh  (task: starting a teammate)
entrypoint-currency-lint: 1 finding(s) across 61 instruction surface(s).
EXIT=1
```

### 3.2 The check passes on a corrected string

Demonstrated in a scratch copy. `engine-status.sh` itself is **never touched** — another
teammate owns that file this session — and the proof of that is in the run: the real
file's count of `spawn.sh` is 0 before and after.

```
$ bash corrected.sh
--- proof the correction is present in the scratch copy, and only there ---
1
--- proof the REAL file is untouched (expect 0) ---
0

########## Layer EP against the CORRECTED scratch copy ##########
Layer EP (standalone)
  [pass] EP. supersession declared as data (4 superseded entrypoints), every standing
         instruction names the current command, and the lint REFUSES a known-bad
         instruction naming file:line while ALLOWING the corrected one (two-sided canary)
EXIT=0
```

One clause changed, and the old names were left in the corrected sentence — because the
correction is additive, and a rule that forced their removal would be wrong.

### 3.3 Zero false positives, measured rather than hoped

Across **94 instruction surfaces in two repositories** (33 in the engine, 61 in
femcboost) the lint returns exactly the two real defects and nothing else. That is the
number that decides whether a check survives: there is nothing to waive on the day it
lands.

### 3.4 The suite

`engine/scripts/entrypoint-currency-lint.test.sh` — **25 cases, 25 green**, discovered
automatically by `run-all-tests.sh`. The paired case is the one that matters: it refuses
the real defect AND passes the corrected string, because a negative test alone is
satisfied by a lint that refuses everything.

It also pins: a bare `entrypoint-exempt:` marker exempts nothing; a blank declaration
stands down **loudly** rather than exiting 0 looking clean; an unparseable declaration is
exit 2, never a green run over an unreadable rule; the superseded script is left
executable and untouched; a `docs/` reference table and a `README.md` are out of scope;
and the working directory cannot rewrite the surface patterns.

---

## 4. What is left to attention, and why

**A check that would have to be waived on the day it lands is worse than no check.** So
the parts that are not mechanized are named here rather than implied away.

1. **Same-file containment is coarse.** A surface that names the replacement *somewhere
   irrelevant* passes. The tighter rules — proximity, or an imperative-verb list — are
   the ones that fire on correct files, and enforced-and-coarse beats
   clever-and-waived. If this ever fails in practice, the fix is a tighter rule with its
   own false-positive measurement, not a stricter default.

2. **Nothing forces a row to be ADDED.** The declaration is only as good as the habit of
   writing a row the day a mechanism is replaced. A check that tried to infer
   supersession from a commit would be guessing at intent, which is the class of defect
   `MODEL_TIERS` exists to end. The mitigation that costs nothing: the row is one line in
   the commit that does the replacing.

3. **No hash sidecar on the parser, deliberately.** Layers MT and MC hash theirs against
   `install.sh`'s explicit manifest list. Adding an entry there makes the probe read RED
   on a freshly merged tree until somebody re-runs `install.sh` — a known trap in this
   repository, and one that teaches people to ignore a red probe. The evidence is in this
   run: 25 of the 26 probe failures on this worktree are "manifest missing or unreadable"
   and say nothing about whether anything works. The two-sided canary proves behavior,
   which is the thing being relied on; a hash proves bytes.

4. **An operator's memory file is out of reach** (§1.4). Nothing in a repository can check
   it.

---

## 5. Landing state

**Superseded by §0.1.** Escalation `esc-20260913T235025Z-65a24aec` said this branch had to
land with or after the `engine-status.sh` fix, because Layer EP was red on `main`. That fix
landed at `953b0369`. **The branch is rebased onto it and Layer EP is GREEN on the engine
(exit 0).** There is no longer a landing-order constraint, and the escalation should be
closed as overtaken rather than acted on.

What remains open is in the other repository: `femcboost/CLAUDE.md:203` still tells Rich to
create every cross-repository worktree with `create-teammate-worktree.sh` and never names
`spawn.sh`. That is a one-clause correction in femcboost, not in this branch, and until it
lands the lint reports it — which is the check doing its job rather than a defect in it.

---

## 6. One more gap, found by the suite and fixed here

The first version of Layer EP scanned **one** root. In an engine-development session the
governed repository and the engine are the same directory, so it looked right and passed.
In the normal by-reference deployment they are not — `REPO_ROOT` is the product repository
and the engine is somewhere else entirely — and `scripts/hooks/engine-status.sh`, **the file
type V was made of**, lives in the engine. A single-root scan would have checked everything
except the announcement, in every session that matters.

It was caught by the integrity suite's own sandbox, where the entity is a fixture with no
instruction surfaces at all: **Layer EP passed there by having nothing to look at.** A layer
that passes because it found nothing to check is the same shape as the defect it is for.

Both roots are now scanned, pinned by a case that fails without the fix. Two smaller
corrections of the same kind came with it, each a thing that was right only because two
values happened to be equal: where the CODE is versus which roots to SCAN (both were
answered with `ENGINE_ROOT`), and executed-versus-sourced (inferred from "is `emit_fail`
defined", which also decided whether to parse arguments, so sourcing the layer into any
shell carrying positional parameters made it refuse them as its own).
