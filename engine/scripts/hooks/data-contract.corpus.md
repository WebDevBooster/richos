# The corpus that re-specified the data-contract dispatch gate

`verify-agent-prompt.sh` check 5 refuses a spawn that will run the local app
without citing an install-fresh script. Until 2026-09-15 it decided that on a QA
verb plus a platform noun, and **that predicate was on the wrong side of its own
question**: the common case — a dispatch that never goes near the app — was the
one made to pay, every time, in a typed paragraph of justification.

This file is how that was established, and how to re-establish it. Every number
below names the command that produced it.

## The ledger, corrected

```
$ wc -l /Users/alex/ab/femcboost/.claude/state/data-contract-bypasses.log
     920
$ grep -c 'data-contract-bypass:' .../data-contract-bypasses.log
     486
```

**The file is 920 lines and 486 of them are waivers.** The other 434 are
`verify-test-bash` records written by the retired every-Bash-call data-contract
test gate, which shared this file — they are not waivers, they were never typed
by anyone, and a line count reads them as if they were. The design document that
ordered this work quoted **917**, which is the file's length, and so did the
brief. The real figure is 486, and it is still the largest waiver ledger in the
engine (`ceo-todos-defers.log`, the next one, is 426).

```
$ sed -E 's/.*data-contract-bypass:[[:space:]]*//' ... | sort -u | wc -l
     174          # distinct reasons -> 64.2% of the 486 are repeats
```

## The corpus

**Every Agent spawn prompt in every femcboost session transcript on this
machine.** Not a sample and not briefs written for this purpose — it is what
this orchestrator actually dispatched, including the brief that ordered this fix.

| | |
|---|---|
| Source | `~/.claude/projects/-Users-alex-ab-femcboost/*.jsonl`, `tool_use` entries named `Agent` or `Task` |
| Transcript files | 51 |
| Spawn prompts | 968 |
| Window | 2026-08-01 → 2026-09-15 (no femcboost transcripts survive from before that) |
| Measured against | the shipped hook, twice: `HEAD` and the re-specified working tree |

Scoped to the femcboost project directory on purpose: this gate is opt-in
(`ENABLE_QA_INSTALL_FRESH_GATE`) and femcboost is the only repository that turns
it on, so a dispatch anywhere else never reaches it.

## What the old predicate did, driven through the shipped hook

```
hook:              HEAD (old predicate)
prompts driven:    968
qa-gate REFUSALS:  9
qa-gate BYPASSES logged: 69
TOTAL FIRES:       78
```

**78 fires. 0 citations. 78 waived or refused.** Not one of the 78 was a
dispatch that tests or renders the app: the 69 bypassed ones say so in their own
words, and the 9 refusals are engine work, repository ports and infrastructure —
each of which was then re-sent with a bypass line. The satisfaction path this
gate exists to enforce was taken **zero times in 968 dispatches**, because the
prompts that tripped it were never app work.

A gate whose escape hatch is its only exit is not protecting anything; it is
charging a toll. This project has three guards (`g11`, `g12`, `g13`) that died
of exactly that, all recorded on one day.

**It also tripped on itself.** `install-fresh` is in both of the old regexes but
is not what `INSTALL_FRESH_SCRIPTS` accepts, so *discussing* the contract was an
automatic refusal. **27 of the 78 fires would not have happened at all had that
one token been absent from the app-context list** — a fifth of this gate's whole
lifetime output is the gate reacting to its own name.

The brief that ordered this fix was refused by this gate for quoting the gate's
own predicate, and the only way through was the hatch:

```
$ tail -1 .../data-contract-bypasses.log
2026-09-15T08:07:50Z  agent=mark  data-contract-bypass: this task never runs,
renders, installs or tests the Avelor or fitapp application. It is engine work …
```

## What the re-specified predicate does, same hook, same 968 prompts

```
hook:              working tree (inverted)
prompts driven:    968
qa-gate REFUSALS:  1
qa-gate BYPASSES logged: 10
TOTAL FIRES:       11
```

**78 → 11, a 85.9% reduction in fires, and 0 new fires.** The new predicate is a
strict narrowing — both original conjuncts are still required — so it cannot
fire anywhere the old one was silent, and the 67 fires it drops are, one for
one, prompts that were bypassed or refused-then-bypassed in life.

Two clauses do the work:

| clause | what it asks | fires it removes |
|---|---|---|
| REACHABILITY | can this dispatch reach *this repository's* app at all? A `cross-repo-worktree:` line naming another repository's workspace is structural proof it cannot. | 53 |
| EVIDENCE | does the prompt name an app RUNTIME (`APP_RUNTIME_RE`) — or is the role one whose job IS the app (`QA_ROLE_AGENTS`)? Naming a platform is not exercising an app. | 14 |

409 of the 968 dispatches (42%) declare a workspace in another repository. That
is the single largest class, and no prose was ever needed to identify it.

**The absent-path branch is the one that runs in life.** `spawn.sh` evaluates
every PreToolUse[Agent] guard *before* it creates the workspace, so at the
deciding evaluation the path is a promise, not a directory. Requiring it to
exist leaves 33 of the 78 fires standing; deciding the absent path leaves 11.

## Expected effect on the ledger

```
$ python3 - <<'PY'   # counts waivers in the replayable window
  waivers in the window (>= 2026-08-01): 66  = 1.43/day = 20.1 per two weeks
  same window at the 11/78 fire ratio:    9  = 0.20/day =  2.7 per two weeks
PY
```

The design's standing rule is that any gate still waived more than 50 times in
two weeks is re-specified or removed. This gate is at **20 per two weeks** today
and lands at **about 3**. The 420 waivers written before 2026-08-01 cannot be
replayed — their transcripts are gone — so no reduction is claimed for them;
their reasons are dominated by `convex-only UDF unit test, no local app touched`
(105 of them), which names no runtime and would be silent under the new
predicate, but that is an inference and it is marked as one.

## Regenerating all of it

Three steps. The second matters: **a prototype is not the artifact** — an early
draft of these numbers came from a python re-implementation of the predicate,
and it was only trustworthy once the shipped hook produced the same 78.

1. **Extract the prompts.** Walk `~/.claude/projects/-Users-alex-ab-femcboost/*.jsonl`,
   keep every `tool_use` whose `name` is `Agent` or `Task`, and write
   `{ts, subagent_type, prompt}` per line.
2. **Build a hermetic entity root.** `git init` a temp directory, copy
   femcboost's `orchestration.config` into it, and point the hook at it with
   `VERIFY_REPO_ROOT_OVERRIDE`. **This is not optional.** The gate appends every
   accepted bypass to `$ENTITY_ROOT/.claude/state/data-contract-bypasses.log`,
   so a replay aimed at the real root writes hundreds of fabricated waivers into
   the ledger you are measuring. That happened during this work — 79 lines, all
   between 08:30 and 08:31 on 2026-09-15 — and they were removed by truncating
   the file back to its 920 real lines. Assert the live ledger's line count is
   unchanged before and after every run.
3. **Drive every prompt through the hook**, old and new, with
   `VERIFY_QA_GATE_OVERRIDE=1`, and count `qa-install-fresh-precondition-missing`
   in stderr plus the lines appended to the hermetic ledger. Refusals plus
   bypasses is the fire count; the exit code is not, because other checks in the
   same hook refuse the same payload for their own reasons.
