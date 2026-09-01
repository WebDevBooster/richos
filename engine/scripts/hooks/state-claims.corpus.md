# The false-positive corpus for the STATE-CLAIM arms of `guard-unresolved-claims.sh`

A blocking guard that is wrong gets waived, and a guard that is waived habitually
is a formality with a hook attached. The CEO has twice said a guard was overkill
and been right both times. So before this one was allowed to `exit 2`, its rate
was measured on real turns, and the measurement is reproducible by anyone who
doubts it.

This file exists for a second reason too. Three of the four shapes that were
proposed for this gate **failed** the measurement and are not shipped as
blockers. What follows is as much the record of what was refused as of what was
built.

## What the gate was built for

On 2026-09-01 three untrue things were told to the CEO as fact in one session:

1. a commit SHA that was **typed rather than read** — `bede2010c9a03…` against a
   real tip of `bede2010650b…`, so the first eight characters matched and the
   invented hex passed his own eye;
2. a merge that **never executed** — `git merge … && git push` was one Bash call,
   a PreToolUse guard refused the whole call at its first step, and the turn
   reported `round-11.2` as landed. He found out by opening the file and getting
   `ERR_FILE_NOT_FOUND`;
3. a value called **"gone from the entire app"** when only `#8F7030` had been
   replaced and the decimal `rgb(143,112,48)` — the same value — survived.

One cause under all three: **the report was written from the INTENT of a command
rather than from the artifact.**

## The corpus

**Every turn in every real orchestrator transcript on this machine.** Not a
sample, not a hand-picked set, and not turns written for this purpose.

| | |
|---|---|
| Source | every `~/.claude/projects/-Users-alex-*/` directory (scratchpad sessions excluded) |
| Session files read | **79** |
| Turns replayed | **2,276** |
| Turns carrying a final assistant message | **2,206** |
| Span | 2026-07-27 15:08 UTC → 2026-09-01 21:38 UTC |
| Measured | 2026-09-01, against the shipped `guard-unresolved-claims.py` |

Scratchpad sessions are excluded for the reason `idle-land.corpus.md` excludes
them: a throwaway session in a temp directory is not a turn this gate governs,
and several hundred of them would dilute the rate with traffic the predicate can
never fire on.

## Regenerating it

Each turn is a `promptId` span, and the message under test is the **last
assistant text block in that span** — which is what `last_assistant_message`
carries at Stop time. Sidechain records are skipped: a subagent's turn fires
`SubagentStop`, not `Stop`, so this gate never sees it.

Every claim is then resolved with the functions the hook itself uses —
`state_claims`, `state_verdict`, `value_absence_claims`, `surviving_spellings` —
against the repositories under `~/ab`.

## Shape 1 — LANDED / MERGED / ON MAIN: **SHIPPED, BLOCKING**

A sentence asserting integration, carrying a SHA-shaped token. The SHA must be an
ancestor of `main`/`master` (local or `origin/`) in some repository that holds it.

The whole state-claim class — a landing word **or** a push word, next to a SHA —
is 573 sentences and 658 SHA citations across the 2,206 messages. Of those 658,
585 resolve to a commit that is integrated today and 73 resolve to nothing
reachable (absent objects and rewrite casualties, both silent by construction).

| | |
|---|---|
| state-claim sentences carrying a SHA | **573** |
| SHA citations inside them | **658** |
| fires against the repositories as they stand today | **0** |
| fires when each turn is replayed against the repository **as it stood at that turn's own clock** | **1** |

**0.15% of citations. 0.045% of turns.**

### The relaxation that got it there, and the number that justifies it

The first version tested ancestry alone and fired **41 times**. Every one of the
41 was in `prospects`, and every one was a casualty of that repository's history
rewrite: the commit was real and on `master` when it was cited, the rewrite moved
`master` to different objects, and the old commit survives in the object DB
reachable from nothing. `Merged to master as 80cc943 and pushed` was true when
written and is unprovable now.

So the gate requires the commit to be **alive on a ref** before it will say
anything. A commit reachable from no ref at all is a rewrite casualty and this
gate has nothing truthful to say about it — it is silent. That one condition took
41 fires to 0, and it is not a tuning knob: **"on a branch that is not main" is a
state a history rewrite cannot manufacture.** It is exactly the state the
2026-09-01 failure left behind.

### The historical replay, and why it was necessary

Measuring only against today's repositories flatters the gate: a claim that was
false when made and merged an hour later reads as true now. So every citation
that is integrated today was re-checked against **when it entered `main`** — the
earliest commit on the branch's first-parent chain that contains it, which is the
ref's own update history — and compared with the turn's own timestamp, with ten
minutes of slack for a merge that happens inside the turn the report closes.

