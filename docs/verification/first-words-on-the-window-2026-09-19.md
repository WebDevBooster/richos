# The six seconds between his Send and the turn's clock — found on the real window, and removed

**2026-09-19 · branch `cc/echo-opus-sixsec1` · CEO ruling §55
(`richos-hq` `wiki/ceo-decisions.md`), continuing
`docs/verification/2026-09-19-nightly-1.2.0-nightly.20260919.1-mac-and-android-rewalk-audit.md`
§2 (Ray, candidate .12) and `docs/verification/first-words-2026-09-18-primed.md`**

*"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
*"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not."*

**Typed only. Nothing was played through the speakers — no `say`, no `afplay` (CEO §53). One
instance per measurement, quit before this was written (CEO §54 addendum 4).**

---

## 1. The headline

| on the REAL window, brand-new thread, one typed job | before | after |
|---|---|---|
| his keystroke → the turn's clock starting | **18.6 s** | **12 ms** |
| the longest single wait a window command paid for the spine | **18 314 ms** | **0 ms** |
| send → his first words on screen | not reached inside a 25.5 s capture | **9.62 s** |

Both runs are the same debug build of this branch, the same scratch machine, the same one
typed job. The debug build's spare front desk costs 17–34 s where the shipped candidate's
costs 5.4 s, so the *shape* is the finding and the absolute seconds are this build's.

---

## 2. Where the seconds went — and the diagnosis is in Ray's own committed log

Candidate .12's `app.log` carries four lines whose **order** is the whole of it:

```
[richos] a front desk is primed and waiting for the next new thread in qa-test-co:  5378 ms
[richos] the front desk is ready before he types: 0 ms
```

The second line is `get_timeline` → `ready_the_front_desk`, and `get_timeline` is a call
`ui/main.js`'s `openThread` makes **on the way to his Send**. It printed *after* the spare
because it had been queued behind it.

