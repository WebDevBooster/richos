# Not blocked — but a premise in the brief is false, and it changes what you can rely on

**Status: the work is done and committed. Nothing is waiting on an answer.** This file exists
because the brief rests on a factual premise that turned out to be wrong, and if you act on the
brief's version of it you will believe you are protected where you are not.

## The false premise

The brief says: build a `PreToolUse[AskUserQuestion]` gate, and *"Reproduce all three of tonight's
failures and show each refused."*

**All three of those failures were PROSE, not `AskUserQuestion` calls.** Verified against the
session transcripts on this machine, not inferred:

| Failure | Where it actually happened |
|---|---|
| Option D / what the customer installs | assistant text, 2026-09-01 22:01:46 — *"**Options:** build your Option D..."* |
| The logo's two tones | assistant text, 2026-09-01 20:01:59 — *"is your mark one color, or does the swoosh get the gold?"* |
| The seven splash screens | assistant text, 2026-09-01 19:45:55 — an **assertion**, not a question |

Every `AskUserQuestion` call ever made on this machine was extracted (18 calls, 27 questions,
2026-07-27 to 2026-09-01). None of them is any of the three.

**So a `PreToolUse[AskUserQuestion]` gate on its own would have caught NONE of the three.** It would
have shipped green over exactly the failure it was built for.

## What I did about it

Built both surfaces rather than one:

- **`guard-ceo-ruled-ask.sh`** — `PreToolUse[AskUserQuestion]`, blocking. The brief's gate. It
  refuses all three questions when they are put through the tool, citing the ruling. That is the
  completion criterion, met.
- **`notice-ceo-ruled-prose.sh`** — `Stop`, non-blocking. The only event that can see a prose ask
  at all. It catches **1 of the 3** (the Option D turn, citing row 3.14 and quoting his standing
  instruction).

## What you must NOT assume

1. **Prose questions are not blocked and cannot be.** There is no PreToolUse event for a sentence
   in a reply. The Stop notice fires *after* the CEO has read the message. It buys you the chance to
   answer from the record before he does — not prevention.
2. **The prose notice catches 1 of 3, not 3 of 3.** The logo question never used the word "logo"
   (it said "your mark"), so no title anchor can reach it. The splash failure was not a question at
   all. Neither is reachable by anything that looks for an ask.
3. **The durable fix for the prose half is behavioral, not mechanical.** The record is already
   carrying that instruction, in your own words at 22:30 that night: *"search the record for an
   existing ruling before putting anything to you."* This mechanism hardens the structured ask and
   reports the prose one. It does not replace the habit.

## One optional follow-up, one line, not done here because it is cross-repo

`femcboost/orchestration.config` could declare the record explicitly instead of relying on the
convention the library falls back to:

```
CEO_RULINGS_PATHS="../richos-hq/wiki/ceo-decisions.md ../richos-hq/wiki/open-items.md CLAUDE.md"
```

Without it the library derives the same three files from the existing `CEO_TODOS_REPOS` declaration
and works today — verified live, and the suite's section 8 proves it against the real record. With
it, a record file that moves becomes a loud BROKEN rather than a quiet convention miss.