Of 585 integrated citations, **584 were already on `main` when the claim was
made.** The one exception:

> `Three fixes landed (d0c68bb)` — the commit reached `master` 19 minutes later.

By this engine's own doctrine that claim was premature rather than true. It is
counted as a **false positive anyway**, because grading it the other way would be
grading my own work.

**Two things this replay cannot reconstruct, named rather than hidden:** which
refs existed at that moment (so "alive on a branch then" is inferred from "on
main now, and it got there later"), and any repository that has since been
deleted. Both bias the count toward *fewer* fires, so the true rate could be
marginally higher than 1 in 658 — not lower.

## Shape 2 — PUSHED: **SHIPPED, BLOCKING**

A sentence asserting publication, carrying a SHA. The commit must be reachable
from a remote-tracking ref; a fire means it is reachable only from a local
branch, i.e. committed and still on this machine.

Measured on its own predicate over the push-sentence subset of the same corpus:

| | |
|---|---|
| SHA citations in push claims | **407** |
| reachable from a remote ref | 362 |
| reachable from nothing (rewrite casualties, silent by construction) | 45 |
| reachable from a local branch only | 0 |
| **fires** | **0** |

## Shape 3 — REMOVED / GONE / ZERO REFERENCES, in general: **NOT ENFORCEABLE**

Take any removal sentence, take the literal it cites, grep for it.

| | |
|---|---|
| absence sentences | 337 |
| ...carrying a checkable literal | 70 |
| literals checked | **109** |
| **fires** | **95 (87%)** |

Every kind of false positive is in there, and they are structural rather than
tunable:

* the **doc that records the removal** — "I removed `BLOCKED.md` from the root",
  and `BLOCKED.md` is named in four agent definitions;
* the **claim scoped to one place, grepped everywhere** — "`#e4dfd3` appears
  nowhere in `round-9/v1`" is about one directory;
* the **ordinary word** — `main`, `customer`, `founded`, `---`;
* the **rename**, where the old name legitimately survives in the file that
  explains the new one.

87% is not a rate you tune down. It reports; it does not block.

## Shape 4 — a value gone in a spelling the claim did not name: **NOT ENFORCEABLE**

This is failure 3 exactly, and it looked like the sharp version of shape 3. The
claim names a value; the gate expands it to every spelling (`#8f7030`,
`#8F7030`, `rgb(143, 112, 48)`, `rgba(143,112,48`) and greps for the ones the
claim did **not** name — so a doc quoting the cited token cannot satisfy it.

Measured over the corpus it fired **once, on the real failure**, and stayed silent
on the only other value-absence claim there was. That reads like a perfect gate.

**It is not, and the reason is worth writing down.** The surviving
`rgb(143,112,48)` it found is in femcboost's `CLAUDE.md` — the file that
**documents this very incident**. The one true positive was scored against a
record written after the fact. Circular, and worth nothing as evidence.

So the risky half was measured on its own, across every value citation in the
corpus rather than only the absence claims:

| | |
|---|---|
| sentences naming a value | 28 |
| values cited | **41** |
| ...for which an alternate spelling survives somewhere | **22 (54%)** |

The grep half fires on more than half of all value citations. The only thing
holding this predicate back from firing constantly is how rarely an English
absence word lands next to a value — and `no longer`, `removed` and `gone` sit
next to color values in design talk all day. Blocking on that is a wolf-crier
waiting for its first design round.

**It reports, and the report is still worth having:** it names the surviving
spelling and the file, which is the one fact the 2026-09-01 turn did not have.

## What is deliberately not caught

* **A state claim with no SHA in it.** "Everything is landed and pushed" names no
  identifier, so there is nothing to resolve. Reading that sentence for intent is
  the 17%-precision approach this gate was built to replace.
* **A claim about a repository this machine does not hold.** Silent.
* **The claim as it appeared in a `SendMessage`.** This is a `Stop` hook; it reads
  the turn's final message. The fabricated SHA of 2026-09-01 went out in an
  in-flight notice first and was only caught when it reached the reply.
* **Anything after the turn ends.** A point-in-time check: it proves the claim was
  true when it was made.

## The cost of a fire, stated as the objection

A fire costs one turn, structurally: `stop_hook_active` is true on the re-fire and
the gate stands itself down, so a given turn can be refused **at most once**. The
worst case is not a wedged session; it is one more turn, in which the answer is
either to run the merge or to say where the work actually is. And the refusal
names the branch the commit is really on, so the correction is a paste rather than
an investigation.
