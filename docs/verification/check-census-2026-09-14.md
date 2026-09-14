# The check census: which of this engine's checks can act, and what to do about the ones that cannot

**Asked by the CEO, 2026-09-14, verbatim:** *"what would be the best mechanism(s) for implementing
that: for each check in this engine, does a refusal, a hold, or a re-open follow from a finding — or
does it only say so? That census is cheap and would separate the controls from the instruments."*

**Answer, in one line: the census is a script, it is committed, it found one live defect and that
defect is already fixed — and the only new mechanism worth building is a refusal at the moment a check
is WRITTEN, because nothing can decide for you which instruments deserve promotion.**

The trap this had to avoid was named in the brief and it is real: a census that produces a list nobody
acts on IS failure type AB, the thing it exists to measure. So the census is not a table in this page.
It is `engine/scripts/check-census.py`, it re-derives in about a second, it cannot go stale the day a
check is added, and it has a suite that drives hooks rather than reading its own reasoning.

---

## 1. What was measured, and with what

```
engine/scripts/check-census.py --engine-root <engine> --entity-root <repo> [--format table|tsv|json] [--sites]
```

Run for this record from `/Users/alex/ab/richos-wt/sage-opus-c1/engine` with
`--entity-root /Users/alex/ab/femcboost`. Full output, every refusal site with its line and its
classification, is in `check-census-2026-09-14-logs/census-with-sites.txt`; the machine-readable form
is `census.tsv`.

**Nothing in the census is typed.** The population comes from `hooks/hooks.json`. The refusal sites come
from the sources. The hatch ledgers come from the guards, by IMPORTING
`scripts/hooks/notice-waiver-repetition.py`'s own discovery rather than keeping a second copy of it.
The waiver counts come from disk.

### The one constant, and why it is declared rather than derived

What the HOST does with a refusal is a property of Claude Code, not of this repository, so it cannot be
derived here. It is one table in the tool, every row carries its evidence, and every row carries a
`verified` flag that the report prints:

| event | what a refusal does | measured in this repository? |
|---|---|---|
| `PreToolUse` | refuses the tool call | yes — in production continuously |
| `Stop` | refuses the turn end | yes — `scripts/lib/stop-hook-notice.sh` lines 44-47 |
| `PostToolUse` | **refuses nothing** | yes — `notice-claim-capability.sh` lines 248-262 |
| `TaskCompleted` | refuses the completion | **NO** — claimed by one hook's own header, nothing else |
| `UserPromptSubmit` | refuses the prompt | **NO** — no engine hook relies on it |
| `SubagentStop` | refuses the turn end | **NO** — no registered hook exercises it |
| `SessionStart`/`SessionEnd`/`SubagentStart`/`TeammateIdle` | nothing | **NO** — assumed |

### Why "does it exit 2?" is the wrong question

**Of the 221 refusal sites in the 70 registered hook scripts, 149 are FAIL-CLOSED SELF-FAILURE** — the
check refusing because it cannot run (a missing library, an absent `python3`, an unparseable payload).
That refuses nothing about the thing it watches. **72 are findings.** A `grep -c 'exit 2'` census would
have called `notice-escalations.sh` a control; it has three `exit 2` strings and not one of them fires
on an escalation.

The separation is derived from the corpus, not invented: clustering the sites by the identical text of
their five preceding code lines puts 80 of 221 in six fragments appearing in five or more different
files — the shared bootstrap, which `contract-integrity-probe.sh` Layer R already asserts is
byte-identical. `--sites` prints every classification with its file and line, so any one of them can be
checked by hand.

---

## 2. The census — counts over stated denominators

**Denominator: 76 registrations, 71 distinct checks** (70 scripts plus one inline `echo` in
`hooks.json`). This is the population that runs automatically in a session. Suites, probe layers and CI
workflows are a different population and are treated in §6.

### Column 1 — does a finding change what happens?

| class | count | what it means |
|---|---|---|
| **CONTROL** | **36** | a finding refuses: the call, the turn end, or the completion |
| INSTRUMENT (person) | 27 | says so, on `systemMessage`, which the operator sees |
| RECORD | 6 | appends to an event log; nothing blocking reads it |
| INSTRUMENT (author) | 2 | says so, on `additionalContext`, which only the acting agent sees |
| INERT | 0 | — and this was **1** before the fix in §4 |

