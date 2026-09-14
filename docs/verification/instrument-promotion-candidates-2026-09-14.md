# Which instruments are cheap enough to run at land time, and what each would have caught

**Task:** wire the hook-registration check at the land, and report which INSTRUMENTS deserve
promotion. **The first half was not done, because it was already done.** The second half is below.

Every number here carries the command that produced it. Runs are from
`/Users/alex/ab/richos-wt/zach-opus-landgate1` at HEAD `0f223eaa`, macOS 24.6.0.

---

## 1. The first half of the task was already built, twelve hours before the land it would have refused

Raised as `esc-20260914T211915Z-aca67745`, state `proceeding`. Summary of the re-derivation:

**The brief's reproduction is stale.** It quotes `exit=1`, *"4 places owing"*. Current:

```
$ engine/scripts/hook-registration-completeness.sh --root . --baseline c495a7b9^
COMPLETE: every derived inventory names every subject.
exit=0
```

The four owed places were paid by `87ce52ff`, `2646df81`, `0f223eaa`.

**"Nothing ran it" is false.** `engine/scripts/hooks/guard-hook-registration-commits.sh` is a
BLOCKING `PreToolUse[Bash]` guard on commit **and** push that calls the predicate. Both files
arrived in the same commit:

```
$ git log --diff-filter=A --format='%H %ci %s' -- engine/scripts/hooks/guard-hook-registration-commits.sh
d49b9344 2026-09-14 08:09:34 +0100 A check that fires when a hook registration is WRITTEN, not when CI runs
```

**It is registered on both surfaces**, since `c730240e` at 08:10:13 — `engine/hooks/hooks.json:260`
and `engine/.claude/settings.local.json:292`. The land that broke CI was `c495a7b9` at
**20:25:04**, twelve hours later.

It already satisfies every constraint the brief asked me to add: it refuses rather than warns; its
hatch is `hook-inventory-ack: <reason>` with a 20-character minimum, logged to
`~/.claude/state/hook-inventory-acks.log`; its cost is measured in its own header (142 ms at commit,
68 ms for the predicate alone, best of 9); its suite is 34 cases.

**So the live defect is not a missing gate. It is a registered blocking gate that did not fire.**
`tom-opus-hook9` had already written the same sentence: *"the guard that calls it,
guard-hook-registration-commits.sh, is registered and did not stop the land."* The hatch log does not
exist, so the guard was not waived — it was never consulted. Diagnosing that is a different task and
I did not start it.

---

## 2. The census, re-derived rather than quoted

The census is not a table — it is `engine/scripts/check-census.py`.

```
$ /usr/bin/time -p python3 engine/scripts/check-census.py \
    --engine-root engine --entity-root /Users/alex/ab/femcboost --format tsv
real 0.32 / 0.26 / 0.27   (three consecutive runs)
72 rows
```

| class | brief said | **re-derived** |
|---|---|---|
| CONTROL | 36 | **37** |
| INSTRUMENT (person 27 + author 2) | 29 | **29** |
| RECORD | 6 | **6** |

**CONTROL is 37, not 36.** The population grew by one: `guard-brief-scope.sh` landed at `c495a7b9`
after `sage-opus-c1` wrote the census. This is the ordinary way a counted row goes stale — the census
re-derives in 0.3 s precisely so that it cannot.

---

## 3. What it costs to promote an instrument: nothing

**Fourteen of the 29 instruments are already registered on `Stop`** — and the census's own host table
records, as measured, that a `Stop` refusal refuses the turn end. They are not instruments because
they run too late to act. **They are instruments by choice.**

Timed with a minimal `Stop` payload, three runs each, best and worst in ms
(`scratchpad/time-instruments.sh`, all exit 0):

