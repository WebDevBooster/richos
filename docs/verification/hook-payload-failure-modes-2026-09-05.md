# What every PreToolUse and Stop hook does with a payload it cannot read

**2026-09-05 — Zach. A survey, not a fix. No guard was modified.**

Establishes one fact so a decision can be made: for every registered `PreToolUse`
guard and every registered `Stop` hook, what happens when the payload arriving on
stdin is EMPTY, TRUNCATED, or NOT VALID JSON.

Every row was produced by driving the real script with a constructed payload and
recording the exit code, both streams, the wall time and, where it mattered, a
`bash -x` trace. Nothing here was read off the source. The harness and the raw
results are committed beside this file in
`docs/verification/hook-payload-failure-modes-2026-09-05/`.

---

## The population is 40, not 38

The brief says 23 `PreToolUse` guards and 15 `Stop` hooks. `Stop` is 15. `PreToolUse`
is **25**, because two guards were registered earlier today, after the count was
taken: `guard-named-persons-writes.sh` and `guard-named-persons-commands.sh`, both
in `b08f653`. The survey covers all 40. The count moving under a survey in the
same day is itself worth knowing before anyone acts on a list of hook names.

---

## The headline, and it contradicts the brief in both directions

The brief expected the `PreToolUse` guards to fail closed by construction and the
`Stop` hooks to be the dangerous half. **Both halves of that are wrong, and the
first one is wrong in the direction that matters.**

| | `PreToolUse` (25) | `Stop` (15) |
|---|---|---|
| Fails CLOSED | **3** | 0 |
| Fails OPEN — proven (a refusal was observed on a valid payload, and the degraded payload passes) | 10 | 1 |
| Fails OPEN — check lost (a finding was observed on a valid payload and is absent on the degraded one) | 2 | 4 |
| Fails OPEN — predicate never evaluated (the trace shows the analyzer runs on a valid payload and does not run at all on a degraded one) | 7 | 0 |
| Payload-independent (behaves identically on all four; there is nothing to lose) | 1 | 4 |
| INDETERMINATE | 2 | 6 |

**Nineteen of the twenty-five `PreToolUse` guards fail open, and seventeen of
those do it in complete silence** — exit 0, no stdout, no stderr, indistinguishable
from a guard that looked and approved.

Counted the other way, across all 40: **30 hooks exit 0 with nothing on either
stream on every one of the three degraded payloads** (19 `PreToolUse`, 11 `Stop`),
and in **16 of them a finding that was observed on a valid payload vanishes
entirely** (11 `PreToolUse`, 5 `Stop`).

**Three fail closed, and one of the three does not count.** `guard-workflow-ban.sh`
refuses every `Workflow` call unconditionally, so it "fails closed" the way a
wall does; it never reads its payload to decide anything. The two real
fail-closed guards are **`guard-sealed-worktree.sh`** and
**`guard-resume-isolation.sh`**.

**The `Stop` hooks are the safer half, not the dangerous one.** Four of the
fifteen — `notice-mechanical-findings.sh`, `notice-unstarted-rows.sh`,
`notice-ceo-unasked.sh`, `notice-waiver-repetition.sh` — read the REPOSITORY, not
the payload, and emit byte-identical notices on an empty payload, a truncated one
and plain prose. Five lose their check entirely, and those are the five whose
finding comes out of the turn's own text. Only one `Stop` hook can block at all
(`guard-stated-actions.sh`, exit 2), and it fails open.

Full per-hook table: `hook-payload-failure-modes-2026-09-05/table.md`.

---

## What that looks like, in the four cases that carry the argument

**`guard-worktree-isolation.sh` — the spawn gate.** With a well-formed payload for
a file-writing teammate carrying no `isolation`, it refuses with exit 2 and 745
bytes naming the fix. With an empty, truncated or non-JSON payload it exits 0 with
nothing on either stream. The trace: 275 executed lines on the refusal, 129 on
each degraded payload. It does not decide the spawn is safe; it never looks at it.

**`scan-secrets.sh`.** An AWS-shaped key in new content is refused, exit 2. The same
three degraded payloads pass silently — 208 trace lines against 134. Its own header
declares this deliberate: *"FAILS OPEN (passes through, exit 0) on a malformed/
unparseable JSON payload ... a payload that can't be understood isn't itself a
threat to react to."* `guard-main-checkout-writes.sh`, `guard-publication-writes.sh`,
`guard-named-persons-writes.sh` and `guard-dialect.sh` carry the same stated
convention, and `guard-dialect.test.sh` asserts it as case B35.

**That rationale is true only under an assumption the bounded-read scenario
breaks.** "A payload that cannot be understood is not itself a threat" holds if a
payload that cannot be read implies a call that cannot execute. Under a bounded
read the payload is truncated **for the guard only**. The tool call proceeds with
every one of its arguments intact. The guard is reasoning about a call that is
about to happen in full.

