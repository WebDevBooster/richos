# An unevaluated call must never be silent — the scope, and two things measured first

**2026-09-05 — Zach. The scope declaration and the measurements it rests on. No
guard is wired in the commit that carries this file.**

The survey this implements is
`docs/verification/hook-payload-failure-modes-2026-09-05.md` (landed at `0455c44`).
Its finding, in its own words: *"The instrument is not the read. It is that an
unevaluated call must never be silent."* Thirty of the forty registered
`PreToolUse` and `Stop` hooks exit 0 with nothing on either stream on every
degraded payload, and in sixteen of them a finding observed on a valid payload
vanishes entirely.

The property being built, precisely:

> **The absence of a finding must be distinguishable from the absence of a check.**

No verdict changes. A guard that allows today allows after this. What is added is
a statement about what happened.

---

## First: the open timeout question, settled

The survey could not confirm one number and said anyone acting on the timeout
behavior should settle it first. `zach-opus-st1` measured a blocking hook holding
a headless session for **602 seconds**, which matches the documented 600-second
default rather than the 10-to-30-second values registered in `hooks/hooks.json` —
suggesting the registered `timeout` might not be applied at all.

**It is applied.** Three arms, each a throwaway sandbox project with its own
`.claude/settings.json` — never a live settings file — driven through one real
headless `claude` 2.1.261 session. The hook ticks once a second for 40 seconds and
reads nothing from stdin, so what is measured is the registered timeout and never
an unclosed-stdin block. The last tick recorded says when the host stopped it.

| arm | event | registered `timeout` | last tick | hook killed at | session wall time |
|---|---|---|---|---|---|
| 1 | `PreToolUse[Bash]` | `5` | `TICK 4 elapsed=4.16` | ~5s | 10.26s |
| 2 | `SessionStart` | `5` | `TICK 4 elapsed=4.12` | ~5s | 7.40s |
| 3 | `SessionStart` | *absent* | `TICK 40 elapsed=41.19`, then `COMPLETED` | not killed | 44.11s |

Raw settings, tick logs and session output for all three:
`unevaluated-payload-notice-2026-09-05/raw/timeout-arm*`.

**What that establishes.** A registered timeout IS honored, on the tool-call path
and on the session-start path alike, and arm 1 also confirms the documented
consequence directly: the hook was killed at 5 seconds and the `echo` still ran, so
a timed-out `PreToolUse` hook does not block the call. Arm 3 is the control that
stops arms 1 and 2 passing for the wrong reason — with the `timeout` key removed
the identical hook runs to completion at 41 seconds, so arms 1 and 2 were stopped
by the registered value and not by anything intrinsic to the hook.

**So the 602 seconds is explained without contradicting anything.** Arm 3 proves
only that the default exceeds 41 seconds; 602 is what a 600-second default looks
like with process startup around it. Every hook in `hooks/hooks.json` carries an
explicit 5-to-30-second `timeout`, so the platform bound applies to all of them.
The survey's premise holds: the hang is already bounded and it already resolves as
a pass, which is why the bounded read helps only the two guards that genuinely fail
closed. This is a confirmation of `zach-opus-fc1`'s reasoning, not a correction of
`zach-opus-st1`'s measurement — that hook simply had no registered timeout on the
path it was measured on.

---

## Second: which channel a `PreToolUse` guard can actually be heard on

`scripts/lib/stop-hook-notice.sh` carries this measurement for `Stop` hooks. The
same question had never been answered for `PreToolUse`, and everything below
depends on the answer, so it was measured the same way rather than assumed.

One sandbox project, one `PreToolUse[Bash]` hook writing a unique marker to stderr
AND a different marker as a stdout `{"systemMessage":...}` before exiting 0, one
headless session driven through a single `Bash` call with
`--output-format stream-json`.

| channel, exit 0 | operator stream |
|---|---|
| stderr (`CHANPROBE-STDERR`) | **no** |
| `{"systemMessage":...}` (`CHANPROBE-SYSMSG`) | **yes** |

The systemMessage arrived as

```
{"type":"system","subtype":"informational","level":"notice",
 "content":"PreToolUse:Bash says: CHANPROBE-SYSMSG: predicate not evaluated"}
```

and the stderr marker appears nowhere in the stream. The tool call ran to
completion in the same session — the positive control: a `systemMessage` carrying
no `permissionDecision` leaves the verdict exactly where it was. Raw stream extract
and the hook: `raw/channel-*`.

**This changes one thing in the brief I was given.** `guard-definition-drift.sh` was
named as the template because it "already ships the pattern in three lines of
output". Its shape is right and it is copied. But it announces on **stderr alone**,
and stderr on a zero exit does not reach the operator — so on the channel that
matters its warning has never once been heard. The template needed the measurement
before it could be followed.