**Thirty of the 36 controls sit on `PreToolUse`.** Five sit on `Stop` (`guard-ci-turn-gate`,
`guard-idle-land`, `guard-stated-actions`, `guard-unresolved-claims`, `guard-workspace-gate`). One sits
on `TaskCompleted` — `task-completed-handoff.sh`, whose entire authority rests on a host behavior this
repository has never measured (§5).

### Column 2 — is the action waivable?

**12 of the 36 controls carry a named escape hatch this census can attribute to them.** The guards
declare **23** hatch ledgers between them; the census attributes **18** to a specific registered check.
The other five are written through a shared library and the scan cannot name an owner: `ceo-ruled-exempts.log`,
`inflight-waivers.jsonl`, `owned-state-acks.log`, `owned-state-dispositions.log`, `stop-work-acks.jsonl`.

### Column 3 — how often has each hatch actually been taken?

Counted on disk across `~/.claude/state`, the eleven session team directories, and
`/Users/alex/ab/femcboost/.claude/state`. **1,968 waivers in total, against 12 controls.**

| hatch ledger | entries | the control it waives |
|---|---|---|
| `data-contract-bypasses.log` | 917 | `verify-agent-prompt.sh` |
| `ceo-todos-defers.log` | 384 | `guard-ceo-ask-first.sh` |
| `resume-acks.log` | 234 | `guard-resume-isolation.sh` |
| `ci-red-acks.log` | 113 | `guard-ci-red-lands.sh` |
| `worktree-remove-acks.log` | 112 | `guard-worktree-removal.sh` |
| `model-ceiling-acks.log` | 75 | `guard-model-ceiling.sh` |
| `main-checkout-runs.log` | 46 | `guard-worktree-isolation.sh` |
| `definition-drift-acks.log` | 35 | `guard-definition-drift.sh` |
| `unevaluated-payloads.log` | 32 | `guard-definition-drift.sh` |
| `definition-drift.log` | 16 | `guard-definition-drift.sh` |
| `stop-work-acks-used.log` | 2 | `guard-stop-live-work.sh` |
| `generic-agent-dispatches.log`, `hand-roll-acks.log` | 1 each | `guard-worktree-isolation.sh` |
| `hook-inventory-acks.log`, `stale-staging-acks.log`, `vendoring-acks.log`, `model-downgrade-acks.log`, `conceal-acks.log` | 0 | never used |

**`guard-ci-red-lands.sh` is the clearest instrument wearing a control's clothes.** 113 acks in five
days, 28 of them today:

```
grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' ~/.claude/state/ci-red-acks.log | sort | uniq -c
  16 2026-09-10   22 2026-09-11   34 2026-09-12   13 2026-09-13   28 2026-09-14
grep -oE '[a-z0-9-]+\.yml' ~/.claude/state/ci-red-acks.log | sort | uniq -c | sort -rn
  55 engine-self-verify.yml   40 windows-companion-ci.yml   10 engine-run-record.yml
   4 ui-suite-ci.yml           4 app-voice-ci.yml
```

Its own refusal text would currently read *"THIS IS ACK NUMBER 55 FOR THIS WORKFLOW"*
(`guard-ci-red-lands.sh:762`). `notice-waiver-repetition.sh` already flags it, and its verdict is the
right one and is not this census's to re-litigate: **the fix is in the guard, not in the next waiver.**

---

## 3. The escalation mechanism, which is the archetypal instrument and is not exempt

**109 escalation records.** `grep -h -m1 -- '- state:' docs/verification/escalations/*.md | sort | uniq -c`:
**79 `work-complete`, 28 `proceeding`, 1 `stopped`.**

Restricted to the 14 whose title names a false premise — the type-AB measurement — the brief's premise
re-derives exactly: **10 `work-complete`, 4 `proceeding`, 0 `stopped`.**

```
ls docs/verification/escalations/ | grep -iE "premise|is-false|are-false|is-not-broken|wrong"   # 14
for f in $(...); do grep -m1 -- '- state:' "$f"; done | sort | uniq -c                          # 10 / 4
```

