# A premise in this brief is now false: a third red check owns `browser-suites`, and it is not one of mine

**Raised by:** Echo (`echo-opus-ci2`, worktree `/Users/alex/ab/richos-wt/echo-opus-ci2`)
**Date:** 2026-09-05
**Status:** not blocking my own work — both checks I was sent for are fixed and committed. This is
the premise correction, because landing my branch will NOT turn `browser-suites` green on its own.

## What I am raising

My brief names two red checks, taken from run `33957510095` (SHA `486b217`):

* `home.js` — "clicking a number SLIDES the company's name out"
* `splash.js` check 13 — "the splash costs the launch less than one frame"

The brief also told me to check the run on `ccaaf00` before changing anything. **I did, and the red
set had already moved.** Run `33958514507` (`ccaaf00`, 2026-09-05 09:38Z, 18m36s, FAILED):

```
FAIL  5  two launches, two compositions, photographed                        (splash.js)
      splash-01-round-11-v1: the curtain left DURING the exposure —
      this photograph is of the screen behind it
      splash.js — 26 check(s) run, 26 declared, 1 failed
1 suite(s) FAILED: splash.js
```

`home.js` was **green** on that run and so was `splash.js` check 13 (cold +4.0ms, warm +8.5ms,
floor 8.0ms) — which is what "intermittent" looks like, and is exactly why both still needed the
machine taking out of them. I fixed both. **But check 5 was green on `486b217` and is red on
`ccaaf00`, so it is a NEW red, and it is not in my scope.**

## Why I have not fixed it

It is in `settledShot` (`app/ui/tests/splash.js:602`) and in the `shot(... onShutter)` hook in
`app/ui/tests/lib/harness.js` — the shot-writing path `echo-opus-r6` landed at `a3b9145` /
`c00e93e`. My brief says, in as many words: *"do not touch the shot-writing path — that is settled
work."* A wrong fix in another engineer's just-landed area is worse than a named red, and the
choice it turns on (below) is a design call in that area, not a defect with one obvious answer.

## The diagnosis, measured rather than guessed

It is the same class as the two I was sent for — a margin that is comfortable here and not on a
runner — and the margin is arithmetic:

| quantity | value | source |
|---|---|---|
| the hold | 3,000 ms | `app/ui/splash.js`, `SPLASH_SECONDS` |
| the flare, after the bar lands | 950 ms | `app/ui/splash.js`, `FLARE_MS` |
| `state.barStopped` becomes true | hold + flare = **3,950 ms** | `tick()` → `stopTicking()` |
| the ceiling fires | hold + 1,000 ms = **4,000 ms** | `CEILING_GRACE_MS` |
| **the exposure window** | **50 ms** | 1,000 − 950 |

Measured on this machine, one launch held open exactly as check 5 holds it:

```
bar stopped 3942ms into the curtain; curtain went at 3975ms; EXPOSURE WINDOW = 33ms
reason: "ceiling"
```

`settledShot` waits for `barStopped` and then opens a shutter that decodes a PNG in the page. It
has 33–50 ms of curtain left to do that in. This Mac usually makes it; a `macos-latest` runner
whose first instruction after `load` arrives ~2,000 ms late does not.

`HOLD_OPEN` does not save it and is not meant to: it replaces only the **exported** `yieldNow`, and
the ceiling timer holds the internal reference — deliberately, so check 10 can observe the ceiling.
Note also that the window does **not** widen with `seconds`: at `seconds: 5` the bar stops at
5,950 ms and the ceiling fires at 6,000 ms. It is `CEILING_GRACE_MS − FLARE_MS`, always.

Before `a3b9145` this shutter opened at 2,000 ms of a 3,000 ms curtain — about 2 s of margin. The
change from a timer to the bar's own end state is right and fixed a real flake (3,835 pixels of
bar); it moved the shutter into a 50 ms gap as a side effect.

## The smallest question that would unblock it

**Whose call is it to widen the exposure window, and which way:**

1. **Disarm the ceiling for a photograph** — an opt-in beside `HOLD_OPEN` (`opts.noCeiling`) used
   only by `settledShot`'s two callers, so the shutter is not racing anything. Keeps byte
   stability, keeps `after.up` as a guard, weakens nothing else — but it is a new harness patch in
   r6's area, and check 10/12c must keep the ceiling they observe.
2. **Widen `CEILING_GRACE_MS`** past the flare in the product. That changes what ships in order to
   suit a photograph, which I would not do.

I would take (1). I have not, because it is r6's file and my brief fences it.

## What I proceeded on meanwhile

Everything else, and it is done: `splash.js` check 13 is now counts rather than milliseconds (with
13b measuring and printing the milliseconds and `RICHOS_SPLASH_BUDGET_MS` re-arming them), and
`home.js`'s slide check now reads the slide in the pill it happens in, with the two transitions
required to be one declaration. Both are committed on `echo-opus-ci2` with their evidence, the
mutation runs, and what is no longer gated named in the files.