The two guards that were already fully right are `guard-ceo-ask-first.sh` and
`guard-ceo-ruled-ask.sh`. Both write stderr AND `systemMessage`, and both say the
useful thing:

> CEO-ASK GATE: could not parse this Agent spawn, so it was not checked and the
> 'ceo-todos-deferred:' escape hatch could not be read either. This ONE dispatch
> is ungated.

That grammar — label, what was not checked, and the scope of the damage — is what
`scripts/lib/unevaluated-notice.sh` copies. Neither of those two guards is rewired
to the library. They are already correct, and the cross-hook suite holds them to
the same words it holds everyone else to, which is a stronger check than making
them share an implementation.

---

## The mechanical cause, which turns out to be one line in every guard

The survey established that seventeen guards never reach their own `PARSEFAIL`
branch. The reason is the same line in each:

```bash
TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c '...' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0
```

On an unreadable payload the extraction fails, `|| true` turns that into an empty
string, and the guard takes the identical silent exit 0 that a well-formed payload
for some *other* tool takes. **"This call is not mine" and "I could not tell whose
call this is" are collapsed into one exit.** Every wiring below separates them
again, at that line, and changes nothing else.

---

## The scope: 27 hooks in, 13 out

Declared here before anything is touched. `notice-unasked-deferral.sh` was fixed
first and alone, at `d65eac2`, because it was the only hook making an
affirmatively FALSE statement rather than merely a silent one.

### IN — the payload is load-bearing for the predicate (19 `PreToolUse`)

| hook | survey verdict | what a degraded payload loses |
|---|---|---|
| `guard-worktree-isolation.sh` | fails open, proven | whether a file-writing spawn is isolated |
| `verify-agent-prompt.sh` | fails open, proven | every spawn-prompt precondition |
| `guard-model-ceiling.sh` | fails open, proven | whether the spawn exceeds the cost ceiling |
| `guard-main-checkout-writes.sh` | fails open, proven | whether the write lands in the main checkout |
| `scan-secrets.sh` | fails open, proven | whether the new content carries a credential |
| `guard-dialect.sh` | fails open, proven | whether the write introduces a non-American word |
| `guard-interactive-prompt.sh` | fails open, proven | whether the command opens an interactive prompt |
| `guard-bash-main-writes.sh` | fails open, proven | whether the command writes into the main checkout |
| `guard-worktree-removal.sh` | fails open, proven | whether the command removes a live worktree |
| `guard-publication-writes.sh` | predicate not evaluated | whether the write crosses the publication boundary |
| `guard-named-persons-writes.sh` | predicate not evaluated | whether the write names a real person |
| `guard-publication-commits.sh` | predicate not evaluated | whether the commit crosses the publication boundary |
| `guard-named-persons-commands.sh` | predicate not evaluated | whether the command names a real person |
| `guard-ceo-todos-commits.sh` | predicate not evaluated | whether the commit leaves the CEO's list stale |
| `guard-completeness-commits.sh` | predicate not evaluated | whether the commit is complete |
| `guard-row-currency-commits.sh` | check lost | whether the commit leaves a row stale |
| `guard-vendoring-commits.sh` | check lost | whether the commit vendors material unrecorded |
| `reader-teammate-hint.sh` | INDETERMINATE in the survey | the hint's whole predicate is `tool_input` |
| `guard-inflight-notify.sh` | INDETERMINATE in the survey | the classifier's input is `tool_input` and `transcript_path` |
| `guard-definition-drift.sh` | payload-independent *(it speaks)* | nothing — but it speaks only on stderr, so nobody hears it |

That last row is why the count above says 19 and the table has 20: the drift guard
loses no check. It is wired because its existing announcement is inaudible, which
is a different defect reached by the same fix.

### IN — the payload is load-bearing for the predicate (8 `Stop`)

| hook | survey verdict | what a degraded payload loses |
|---|---|---|
| `guard-unresolved-claims.sh` | check lost | the turn's unresolved claims |
| `turn-manifest.sh` | check lost | the turn's manifest |
| `notice-hook-staleness.sh` | check lost | the staleness comparison for this session |
| `guard-stated-actions.sh` | fails open, proven | actions the turn stated and did not take |
| `notice-inflight-acks.sh` | INDETERMINATE in the survey | keyed on `session_id` and `transcript_path` |
| `notice-ceo-ruled-prose.sh` | INDETERMINATE in the survey | keyed on `last_assistant_message` |
| `guard-agent-state-claims.sh` | INDETERMINATE in the survey | the whole payload is piped to the analyzer |
| `guard-idle-land.sh` | INDETERMINATE in the survey | keyed on `transcript_path` / `prompt_id` / `stop_hook_active` |

