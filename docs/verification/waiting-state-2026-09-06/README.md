# "It looks like a crashed application" — what the waiting state actually showed, and what it shows now

**Author:** Echo (Rust & Tauri desktop engineer). **Date:** 2026-09-06.
**Branch:** `echo-opus-wt1`, cut from `934f127`.

The first outside user of RichOS, relayed verbatim by the CEO on 2026-09-06:

> *"One thing from a quality perspective, it takes a lot of time to get a reply, a lot of
> spinning wheels waiting. … no interaction of feedback, so it looks like a crashed
> application."*

The defect is not the latency. It is the silence during it: a person who cannot tell a
working app from a dead one stops trusting it before the reply ever arrives.

---

## 1. Method

`drive-wait.js` runs the **shipping** renderer (`app/ui/index.html`, `main.js`,
`timeline.js`, `style.css`) under **WebKit** — the engine Tauri renders through on macOS —
and drives a long turn the way a long turn really behaves:

- `send_message` **never returns**. That is not a simulation of a stall; it is the shipping
  contract. `send_message` resolves only when the turn ends, so for a turn's whole duration
  the screen is driven by events and by nothing else.
- The `rich://turn-status` events are the spine's own, in the spine's own order:
  `queued` (with `startedAt: null`) then `working` (with the ledger's `startedAt`), which is
  what `spine.rs` `submit_prompt` and `run_turn` emit.
- Events are delivered through the callbacks `main.js` registered with
  `window.RichBridge.listen`, captured by wrapping the bridge as `mock.js` assigns it. **No
  renderer function is ever called directly**, so every frame is the DOM a real event
  produces.
- Both themes, seeded through the store `theme-boot.js` actually reads, with the painted
  `data-theme` asserted before any frame is taken.

No audio path is touched: headless WebKit, no voice mode, no output device.

```
node drive-wait.js [outDir] [--pw=/path/to/node_modules/playwright]
node gaps.js            # the inter-event measurement in §5.1
node mark-contrast.js   # the contrast arithmetic in §5.2
```

Frames: `frames-before/` (at `934f127`, before the change) and `frames/` (after).
Machine-readable readings: `readings.json` in each.

---

## 2. What a person saw, BEFORE — 2s, 10s, 30s, 60s

Every frame below is a full 1280x860 window. `frames-before/silent-{dark,light}-*.png`.

| t | On screen | Anything moving? |
|---|---|---|
| **2s** | His own message, and one line reading `Working` — 14px, `--ink-soft`, top-left of the conversation. Everything below it is ~400px of empty page. | A 5px dot, `--accent`, breathing its opacity between 0.2 and 0.7 |
| **10s** | Identical, except the line now reads `Working for 8s` | The same dot |
| **30s** | Identical, except `Working for 28s` | The same dot |
| **60s** | Identical, except `Working for 58s` | The same dot |

**The four frames differ by two characters.** The word "Working" and a number in 14px
`--ink-soft`, in the corner of an empty region, is the entire answer to *"is this thing
alive?"* — and it **scrolls away with the conversation**: a CEO who scrolls up to re-read his
own question takes the app's only sign of life off the screen with him.

And the dot — the thing his report calls a spinning wheel — **failed the 3:1 non-text
contrast floor for most of its life.** Measured, both themes, in §5.2.

`frames-before/readings.json` also records the case that matters most: with a real activity
row and real streaming text arriving, the screen said **exactly the same thing**
(`Working for 10s`, `Working for 11s`). There was no channel between "Rich is doing
something specific" and the CEO at all.

---

## 3. What a person sees, AFTER

`frames/silent-{dark,light}-*.png`, same driver, same instants.

| t | The band, directly above the composer |
|---|---|
| **2s** | ● **Rich is working** — *Nothing has come back yet* |
| **10s** | ● **Rich is working** · **8s** — *Nothing has come back yet* |
| **30s** | ● **Rich is working** · **28s** — *Nothing new for 28s* (attention tone) |
| **60s** | ● **Rich is working** · **58s** — *Nothing new for 58s* (attention tone) |

With work actually happening (`frames/active-*`):

| moment | The band |
|---|---|
| an activity row arrives | ● Rich is working · 2s — **Read the Q3 board pack** (the backend's own `summary`, verbatim) |
| 8s later, nothing since | ● Rich is working · 10s — Read the Q3 board pack **· 8s ago** |
| text starts streaming | ● Rich is working · 11s — **Writing the reply** |
| 27s of silence after that | ● Rich is working · 38s — **Nothing new for 27s** |

The band sits at the top of `#composer-zone`, so it is on screen at **every scroll
position** — which the duration row is not.

**Every moving thing in it is a fact.** The clock moves because time passes. The mark
flashes **once per arriving event** and never on a loop, so with nothing coming back it goes
still. A spinner that keeps spinning after the process dies is the exact lie that produced
the report; this band is structurally incapable of it.

---

## 4. The dead turn looks different from the slow one

`frames/dead-{dark,light}-0{1,2,3}-*.png`.

| moment | Screen |
|---|---|
| 6s in | ● Rich is working · 4s — Nothing has come back yet; duration row `Working for 4s` |
| `rich://turn-status: failed` | **band gone**; duration row `Stopped after 6s`; the §21 failure card: *"I hit a snag mid-thought and had to stop — say the word and I'll pick it back up."* with a **Pick it back up** button |
| 5s later | unchanged — nothing re-reassures on the next tick |

The terminal status is a **positive** signal (continuity §5.2 — death is never inferred from
silence), and it is what removes the band. Nothing in this feature can keep saying "Rich is
working" over a failure card.

**One harness limitation, stated rather than discovered later.** The dead scenario emits
`rich://turn-status: failed` and deliberately **not** `rich://turn-error`. `turn-error`'s
listener calls `loadTimeline()`, which re-reads `get_timeline` — and the browser mock never
recorded this turn, because the whole scenario rests on `send_message` never returning. In
the shipping app the prompt is fsync'd `received` before anything else (`spine.rs`
`submit_prompt`, persist-before-send), so that reload returns the CEO's message and the
failed turn. Under this harness it returns an empty thread and blanks the screen back to the
greeting — a picture of the mock's empty ledger, not of RichOS. `turn-status: failed` is the
event that draws the failure treatment (`main.js` says so at the `turn-error` listener), and
it is what these frames measure.

---

## 5. Why the numbers in the code are the numbers they are

### 5.1 The quiet threshold: 25 seconds, from measured traffic

`QUIET_AFTER_MS` decides when the band stops describing the last thing it saw and starts
naming the silence. It is derived from the five committed **real** `claude-agent-acp` runs in
`../acp-emission-probe-2026-08-28/run{1..5}.raw.jsonl`, which carry an `atMs` on every
inbound message. Gaps between consecutive inbound messages during the prompt phase, plus each
run's `session/prompt` to first-inbound gap (`node gaps.js`, n=192):

```
run1  inbound=47  prompt->first=30ms  span=13292ms  maxGap= 2174ms  medianGap= 16ms
run2  inbound=32  prompt->first=35ms  span=22481ms  maxGap= 6427ms  medianGap=649ms
run3  inbound=73  prompt->first=32ms  span=30608ms  maxGap= 7090ms  medianGap= 50ms
run4  inbound=23  prompt->first=32ms  span=33330ms  maxGap=20741ms  medianGap=705ms
run5  inbound=17  prompt->first=38ms  span= 3949ms  maxGap=  981ms  medianGap= 17ms

p50 62ms   p90 894ms   p95 1119ms   p99 7090ms   max 20741ms
over 5s: 4     over 10s: 1     over 20s: 1
```

A **healthy** turn has gone **20.7 seconds** with nothing observable arriving. Any threshold
under that would call working turns quiet. 25,000ms clears it with margin.

It is a **presentation** threshold only. *"Nothing new for 41s"* is true at every value this
constant could take, so no number here can make the band say something false — only something
differently emphasized.

### 5.2 Contrast — computed, both themes, 3:1 and 4.5:1

`node mark-contrast.js`, using `app/ui/tests/lib/contrast.js` — the same arithmetic
`app/ui/tests/contrast.js` runs against the real DOM. Backgrounds are `--paper`, which is
`--ground` (`#0c1322` dark, `#eae6dd` light); `#composer-zone` paints it and nothing sits
between.

**The failure this found in shipped code.** `.tl-pulse` — the ONE mark in the timeline saying
the app is alive, and the thing the user's report calls a spinning wheel — was `--accent` at
`opacity: 0.55`, animating between 0.2 and 0.7:

```
old .tl-pulse (--accent)  dark   0.2 -> 1.40:1 FAIL   0.45 -> 2.48:1 FAIL   0.55 -> 3.11:1   0.7 -> 4.31:1
old .tl-pulse (--accent)  light  0.2 -> 1.22:1 FAIL   0.45 -> 1.60:1 FAIL   0.55 -> 1.79:1 FAIL   0.7 -> 2.14:1 FAIL
```

In dark it failed for the part of every 1.8s cycle spent under ~0.55. **In light it never
cleared the floor at any point of its cycle**, and under `prefers-reduced-motion` — where it
was pinned at 0.7 — it sat at 2.14:1 permanently.

Fixed by giving the mark its own token at **full opacity in both themes** and animating its
**size** instead, which cannot dilute a ratio:

```
--live-mark   dark  #c2a35c -> 7.68:1 PASS      light #715715 -> 5.48:1 PASS
--attention   dark  #e09a55 -> 7.88:1 PASS      light #8c4a1b -> 5.42:1 PASS   (quiet state)
```

**The band's own text**, against the same ground:

| element | token | size | dark | light | floor |
|---|---|---|---|---|---|
| `.wait-head` | `--ink` | 18px | 14.55:1 | 14.90:1 | 4.5:1 |
| `.wait-time` | `--ink-soft` | 18px | 6.47:1 | 5.86:1 | 4.5:1 |
| `.wait-detail` | `--ink-soft` | 16px | 6.47:1 | 5.86:1 | 4.5:1 |
| `.wait-detail` (quiet) | `--attention` | 16px | 7.88:1 | 5.42:1 | 4.5:1 |
| `.wait-mark` | `--live-mark` | 10px | 7.68:1 | 5.48:1 | 3:1 |
| `.wait-mark` (quiet) | `--attention` | 10px | 7.88:1 | 5.42:1 | 3:1 |

Nothing in the band is claimed as exempt except **one** thing, declared here and again in
`style.css`: the flash **ring** (`wait-mark--flash`'s `box-shadow`) is decoration that
repeats what the solid dot beside it already says. It carries no information, it is
`aria-hidden` with its host, and it fades to transparent by design. The dot it expands out of
holds 7.68:1 / 5.48:1 at every instant.

The mark also carries `data-contrast-role="indicator"`, which puts it under the shipping
`tests/contrast.js` gate at 3:1 in both themes rather than only under this feature's own
suite — an indicator no gate walks is exactly how `.tl-pulse` reached 1.40:1 unnoticed.

---

## 6. What each thing on screen is derived from — nothing is fabricated

| Element | Derived from | Could it be wrong? |
|---|---|---|
| `Rich has your message` / `Rich is working` / `Rich is picking this back up` | the four live `rich://turn-status` values, and nothing else | No — it is the ledger's own transition, read back out of the ledger before it is emitted |
| the elapsed number, while working | `RichTimeline.durationRow(turn, now)` — the **same** function the timeline's duration row calls, so the two can never show two ages for one turn | No |
| the elapsed number, while queued | `now - acceptedAt`, this window's own clock, because the ledger has no `started_at` yet; the headline says whose clock it is (*"Rich has your message"*, not *"working for"*) | No |
| `Read the Q3 board pack` | the backend's `summary` on `rich://activity-upserted`, relayed **verbatim** | No — nothing here composes, shortens or interprets it |
| `Writing the reply` | `rich://message-started` / `message-delta` arriving. It claims text is arriving and nothing more — `phase` is `unknown` on every message this runtime emits (`live.rs`), so naming a *kind* of writing would be inventing one | No |
| `· 8s ago` / `Nothing new for 41s` | `now - lastAt`, where `lastAt` is the wall-clock instant of the last event **the timeline accepted for the thread on screen** | No — the fence has already refused everything belonging elsewhere |
| `Nothing has come back yet` | zero accepted content events, on a turn this window watched from its start | No — and on a turn it joined late it says `Nothing new for {d}` instead, because it did not watch the beginning and must not report on it |
| the mark flashing | one flash per accepted event, restarted per event; never a loop | No |

**Not present, deliberately:** any percentage, any step count, any estimated completion, any
invented step name. There is no source for any of them —
`../acp-emission-probe-2026-08-28.md` §4-5 records the complete union of what the adapter
emits, and nothing in it says how much of a turn is done.

---

## 7. Open, and named rather than quietly absorbed

1. **`.tl-pulse` is fixed but not gated.** Its color and animation are corrected in
   `style.css` and the arithmetic is above, but the span is created in `app/ui/timeline.js`
   and adding `data-contrast-role="indicator"` to it would need an edit to that file, which
   was outside this task's scope. Until then the shipping contrast gate does not walk it.
2. **The empty middle is still empty.** The band answers *"is it alive, what is happening,
   how long has it been"* at the bottom of the screen. The ~400px of blank conversation above
   it is unchanged; filling it would need something true to put there, and on a silent turn
   there is nothing.
3. **A hung-but-alive turn cannot be distinguished from a dead one that emitted no terminal
   event.** Both read as `Nothing new for {d}`, which is the honest limit: the app is told
   about death by a positive signal and by no other route, so the longer the silence runs the
   louder the count gets, and the number never stops being true.