**`guard-sealed-worktree.sh` — the one that gets it right.** It refuses on empty,
truncated and non-JSON alike, at 43, 68 and 43 trace lines: it decides before it
does any work. Its design is the template — prove the safe case (a payload that
PARSES and carries no `agent_id` is the lead's), deny everything else, and keep a
read-only tool allowlist so a broken engine cannot brick a running worker.

**`guard-definition-drift.sh` — fails open, but says so.** On every degraded payload
it exits 0 with *"could not parse the Agent spawn payload — agent-definition
freshness NOT verified for this spawn."* Same permissive outcome as the other
seventeen; completely different operational value. This is the cheap fix, already
shipping in one place.

---

## One finding I got wrong first, and how

My first `Stop` run showed empty and non-JSON payloads emitting their notices while
the truncated payload was silent — an alarming asymmetry, and I had started writing
it up as the headline. It was an artifact of my own harness. `stop-hook-notice.sh`
suppresses a repeat of an identical state for the same session, and I had run all
four variants under one session id: the truncated payload carried a readable
`session_id` and was suppressed as a repeat of the control, while the empty and
non-JSON payloads carried none and landed in a different bucket. Re-run with a
distinct session per variant and the notice state cleared between runs
(`sweep6.py`), the asymmetry disappears entirely.

Recorded because the brief says reading produced a wrong answer twice today. Driving
it produced a wrong answer once too — and the thing that caught it was driving it
again, differently.

---

## The platform fact that changes the question

From the Claude Code hooks documentation, on `timeout`:

> Apart from a command hook you run with `async: true`, Claude Code cancels a
> `command`, `http`, or `mcp_tool` hook that reaches its `timeout`, discarding the
> hook's output, so on most events a timed-out hook renders no decision.

and, for this event specifically:

> A timed-out `command`, `http`, or `mcp_tool` hook doesn't block the tool call. The
> call continues through the normal permission flow, **so don't count on a stalled
> hook to act as a gate.**

Three consequences, and they reorder the whole decision.

**1. The hang is already bounded, and it already resolves as a pass.** Every hook
here carries a registered timeout of 10 to 25 seconds. A guard blocked on an
unclosed stdin is stopped at that timeout and the tool call proceeds. The
unbounded `INPUT="$(cat)"` is not protecting anything: it buys a stall, and the
stall ends in the same permissive outcome.

**2. The fear that motivated `zach-opus-st1`'s recommendation does not apply.** It
declined a blanket bounded read because bounding might turn a fail-closed guard
into a fail-open one. It cannot: the platform already converts a stalled guard into
a pass. Bounding the read is **safe for all 40** and cannot make any of them less
safe than it is now.

**3. And it is nearly worthless.** For the 19 guards that already fail open, bounding
changes nothing at all — they pass either way. For the 2 that genuinely fail closed,
bounding is a real improvement, because it preserves their exit 2 in a case where
the platform timeout would otherwise discard it. That is the entire benefit: two
hooks.

**This also names a live conditional hole.** `guard-sealed-worktree.sh` is the write
barrier, it is documented fail-closed, and probe Layer Q6 proves it fails closed on
a bad payload. It is **not** fail-closed against a slow one: if it ever reaches its
15-second registered timeout its verdict is discarded and the write proceeds. Its
own internal `SEAL_WAIT_SECONDS` of 5 already spends a third of that budget. This is
not broken today and I am not touching it; it is the reason the barrier should not
rely on the read being unbounded.

**One number I could not confirm.** `zach-opus-st1` measured a blocking hook holding
a headless session for 602 seconds "with no rescue timeout on that path". 602 is
consistent with the documented 600-second DEFAULT for command hooks, not with the
10-to-30-second values registered in `hooks/hooks.json` — which suggests the
registered `timeout` was not applied on whichever path it measured. I could not test
this without registering a blocking hook, which is a guard change and out of scope.
Anyone acting on the timeout behavior should settle it first.

---

## Why "make them all fail closed" is not available on the Stop side

Measured, not assumed (`probe5.py`, section P2). `guard-stated-actions.sh` with a
violating payload:

| `stop_hook_active` | outcome |
|---|---|
| `false` | exit 2, turn blocked |
| `true` | exit 0, stands down |
| field absent | exit 2, turn blocked |

`stop_hook_active` is the loop brake, **and it arrives in the same payload**. A `Stop`
hook that failed closed on an unreadable payload would also be unable to read the
field that tells it to stop re-firing: absent reads as false, so it would block the
stop, fire again, fail to read again, and block again. **Fail-closed on the `Stop`
side manufactures an unbreakable session.** The `Stop` hooks must fail open. The only
correct treatment there is to make the failure audible.

There is a matching hazard on the notice side. `notice-unasked-deferral.sh`, given a
payload that parses but carries no `last_assistant_message`, emits:

> DEFERRAL WATCH — RUNNING AGAIN. This turn's text was checked for work postponed
> without putting the choice to you.

It did not check the turn's text. There was no turn text to check. **The reassurance
is decoupled from the check** — the exact shape this repository names as a check
reporting green over nothing, and the one place in this survey where a degraded
payload produces an affirmative false statement rather than silence.

---

## Recommendations

Recommendations only. Nothing here was implemented.

**1. Bounding the read is safe everywhere. Do it if the stall is worth removing, and
do not expect it to buy security.** It cannot make any of the 40 less safe. It helps
exactly two — `guard-sealed-worktree.sh` and `guard-resume-isolation.sh` — by
preserving an exit 2 the platform timeout would discard. If it is done, a bounded
read must be paired with the rule below, or a truncated payload becomes a silent
pass in 17 guards instead of a visible stall.

**2. The change worth making is not the read. It is that an unevaluated call must
never be silent.** Nineteen `PreToolUse` guards and eleven `Stop` hooks currently
exit 0 with nothing on either stream on every degraded payload, and in sixteen of
those a finding observed on a valid payload disappears. This is independent of
stdin and independent of bounding: it is what happens whenever the payload is not
what the guard expected, for any reason at all. `guard-definition-drift.sh` already
shows the shape in three lines of output. Applying that pattern is mechanical, low
risk, changes no verdict, and converts the entire silent class into an audible one.

**3. For the small number where a silent pass is genuinely dangerous, adopt the
`guard-sealed-worktree.sh` template rather than a bounded read.** Prove the safe
case, deny the rest, keep an allowlist so a broken engine cannot brick a session.
The strongest candidates by what was observed here, in order:

- `guard-worktree-isolation.sh` — silently permits an unisolated file-writing spawn.
  Every downstream worktree guarantee starts at this gate.
- `verify-agent-prompt.sh` and `guard-model-ceiling.sh` — same event, same silence.
- `scan-secrets.sh` — the credential barrier, and the only one whose failure is
  irreversible once the bytes are on disk.
- `guard-interactive-prompt.sh` — the guard that exists because a password window
  appeared on the CEO's screen at 02:01.

Which of these should change is a judgment about how much brick-risk is acceptable
at each gate, and the answer differs per hook. That is the decision this survey was
run to inform; it is not mine to take.

**4. Do not make any `Stop` hook fail closed.** See the table above. `stop_hook_active`
travels in the payload the hook cannot read.

**5. Fix the one affirmative false statement.** `notice-unasked-deferral.sh` should
not say the turn's text was checked when there was no turn text. Announce that it
could not check, or say nothing.

**6. `guard-workflow-ban.sh` is not evidence that the fail-closed pattern is
adopted.** It refuses everything unconditionally. Counting it as a fail-closed guard
overstates the current posture by a third.

---

## The eight INDETERMINATE rows, named rather than collapsed

For these I established the degraded-payload exit code as fact — all exit 0 — but
could not construct a payload that made the hook produce a finding, so I cannot say
whether a real violation would be missed. They are neither fail-open nor fail-closed
on this evidence.

`PreToolUse`: `reader-teammate-hint.sh` (fired on no prompt shape tried, though
`READER_TEAMMATE="reed"` is configured); `guard-inflight-notify.sh` (reaches its
"nothing in flight" exit at line 341 under a synthetic session id — note separately
that its classifier resolves a parse failure to `PASS` at line 281, which is a
fail-open in one line, but I did not observe the contrast).

`Stop`: `notice-inflight-acks.sh`, `notice-ceo-ruled-prose.sh`, `notice-escalations.sh`,
`guard-agent-state-claims.sh`, `guard-idle-land.sh`, `notice-ceo-inputs-unheld.sh` —
each silent on the control as well as on all three degraded payloads.

---

## Method, and what it is worth

- Two entity roots: an isolated sandbox and the real governed checkout. The sandbox
  alone gave a false reading for `guard-ceo-ask-first.sh`, which stood down there for
  an environmental reason and refuses at exit 2 against the real root. Every verdict
  above is from the real-root run.
- Every violating payload was padded with a long trailing field and cut inside the
  padding, so the violating bytes survive the truncation and only the JSON structure
  is destroyed. That is the shape a bounded read produces.
- `bash -x` trace step counts distinguish "evaluated and found nothing" from "never
  looked" for hooks whose control produced no refusal.
- State was snapshotted before and after. The run created 16 files under
  `femcboost/.claude/state`, all namespaced to the synthetic session; all were
  removed and the directory listing verified byte-identical to the pre-run snapshot.
  `sweep6.py` removes each notice-state file it creates as it goes and reports zero
  leftovers.

Reproduce: `python3 docs/verification/hook-payload-failure-modes-2026-09-05/sweep2.py`
(degraded matrix), `sweep3.py` (violation controls), `sweep4.py` and `sweep6.py`
(traces and the corrected `Stop` run), `probe5.py` through `probe8.py` (the targeted
questions). `table2.py` regenerates `table.md` from the recorded JSON, so no number
in the table is transcribed by hand.