**The eight INDETERMINATE rows are not left indeterminate.** The survey could not
construct a payload that made those hooks produce a finding, so it correctly
declined to call them fail-open. That is a different question from the one that
decides scope, which is whether the payload is load-bearing for the predicate at
all — and that is answered by reading, per hook, in the right-hand column above.
Six of the eight are in. Two are out, below, for a reason that is also read off the
source rather than inferred from the survey's silence.

### OUT — 13, each with the reason

**Three `PreToolUse` guards that do not fail open.**

- `guard-sealed-worktree.sh` — the write barrier, genuinely fail-closed, proven by
  probe Layer Q6. Explicitly out of scope in the brief and untouched.
- `guard-resume-isolation.sh` — genuinely fail-closed. It refuses a degraded
  payload, so there is no silence to remove.
- `guard-workflow-ban.sh` — refuses every `Workflow` call unconditionally. It never
  reads its payload to decide anything, so it has no predicate to leave unevaluated.

**Two `PreToolUse` guards that already do exactly this.**

- `guard-ceo-ask-first.sh`, `guard-ceo-ruled-ask.sh` — both announce on stderr AND
  `systemMessage` on all three degraded payloads. Verified by driving them against
  the real governed root, not read off the survey table. They are the precedent,
  not the work.

**Six `Stop` hooks whose predicate is the REPOSITORY, not the payload.** A degraded
payload costs them nothing, and an announcement would be pure noise — which is the
thing this engine has already decided not to make.

- `notice-mechanical-findings.sh`, `notice-unstarted-rows.sh`,
  `notice-ceo-unasked.sh`, `notice-waiver-repetition.sh` — the four the survey
  measured emitting byte-identical notices on all four payload shapes.
- `notice-escalations.sh` — reads the escalation ledger. It already announces when
  its predicate is unavailable (`ESCALATION WATCH IS OFF`, `ESCALATION WATCH
  PRODUCED NOTHING`), which is this property implemented for a different input.
- `notice-ceo-inputs-unheld.sh` — reads the ingress ledger and re-decides against
  git every turn.

Both of the last two use `session_id` from the payload, but only as a notice
de-duplication key. Losing it makes the notice less well de-duplicated; it does not
make the check not run.

**Two things deliberately not built**, both named in the brief as separate
decisions:

- **The bounded read.** The timeout measurement above is what makes it optional
  rather than urgent: the host already stops a stalled hook and lets the call
  proceed. It would help the two genuinely fail-closed guards by preserving an
  exit 2 the platform timeout would otherwise discard, and no others.
- **The fail-closed template.** Which gates are worth the risk of bricking a live
  session is a judgment that differs per gate, and it has not been taken. Every
  wiring here allows exactly what it allowed before, which is what makes it safe
  to apply across many guards at once.

---

## What was built, and what it measures now

Added after the wiring, so this section reports artifacts rather than intentions.

`scripts/lib/unevaluated-notice.sh` holds the judgment (does this payload parse as a
JSON object?) and the sentence, in the grammar `guard-ceo-ask-first.sh` established.
Twenty-seven hooks source it. `scripts/hooks/unevaluated-payload.test.sh` derives both
inventories from `hooks/hooks.json` and drives every one of the forty:

| class | how it is established | count |
|---|---|---|
| audible — announces on a payload it cannot read | proven by driving it | **31** |
| fail-closed — refuses one | proven by driving it | **3** |
| payload-independent — the predicate is the repository | **declared** in the hook, and the declaration verified by driving it | **6** |
| silent and undeclared | | **0** |

**Only one of those three classes needs a word in its source, and that is the point.**
A refusal and an announcement are positive evidence; a test that drives the hook sees
them and needs nothing else. Silence is not evidence of anything — a hook that is quiet
on all four payloads looks identical whether its predicate never needed the payload or
its predicate was silently lost, which is the whole defect. So payload-independence is
the single class a person has to CLAIM, in the file, where a reviewer sees it, and the
suite then holds the claim to its consequence: the output must be identical across all
four payloads.

`4d` is the case that keeps this from becoming the thing it was built against: a guard
that announced on every call would satisfy everything above and be worthless. Silence
on a payload the guard could read is asserted separately, per hook.

## Two things this work got wrong first, and how

**The sandbox gave a false red for two guards, exactly as the survey warned.** Driven
in a bare sandbox, `guard-ceo-ask-first.sh` and `guard-ceo-ruled-ask.sh` stood down and
landed in the silent-and-undeclared bucket — a failing case for a defect that does not
exist. The survey had already recorded this for the first of the two, and I reproduced
it independently. Both stand down when the repository declares no CEO list, and that
stand-down is correct: a repository with no list has no protection to lose. The suite's
sandbox is now a complete adopter.