| instrument (`Stop`) | best | worst |
|---|---|---|
| `turn-manifest.sh` | 64 | 67 |
| `notice-ceo-inputs-unheld.sh` | 65 | 69 |
| `notice-ceo-ruled-prose.sh` | 65 | 67 |
| `notice-ceo-unasked.sh` | 65 | 68 |
| `notice-unstarted-rows.sh` | 65 | 67 |
| `notice-waiver-repetition.sh` | 65 | 68 |
| `notice-mechanical-findings.sh` | 66 | 68 |
| `notice-protected-ref-moves.sh` | 66 | 68 |
| `notice-unasked-deferral.sh` | 66 | 68 |
| `notice-unlanded-branches.sh` | 67 | 68 |
| `guard-agent-state-claims.sh` | 68 | 74 |
| `notice-escalations.sh` | 69 | 69 |
| `notice-inflight-acks.sh` | 70 | 96 |
| `notice-hook-staleness.sh` | 71 | 94 |

**Total 926 ms best-case — and it is already being spent at every turn end.** Promotion adds zero
wall time. The budget question the brief raises does not arise for these fourteen; only the
false-positive question does.

Excluded from timing deliberately: `observe-created-refs.sh`, `workspace-lifecycle.sh`,
`snapshot-agent-definitions.sh`, `snapshot-enforcing-hooks.sh` — they mutate lifecycle state, and
timing them would have written it.

---

## 4. The candidates, with the failure each maps to

Escalations raised 2026-09-07 to now, from `~/.claude/state/escalations.jsonl`
(`scratchpad/cluster.py`): **112 in the last week**, out of 211 in the ledger's history.

| instrument | ms | last-week escalations on its subject | evidence |
|---|---|---|---|
| **`notice-unlanded-branches.sh`** | 67 | **28** | every one titled *"Finished work is neither landed nor held for a reason: richos cc/…"* |
| **`notice-hook-staleness.sh`** | 71 | **4** | incl. *"Two hooks landed on main non-executable … two registered guards load nothing"*; *"Two CI hooks are wired in the plugin manifest but not on the engine's seated surface"* |
| **`guard-agent-state-claims.sh`** | 68 | — | no last-week instance found; its recorded instance is 2026-08-31 |
| **`notice-waiver-repetition.sh`** | 65 | — | no last-week instance found |

### The one with the evidence behind it: `notice-unlanded-branches.sh`

**25% of every escalation raised this week (28 of 112) is the condition this instrument watches.**
It reports that condition and refuses nothing.

**An honest complication, and it changes the recommendation.** Those 28 were not raised by the
instrument. `actor` on all of them is `land-disposition.py`, and
`grep -n escalate engine/scripts/hooks/notice-unlanded-branches.sh` returns nothing. So the condition
is already escalated by a *second* tool while the instrument beside it stays quiet — two checks on one
condition, neither of which refuses. That is worth fixing for its own sake, and it means the promotion
is cheaper than it looks: the escalation path already exists and already fires.

### What I am NOT claiming

For `notice-hook-staleness.sh` I have the subject match and the escalation text; **I did not run the
instrument against the tree as it stood at each failure**, so "would have caught it" is inference from
subject, not a measurement. Marked so rather than asserted. Settling it costs one checkout per
incident and I did not spend it.

---

## 5. The recommendation, and the one that should not be taken

**Promote `notice-unlanded-branches.sh` to a `Stop` refusal with a
`unlanded-branch-ack: <reason>` hatch.** It is the only candidate where the count is large (28), the
subject is unambiguous (a branch is merged or it is not — no prose, no intent), the cost is already
paid (67 ms, already at every turn end), and the escalation machinery already exists.

**Do not promote the `notice-ceo-*` family.** Four of them read prose for intent — deferral phrasing,
unheld inputs, unasked questions. That is exactly the predicate class this project rejected three
times in one afternoon, where the fix on the day is always to waive and habitual waiving is how a
guard dies while still looking installed. They should stay instruments, and that is not a defect.

**The census should be the gate, not this page.** A list of promotion candidates in a document is the
failure type this task was dispatched against. `check-census.py` re-derives in 0.3 s and already
classifies every check; the durable version of this finding is a threshold in the census, not a
paragraph in `docs/verification/`.