`create_thread_in` (which the Send handler calls, `ui/main.js`'s `draftEntityId` branch)
consumes the standing spare and then asks for the next one.
`Spine::ready_a_spare_front_desk` took the spine's mutex and held it across a **process spawn
and a priming model turn** — and the eight bridge calls the window makes between
`create_thread_in` and `send_message` all take that same mutex:

```
create_thread_in → navigation_tree → switch_thread → active_context
                 → techy_mode → get_timeline → onboarding_view → take_work_notices
                 → send_message
```

5.4 s of lock, plus the hops' own work, is Ray's ~6 s: **"On it!" at 14.24 s with the turn's
own header reading "Working for 8s".**

**Nothing in the log said so, and that is a property of the instrumentation rather than bad
luck.** `send_wait_notice` measured exactly one lock take — `send_message`'s — and by the time
that line ran the mutex was free. So the first commit on this branch moves the measurement
from one call site to the LOCK, which is the only thing all nine have in common, and names the
site with `#[track_caller]` so a hop added later is measured without anybody remembering to
measure it.

---

## 3. The BEFORE run, on the window

Instrumented build at `171cd552`, `RICHOS_HOP_TRACE=1`, scratch HOME, one company already
chosen, ⌘N → type → Return, 70 frames at 0.37 s from the keystroke.

From `app.log`:

```
[richos] a front desk is primed and waiting for the next new thread in sixsec-co: 18318 ms
[richos] a window command waited 18314 ms for the spine at src/main.rs:3964   (navigation_tree)
[richos] a window command waited 18028 ms for the spine at src/main.rs:746    (switch_thread)
[richos] the front desk is ready before he types: 0 ms
```

From the frames (OCR of the turn's own header, which is the app's own clock):

```
053  t=19.61  header "Working for 1s"     <- the turn's clock STARTS here
069  t=25.54  header "Working for 7s"     <- capture ran out before his first words
```

**The header read "Working for 1s" at t = 19.61 s, so the turn began about 18.6 s after the
keystroke — and the log says a window command waited 18.3 s. That is the whole of it.**

---

## 4. The AFTER run, on the window

Same harness, same job, the fix in. The hop trace, verbatim and in order, from the moment the
Send handler started:

```
+46693 ms  spine TAKEN at src/main.rs:4273 (create_thread_in) after waiting 0 ms
+46699 ms  spine TAKEN at src/main.rs:3994 (navigation_tree)  after waiting 0 ms
+46701 ms  spine TAKEN at src/main.rs:766  (switch_thread)     after waiting 0 ms
+46702 ms  spine TAKEN at src/main.rs:4239 (active_context)    after waiting 0 ms
+46703 ms  spine TAKEN at src/main.rs:795  (get_timeline)      after waiting 0 ms
+46704 ms  spine TAKEN at src/main.rs:853  (prime_front_desk)  after waiting 0 ms, held 0 ms
+46704 ms  spine TAKEN at src/main.rs:876  (the spare's tail)  after waiting 0 ms
+46705 ms  spine TAKEN at src/main.rs:4145 (onboarding_view)   after waiting 0 ms
+46705 ms  spine TAKEN at src/main.rs:1165 (send_message)      after waiting 0 ms, held 10559 ms
```

**`create_thread_in` at +46693 ms, `send_message` at +46705 ms: the whole chain is 12 ms, and
not one hop waited.** `send_message`'s 10 559 ms hold is the turn itself.

The spare for the NEXT new thread was primed during that turn, off the lock, and cost his
window nothing:

```
[richos] a front desk is primed and waiting for the next new thread in sixsec-co: 34291 ms
```

From the frames: **his first words reached the screen at t = 9.62 s** (frame 026 of 100 at
0.37 s). The headless probe on the same code measured 8.006 s for the model turn
(`eec94184`); this is a debug build, and the difference between the window and the probe is now
the build, not the app.

---

## 5. The fix, in one sentence each

* **`ready_a_spare_front_desk` is five steps.** Steps 1, 3 and 5 — decide and reserve the slot;
  assemble the priming payload and claim the ledger action; install the desk and settle the
  action — are microseconds of ledger and configuration work. Steps 2 and 4 — the child's
  spawn and its priming turn — are seconds and touch nothing but a lease nobody else can see,
  so they run with the mutex DOWN.
* **`ready_a_spare_front_desk_without_the_spine(&Mutex<Spine>, entity)`** is the road the shell
  takes. `Spine::ready_a_spare_front_desk(&mut self)` runs the same five steps under the
  caller's lock, so there is one behavior and no second implementation to drift.
* **`LeaseFactory::duplicate()`** hands out a second handle onto the same configuration so step
  2 can run outside the mutex. It defaults to `None`, which puts the spawn back under the lock
  exactly as before; every test double keeps the default.
* **`spare_in_flight`** stops a second ask spawning a second child for one slot while the
  mutex is down between steps.
* **`front_desk_generation`** catches the app un-priming every desk mid-prime: step 5 installs
  the finished child **kept but un-primed** and says so, rather than handing him a desk primed
  with material the app has discarded.

---

## 6. What is still open, named rather than left to be found

**`prime_front_desk` — the CHAIR's prime — has the same shape and is untouched.** The AFTER
run logged it holding the spine **17 249 ms** on a thread OPEN, with `onboarding_view` waiting
**17 247 ms** behind it:

```
+13204 ms  spine TAKEN at src/main.rs:853  (prime_front_desk)
+30453 ms  spine RELEASED at src/main.rs:853 after holding 17249 ms
+30453 ms  spine TAKEN at src/main.rs:4145 (onboarding_view) after waiting 17247 ms
```

It is **not** in front of his first words on the measured path — a brand-new thread adopts the
spare, so that prime is 0 ms, and an existing thread's Send never re-enters `openThread` and
has the deferred road — but it does freeze window reads for the length of a priming turn. It
wants the same five-step treatment and is a slice of its own.

**And the part of the remaining ~9 s that is ours versus the provider's.** From the headless
probe's own arrival order at `eec94184` (8.006 s total): 4.064 s to the register's tool CALL,
1.099 s streaming its arguments, then **2.843 s between the arguments completing and the app
saying the receipt at the tool RESULT**. The first two are the provider's. The third is the
child's MCP round trip plus the register's own write, and it is the only remaining span that
could be shortened without changing what the app is allowed to say — which is
`esc-20260919T001643Z-2ebd8a23`, and §55 as recorded rules out saying "On it!" at accept time
before the model has taken its turn. It stays ruled out.

---

## 7. How the window was measured, so it can be re-run

```
scratch HOME under the session scratchpad, canonical and private (richos-user-update::root)
  HOME/.claude            -> symlink to the operator's own
  HOME/.claude.json       -> copied
  HOME/Library/Keychains  -> symlink to the operator's own
env -i HOME=<scratch> USER=… PATH=/usr/bin:/bin:/usr/sbin:/sbin
      RICHOS_ACTIVATION=regular RICHOS_ENGINE_DIR=<scratch>/engine
      RICHOS_CLAUDE_BIN=/Users/alex/.local/bin/claude RICHOS_HOP_TRACE=1
```

**The keychain symlink is a finding, not a detail.** With `HOME` pointed at a scratch
directory `claude` answers *"Not logged in · Please run /login"*, and the thing `HOME` takes
away is the **login keychain** — macOS Security resolves it through the home directory. Proved
by three probes, in this order: `CLAUDE_CONFIG_DIR` alone → not logged in; plus a copied
`~/.claude.json` and a `~/.claude` symlink → still not logged in; plus
`~/Library/Keychains` symlinked → `ok`. Any future scratch-HOME run of the real window needs
that third line, or it measures a sign-in rather than the app.

Every synthesized key was addressed at the launched pid and refused if that pid was not
frontmost. **The instance was quit at the end of each measurement and `pgrep -fl richos-tauri`
was empty before this was written.**