**Then the sandbox's declaration was malformed and the guards were blamed for saying
so.** `.ceo-todos` is `KEY=value`; the first version wrote a markdown checklist, and
both hooks reported *"declares CEO TODOs but its declaration could not be read"* on the
CONTROL arm, which `4d` read as noise. They were doing their job. Declared, readable
and satisfied is the one sandbox state that leaves the gate live and the happy path
silent.

Recorded because the survey's own method section makes the same point from the other
side: reading produced a wrong answer twice that day, and driving produced one too. What
caught both here was the control arm — the thing that exists so a case cannot pass, or
fail, for a reason that has nothing to do with what it claims to test.

## Two findings closed on the way, neither of them the task

**`hook-staleness-latest.announced` can no longer be written by a payload nobody could
read.** The survey found this file was the one piece of state a degraded payload could
write, and that writing it suppresses the next real staleness announcement for
everybody; it recorded it as a small finding it did not pursue. With an unreadable
payload `notice-hook-staleness.sh` produced an empty `SESSION_ID`, fell back to that
non-session-scoped marker, and wrote it. It now stands down before reaching that line.

**`guard-completeness-commits.sh` lost its check one step earlier than any of its
siblings.** Before resolving any root it tests the RAW payload for `commit`/`push` and
exits 0 on anything else, so a truncated payload cut before the command never reached
the tool-name dispatch the survey measured. Its notice sits above that filter.

## What is still open, and belongs to someone else

- **The bounded read.** Safe everywhere, worth it for two guards, and unnecessary for
  the reason the timeout arms above establish. Not done.
- **The fail-closed template.** Which gates are worth the risk of bricking a live
  session is a per-gate judgment that has not been taken. Not done, and nothing here
  moves any verdict toward it.
- **`guard-worktree-isolation.test.sh` exits 1** on its embedded clause-7 mutation
  section — 3 properties not proven load-bearing, 4 proven, with `Q05`, `Q07` and `Q09`
  named. Its own 174 cases all pass. **That red is not from this work:** reverting the
  hook to the previous commit and re-running produced byte-identical output.

## What it costs, measured, because the first number was wrong

Sourcing the library and classifying the payload adds one `python3` invocation to a
hook that reaches it. That is not free and it goes on the happy path of guards that
fire on every tool call, so it was measured rather than waved away.

**The first measurement was worthless and said so loudly, which is why it got a second
one.** It ran the reverted hook from a bare temp directory, where it could not find
`scripts/lib/resolve-roots.sh` and exited on the broken-install path in 9.7ms. Against
the wired hook's 83.4ms that read as a catastrophic regression. It was a measurement of
a hook that did nothing.

**Both arms then ran from a full mirror of the engine's `scripts` tree**, so each hook
resolves its libraries exactly as it does in place and the only difference between the
arms is the hook file. Twenty runs each, one warm-up discarded (`raw/cost-harness.sh`):

| hook | unwired | wired | added |
|---|---|---|---|
| `guard-bash-main-writes.sh` | 42.9 ms | 59.9 ms | +17.0 ms |
| `guard-interactive-prompt.sh` | 61.0 ms | 82.5 ms | +21.5 ms |
| `guard-worktree-removal.sh` | 59.3 ms | 74.7 ms | +15.4 ms |

**And the number that decides whether that matters is whether the host runs matching
hooks in parallel or in series.** Ten guards are registered on `Bash`; in series the
added cost of a `Bash` tool call would be about 200ms, which is a regression worth
redesigning for, and in parallel it is about 20ms, which is not.

Measured, in the same sandbox style: five hooks registered on `PreToolUse[Bash]`, each
sleeping two seconds and logging its own start and end.

```
h1 start +0.000s   h2 end +2.033s
h2 start +0.001s   h3 end +2.042s
h3 start +0.007s   h1 end +2.044s
h4 start +0.020s   h5 end +2.059s
h5 start +0.027s   h4 end +2.062s
hook span: 2.06s
```

**Parallel.** All five started within 27ms of each other and the whole set finished at
2.06 seconds rather than 10. So the added cost of this change to a tool call is the
added cost of the slowest guard — about **20 milliseconds** — and not the sum across
the chain. Raw: `raw/parallelism-*`.

That number is why the obvious optimization was NOT taken. Moving each notice below the
guard's own tool-name extraction and firing it only when that extraction came back
empty would put the happy-path cost at zero, and it would mean twenty-seven bespoke
insertions instead of three shared shapes, in files where the dispatch is sometimes in
shell and sometimes inside a python heredoc. Twenty milliseconds is not worth trading a
uniform, checkable block for that. It is written down here so the trade is a decision on
the record rather than something nobody looked at.
