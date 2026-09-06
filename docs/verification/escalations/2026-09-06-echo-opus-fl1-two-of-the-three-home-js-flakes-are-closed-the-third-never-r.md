# Escalation: Two of the three home.js flakes are closed; the third never reproduced, so it is diagnosed rather than fixed

- id: `esc-20260906T083456Z-f98c9544`
- raised: 2026-09-06T08:34:56Z
- from: echo-opus-fl1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-fl1` (branch `echo-opus-fl1`)
- head: `c8b0b1be0200aa879a48b4be80cc55b63c6d6c7a`
- state: **work-complete**
- for: lead

## The question

Do you want the WITH A CORPUS ABOVE THE THRESHOLD race chased further on a deliberately loaded machine, or is a diagnosed timeout enough until it recurs on its own?

## What was already tried

Failures 1 and 2 are closed and measured. Failure 1: 40 theme walks showed 5 of 6 readings bit-identical every walk and only the Enter caption drifting 8.6:1 vs 8.34:1 as the nebula moves behind it; the string-equality assertion is replaced by a per-floor comparison plus a deterministic 53-token computed-style fingerprint with its own staged-leak control. Failure 2: reproduced at 1 in 25 cold launches and closed by waiting for the page own __liveAt record. FAILURE 3 DID NOT REPRODUCE. 20 consecutive standalone runs, a full 26-suite run.js sweep, and a run under RICHOS_SPLASH_LAG_MS=2000 are all green, and I never once saw the 30000ms timeout tom-opus-bs1 hit. I will not claim a fix for something I have not observed. What I did instead: every boot wait in the file now carries an explicit 15000ms budget instead of Playwright undeclared 30000ms default, and on expiry reports the fact it wanted, the page errors already collected, and how far the boot got - because window.RichHome is assigned by a synchronous IIFE at home.js:55 and is absent for essentially one reason, which the old bare timeout could not distinguish from a slow machine. SEPARATELY, A FALSE PREMISE ON MAIN THAT IS WORTH YOUR RECORD: the same corpus check waited for the door border to reach a regex requiring alpha 0.70x, and its comment called rgba(194, 163, 92, 0.706) the resting value. home.css:892 declares alpha exactly 0.7, which serializes as rgba(194, 163, 92, 0.7) and does NOT match that regex. 0.706 is a value the fade passes THROUGH, so that wait was returning mid-fade - the exact thing its own comment warned against - and the door edge contrast row in that check was being measured one frame early on main. It now waits on the transitions own finished state and asserts the value read out of home.css.

## Proceeding meanwhile

Nothing is waiting on the answer. Five atomic commits are on echo-opus-fl1 (775d369, 53532f3, 0a0d535, 473cfad, c8b0b1b), one file, tree clean, every republished screenshot fixture reverted. 20/20 standalone runs green at 34 checks each, and 2 of those 20 hit the exact picture drift that used to fail CONTRAST BOTH THEMES and reported it honestly instead of failing. Full sweep exit 0, 26/26 suites, 537 checks.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T083456Z-f98c9544`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T083456Z-f98c9544 --disposition "<what you decided or did>"