**And nothing acts on any of them.** `escalations.jsonl` is a RECORD; its two readers
(`session-start-escalations.sh`, `notice-escalations.sh`) are both INSTRUMENT (person). No control in
the engine reads the escalation ledger at all:

```
grep -ln 'escalat' engine/scripts/hooks/guard-*.sh engine/scripts/hooks/verify-*.sh engine/scripts/hooks/scan-*.sh
```

returns two files and both matches are incidental prose — `guard-inflight-notify.sh:79` ("the operator
escalates") and `guard-interactive-prompt.sh:13` ("macOS escalates"). **Zero controls, 109 escalations.**

---

## 4. What the census found, and what was done about it the same night

### 4a. A notice speaking on the one channel measured to reach nobody — FIXED

`session-start-ci-surface.sh` classified **INERT**: it neither refused, nor announced on an audible
channel, nor recorded. Its own header says it exists because the CI gate and the CI watch *"put no
single word in front of a person"* — and it wrote its entire notice to **stderr with exit 0**, which the
engine's own measured table says renders to NO ONE on every event.

Reproduced while it was holding a live finding:

```
bash engine/scripts/hooks/session-start-ci-surface.sh < payload.json >out 2>err
out: 0 bytes        err: 223 bytes, "=== CI SURFACE ===  CI IS RED — 1 workflow(s) ..."
```

(`check-census-2026-09-14-logs/ci-surface-before-fix-stderr.txt`.)

It now emits the pair `session-start-escalations.sh` uses — `systemMessage` for the operator and
`additionalContext` for the model. After the fix, the same payload yields 220 bytes on each audible
channel and nothing on stderr (`ci-surface-after-fix-stdout.json`).

**The suite was asserting on the silent channel,** which is how eight green cases sat over a notice
nobody ever saw. Its runner now reads the operator-visible text, so every existing case asserts what it
always asserted about a channel somebody reads, and a new case N9 is the regression test for the defect
itself.

| run | result | log |
|---|---|---|
| new suite, fixed hook | **9 of 9 pass** | `ci-surface-suite-after-fix.txt` |
| new suite, reverted copy of the hook | **7 of 9 FAIL**, N9 quoting the finding sitting on the silent channel | `ci-surface-suite-reverted-copy.txt` |
| `contract-integrity.test.sh --only base` | 11 of 11 pass, exit 3 (scoped-and-green) | `contract-integrity-only-base.txt` |

### 4b. Two names that contradict their code

- **`reader-teammate-hint.sh` is a CONTROL.** Its own line 3 says *"PreToolUse guard (Agent)"* and it
  blocks the spawn. A file called `*-hint` refuses tool calls.
- **`guard-agent-state-claims.sh` is an INSTRUMENT.** Correct by design — `CLAUDE.md` says it "reports
  the contradiction at turn end, but it is a backstop, not the check" — and the `guard-` prefix says
  the opposite to anyone who has not read it.

Neither is a defect today. Both are evidence that **the naming convention is not a usable declaration
of class**, which is the load-bearing input to the recommendation in §7.

### 4c. One control's authority rests on an unmeasured host behavior

`task-completed-handoff.sh` is the engine's only control outside `PreToolUse` and `Stop`. Its header
says *"a refused proof exits 2 so the native task remains open with remediation"* (line 12). Nothing in
this repository measures whether `TaskCompleted` exit 2 holds a task open.
`grep -rn "remains open\|task stays open" engine/scripts/` returns that header and nothing else. **If
that assumption is wrong, the delivery gate is an instrument and nobody would know.**

### 4d. The hatch watcher names the wrong owner for one hatch

`notice-waiver-repetition.py`'s source scan does not strip comments, so `inflight-waivers.jsonl` is
credited to `notice-waiver-repetition.py:457` — which is a **comment describing how the real writer
resolves its path**. The real writer is `scripts/lib/inflight.py:500`, reached from
`guard-inflight-notify.sh`. The consequence is visible in tonight's report: *"SUSPECTED BROKEN GUARD:
notice-waiver-repetition.py"*, naming the watcher as the owner of a hatch it does not write. The census
drops any attribution whose site is a comment line, and says which
(`waiver-repetition-report.txt` is the unmodified report; the census's `discovery_notes` names the drop).

---

## 5. Promote, keep, retire

**Retire: nothing.** All 71 checks either act or are read. The one that was neither was fixed rather
than removed, because it had a live finding.

**Keep as they are: all 35 non-controls** — 29 instruments and 6 records. Every one of them either
reports to a person on the measured operator channel, or hands the acting agent a line it can act on, or
appends to a durable log, and for each of them the non-blocking choice is argued in its own source. `notice-waiver-repetition.sh` makes the argument best and it holds: the evidence was never
missing, it was never READ, so the artifact that changes the outcome is the arithmetic done
automatically on the channel that reaches the operator.

**Promote: exactly one candidate, and it is not an instrument in the hook population.**

The escalation ledger. Not by blocking the ENGINEER — the 10 `work-complete` records are engineers who
did everything right, and refusing their work would punish the wrong party. **The act belongs on the
LEAD, and the verb the CEO named for it is `re-open`.** The narrow form: a `Stop` gate that refuses the
lead's turn end while an escalation naming a false premise in a live dispatch is unacknowledged, exactly
as `guard-unresolved-claims.sh` already refuses a turn end. Denominator for the narrowest version
(`state: stopped` only) is **1 of 109**, so it cannot wedge a session.

**It is not built here, and deliberately: it changes what a check refuses, which this pass was scoped
out of, and it is one dispatch.**

Three other promotions were considered and rejected: `guard-ci-red-lands.sh` (already correctly flagged
by the waiver watcher; its fix is a re-tune of the guard, not a class change);
`notice-hook-staleness.sh` (a stale registration is not worth wedging a session for);
`handoff-facts-annotate.sh` (PostToolUse — the host ceiling forbids it, whatever anyone wants).

---

## 6. What this census does NOT cover, stated plainly

- **Suites, probe layers, CI workflows and commit-time predicates are a different population.** They are
  reachable as controls only through `guard-ci-red-lands.sh`, whose refusal has been waived 113 times —
  so the honest statement is that **CI is a control on paper and an instrument in practice on this
  machine**, and that is column 3 doing its job rather than a separate census.
- **Five hatch ledgers have no attributable owner** (§2), so their waivers are counted in the ledger
  totals and not against a named control.
- **Seven of the ten host-ceiling rows are unverified** (§1). One of them carries a real control (§4c).
- **Removals are not watched.** A check deleted from `hooks.json` leaves this census silently smaller.

---

## 7. The mechanism — what to build, and what it does when it finds something

### The four options, weighed

| option | act | why not / why |
|---|---|---|
| **the census printed on a cadence** | none | this is type AB with extra steps. The engine's own reasoning (`stop-hook-notice.sh`) is that identical text under every turn is text the eye is trained to skip. 71 rows under every session is wallpaper by the second day. **Rejected.** |
| **a probe layer that refuses when a control-claiming check cannot act** | refuses a land, via CI | right predicate, wrong altitude: it fires after the land, on `main`, and its enforcement runs through the hatch that has been taken 113 times. Type X's whole lesson is that CI is where the author finds out too late. **Rejected as the primary.** |
| **a check must DECLARE its class; a check fails if declaration and behavior disagree** | refuses the commit | **CHOSEN**, in the narrow form below. |
| **nothing new** | — | too strong. There WAS a live defect, it had been invisible for the life of the hook, and no existing check could have found it. **Rejected — but only just, and §5 is why: nothing needs retiring and only one thing needs promoting.** |

### The recommendation

**Put the class check in the commit guard that already fires on exactly these files, and add no new
hook.** `guard-hook-registration-commits.sh` already refuses a commit that touches
`engine/scripts/hooks/*.sh` or `hooks/hooks.json` without completing the registration inventories. It
is a `PreToolUse` refusal — the strongest act available, at the moment of authoring, with a named hatch
that has been taken **0** times. Extending its predicate costs one more derived question and, critically,
**no new registration**: type X says every new hook must be added to four inventories nobody enumerates,
so the cheapest correct mechanism is one that adds no hook.

The added question, in the form the census already answers:

1. **A check declares its class in a header line** — `CHECK-CLASS: control | instrument | record` — and,
   if `control`, the act (`refuse-call` / `refuse-turn-end` / `refuse-completion`).
2. **The commit is refused when the declaration and the derived behavior disagree**, in either
   direction: a check claiming `control` with no finding-refusal path, or on an event whose host ceiling
   is `none`; and a check declaring `instrument` that in fact refuses.
3. **The declaration is required only of a check the commit ADDS or MODIFIES.** The existing 71 are
   back-filled once, from `check-census.py --format tsv`, in a single commit. Nobody edits 71 files by
   hand and nobody has to.

The reason this shape and not a survey: **the naming convention is already a declaration and it is
already wrong twice** (§4b). Making the declaration explicit and binding costs one line per check and
removes the class of error the census exists to find.

### What it does when it finds an instrument that should be a control

**Nothing — and that is the answer, said plainly rather than dressed up.**

Promotion is a design decision. A refusal has a false-positive class, it needs a hatch, the hatch needs
a reason, and someone has to own what happens when it fires at three in the morning. **No mechanism can
make that decision, and a mechanism that pretended to would be worse than the gap.**

What the mechanism guarantees is narrower and is the part that is actually broken today: **a check's
class can never again be absent, wrong, or discovered a year later.** The promotion question gets asked
of a person at the moment the check is written, when it costs one line, instead of being asked by the
CEO after reading the second half of a sentence.

**So, honestly: this is not a mechanism that promotes instruments. It is a mechanism that makes it
impossible to ship a check whose authority nobody stated.** If that reads as a smaller answer than the
question implied, the smaller answer is the true one, and §5 is the evidence: across 71 checks the
census found one thing to fix, one thing to promote, and nothing to retire. **The engine does not have a
population of detectors wired to nothing. It had one, and it has none now.**

---

## 8. Every relayed premise in the brief, re-derived

| premise | verdict |
|---|---|
| 10 of 14 false-premise escalations are `work-complete` | **TRUE**, re-derived exactly (§3) |
| `PostToolUse` exit 2 refuses nothing | **TRUE**, and sharper: it reaches the acting agent under a "BLOCKING ERROR" banner while blocking nothing (`notice-claim-capability.sh` 248-262) |
| stderr + exit 0 reaches nobody | **TRUE** (`stop-hook-notice.sh` 20-32), and it cost this engine a live notice — §4a |
| `systemMessage` is the only person-audible, event-agnostic channel | **TRUE** for the operator. `additionalContext` reaches the MODEL on every event, so "reaches nobody" is wrong about it; the distinction matters and is why the fix in §4a emits both |
| one guard's refusal reported it had been acked 26 times; a dozen more followed in one session | **NOT REPRODUCIBLE as stated** — the count is a point in time and has moved. What is reproducible: `ci-red-acks.log` holds 113 entries, 55 for one workflow, 28 added today (§2) |
| `notice-waiver-repetition` reads 22 hatch ledgers | **FALSE by one, and the direction matters: it is 23.** `python3 engine/scripts/hooks/notice-waiver-repetition.py --engine-root engine --json` → `len(hatches_declared) == 23` |
| the signature mapping in column 1 | **TRUE where the brief stated it, incomplete where it did not.** `TaskCompleted` refusal is a real signature the brief did not name, and the one control using it rests on an unmeasured assumption (§4c) |

---

## 9. What was committed

| | |
|---|---|
| `engine/scripts/check-census.py` | the census, derived; `--format table\|tsv\|json`, `--sites` |
| `engine/scripts/check-census.test.sh` | 5 cases; C2 and C3 drive hooks and compare exit codes to the verdict |
| `engine/scripts/hooks/session-start-ci-surface.sh` | the channel fix (§4a) |
| `engine/scripts/hooks/session-start-ci-surface.test.sh` | runner reads the operator channel; N9 added |
| `docs/verification/check-census-2026-09-14-logs/` | census output with every site, the TSV, both suite runs, the scoped probe run, and the before/after channel bytes |

**For the land:** the hook body change means `install.sh` has to rerun after the merge, or the
gitignored `.sha256` sidecars leave BR4 red.
