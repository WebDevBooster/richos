# The front door: what the harness had been measuring instead

Written by Echo, 2026-09-18, beside
[`2026-09-18-nightly-1.2.0-nightly.20260918.3-onscreen-audit.md`](2026-09-18-nightly-1.2.0-nightly.20260918.3-onscreen-audit.md),
which is the audit this answers. One row per row.

**The question this file exists for.** The `ui1` slice (`2e377176`) closed audit-8 rows 3, 4, 5,
10, 11 and 13 against a green harness, and three of them came back open on the installed bundle.
`2e377176` really is in that bundle — `git merge-base --is-ancestor 2e377176 794eac7f` exits 0,
and the bundle's `Info.plist` carries `RichOSSourceCommit = 794eac7f`. So the harness proved
something the window does not do, and the reason is different for every row.

**One correction to my own brief before anything else.** It gives the bundle's source as
`580f896a`. That commit is real — *"README: richos-core is 1270 tests after the §58 land"* — but it
is not what the bundle was built from. The bundle names `794eac7f` (*"Build
v1.2.0-nightly.20260918.3"*) in three places, exactly as Ray's §0 reports. `580f896a` is an
ancestor of it. Nothing downstream changes; the parenthetical was pointing at the wrong thing, in
the same shape as the `54e79b7f` correction Ray had to make to his own brief.

---

## Summary

| Row | Ray's finding | What it turned out to be | State |
|---|---|---|---|
| 1 | `Enter` is not a control; the slot announces `waking loro…` | TWO things. The absent `Enter` is the design `7ed03c68` landed. The `waking loro…` is a real defect: a faded-out layer that never left the tree. | half fixed, half was never broken |
| 2 | Escape does not close the settings sheet | DOES NOT REPRODUCE on the shipped window. Escape closes the settings menu, three runs out of three. Every red this instrument produced was its own — four harness defects, each measured. | **settled** — see the postscript |
| 3 | The opening screen appears with its own switch OFF, twice a session | The switch is the CURTAIN's and was obeyed. The Dock restore is a real defect with a different cause: `home.js` never read the launch kind. | fixed |
| 4 | Three sheets back to back; the first re-rendered under the cursor | One sheet re-rendering 47 px, which is what made it read as two. | fixed |
| 5 | The approval sheet shows a raw shell command in a JSON object | As described. | fixed |
| 6 | Opening-screen text over the artwork at 4.46 / 2.99 / 4.18:1 | A measurement-method question, and it is the CEO's. Measured against the ground each glyph actually sits on, the same labels are 5.27–7.85:1. | **raised**, `esc-20260918T143512Z-f198ca29` |

---

## Row 1 — the accessibility tree the harness does not have

**What the harness was measuring instead: the DOM.** Nothing in `app/ui/tests` has ever read an
accessibility tree. `control-names.js` says so in its own header and it is exactly true —
re-measured on the installed Playwright 1.61.1:

```
$ node -e "... const p = await b.newPage(); console.log(typeof p.accessibility)"
undefined
```

So every accessibility claim in that directory has been a claim about attributes. The DOM said
`#home-door-cap` is `aria-hidden="true"`, and the native tree agreed. The DOM had nothing to say
about the node next to it.

**The half that is the design, not a defect.** `Enter` is absent from the tree on purpose, since
`7ed03c68` (audit-8 row 3). The rationale is at `app/ui/home.js:749-761`: the fact the word renders
— the Enter key opens this — is in the tree where the platform looks for it,
`aria-keyshortcuts="Enter"` on the door itself, and announcing a second control with the same name
is what a screen reader cannot tell apart. It is pinned now by `tests/front-door.js` A3, so the
next walk does not re-open it.

**The half that is real.** `#home-loading.gone` was `opacity: 0` plus `pointer-events: none`, and
neither takes a node out of the tree. Measured in the renderer:

```
#home-loading  ->  { cls: "gone", display: "flex", visibility: "visible", opacity: "0" }
```

and on the .9 window at 14:56Z, in the slot directly under the door, which is where `build()`
appends it:

```
AXButton     | name=Talk to Rich
AXStaticText | name=waking loro…
```

Fixed by `visibility: hidden` delayed by the fade. The new check is `tests/front-door.js` A1,
which uses `locator.ariaSnapshot()` — the nearest thing 1.61 ships, and its visibility rule was
measured rather than read: `opacity: 0` is IN the snapshot, `[hidden]` is OUT.

## Row 2 — a key that the harness never sends

**What the harness was measuring instead: the handler, never the key.** `escape.js` has ten checks
and thirty-nine assertions, including B3, which does exactly what Ray did — click `#set-btn`, press
Escape, assert the menu is hidden — and it is green. `page.keyboard.press` hands the event to the
page through WebKit's automation protocol; the shipped window has no such path. Green there says
the handler is right. It cannot say the key arrives.

**And the handler is right, twice over.** On `6a5b6496`, `#set-menu` is closed by two independent
document-level listeners: `main.js:6929` (`dismissTopmostPopup`) and `settings-button.js:659`
(`if (e.key === "Escape") close(true)`, bound to `document`, not to the menu). Nothing with a
computed z-index above `#set-menu`'s 301 can be on screen except `#home-prefs` (340), which is
created `hidden`. There is no ordering there that swallows the key.

**Half of the row's evidence is void, and it matters for every future walk.** The row rests on two
indistinguishable screenshots and on *"the tree still returns the sheet's 5 nodes"*. The second
proves nothing: **System Events reports nodes for subtrees that are `display: none` in the
renderer.** Measured both ways on the same build in the same hour —

```
the .9 window's tree, at rest, nothing open       the same page, in the renderer
  AXGroup | name=Connected repositories             #repositories-sheet -> display: "none"
  AXGroup | name=Allow this action?                 #permission-sheet   -> display: "none"
  AXGroup | name=Quit while work is running?        #quit-question      -> display: "none"
```

(`[hidden] { display: none !important }`, `style.css:280`.) **Presence in that tree is not evidence
of being on screen.** Assert on the node's SIZE — 0x0 for an unrendered subtree, its real box
otherwise.

**Why it is still open.** `app/scripts/front-door.test.sh` drives the real window through AppKit
and would settle it, and it could not run today for reasons that are about this machine and not
about the product:

```
$ scripts/front-door.test.sh --release ~/.richos-nightly/releases/v1.2.0-nightly.20260918.3
  REFUSED  NO DISPLAY IS AWAKE — CGGetActiveDisplayList reports 0 ... (online: 3)     exit 2

$ caffeinate -u -t 60 &  ; scripts/front-door.test.sh --release …
        3 display(s) awake — the boot can be held to a placement backed by one of them
  REFUSED  the session is LOCKED (CGSSessionScreenIsLocked = true).                   exit 2
```

With the screens woken and the session still locked, the app boots and derives a real geometry on
a real monitor (`window: derived 1400x880 pt at (260,102) ... Monitor #30942`) and System Events
still reports `windows: 0`. A probe of mine lost a whole measurement to that before it was found:
Return and Cmd-K both did nothing, which looks like Ray's defect and is not.

**Recorded before the fact so it cannot be written afterwards:** given the two independent handlers
and the twice-reproduced fact that a locked or asleep session eats every synthesized key, I expect
`C1` or `C2` — the positive controls — to be what goes red on an unlocked screen, not `C4`. That
would make row 2 a harness artifact of the walk, as the candidate-.6 onset defect was. I do not
know that. Ray typed a full sentence into that composer minutes before his Escape, which is a real
`C1` pass on his run, and that is the fact that keeps this open rather than closed.

**To settle it:** unlock the screen and run
`richos/app/scripts/front-door.test.sh --release ~/.richos-nightly/releases/v1.2.0-nightly.20260918.3`,
or leave it running with `--wait-for-screen 3600` and let it wait for the unlock as a state
(CEO §56).

## Row 3 — a suite that asserted the defect

**What the harness was measuring instead: it was pinning the behavior.** `tests/home.js`'s check
*"a launch with NO curtain at all lands on the home screen"* asserts `homeOpen && !homeHidden`, and
its own comment read *"It is also what every reload, every crash-restart and every second window
gets"*. A Dock restore IS a second window. A check cannot catch what it asserts.

**Two things were conflated in the row, and only one is a defect.** The `Opening screen` switch in
Settings is the CURTAIN's — `splash.js`'s `KEY_ENABLED`, written through `main.js::setSplashEnabled`
and reconciled against `ConfigStore::splash_enabled`. It governs `#splash`, the three-second
composition that lifts by itself. The home screen (`#home`) has never had an off switch, and the
CEO ruled on 2026-09-01 that it must be shown after the splash. So the switch Ray read was off and
was obeyed; the surface he saw is a different one. His own caveat named the half that still needed
explaining, and it was the right half.

**The defect.** `home.js` never read `window.__RICHOS_LAUNCH__` — grepped across `app/ui` on
`6a5b6496`, it had exactly one reader, `splash.js`. And a Dock restore is a webview boot: closing
the window destroys it (`ExitRequested` -> `StayResident` prevents the PROCESS exit, not the
window's destruction), so `app.webview_windows()` is empty when `RunEvent::Reopen` arrives and
`reopen_window` (`main.rs:6982`) builds a new one. Its own doc comment had already decided what
that should look like — *"It is a `SecondWindow` launch: nothing begins, no opening screen, no
count"* — and the frontend was not honoring it. It does now, scoped to that one kind, with
`tests/front-door.js` B2 holding `fresh`, `reload` and `crash-restart` on the screen and B3 holding
the logo's way back.

## Row 4 — a defect with no time in it

**What the harness was measuring instead: a bridge with no latency.** `tests/setup.js` case 17,
written first without the latency, PASSED against the broken source. The mock answers
`provider_auth_status` in a microtask, so no frame is painted between the done state and the
account answer and the button appears never to move. A defect about the ORDER OF TWO PAINTS cannot
be seen by a harness with no time between them. With 150 ms on that one command:

```
FAIL 17  `Close` moved after it was on screen — it was at [290,243] across 26 frames,
         a travel of 47px. A button a person is already aiming at may not move.
```

47 px against Ray's "~46 px", by a different method on a different machine. The cause is
`runSetup` painting the done state and then awaiting `provider_auth_status`; the answer is
`connected`, `renderProviderAuth` hides `#provider-connect` and `#provider-account-kind`, and both
sit above `#setup-close`.

**And there were never three sheets.** `#setup-account` is a paragraph inside the setup sheet. What
made it read as a second dialog is this re-render — the same panel changing its heading, its body
and its height a beat after he had finished reading it. With one paint there are two sheets, and
the second is a separate question.

## Row 5 — not a harness gap

No suite had an opinion about the ORDER of what the approval sheet shows. There is one now
(`tests/permissions.js`, the fourth check): the description first, the scope second, the raw form
last and closed, reachable by Tab and opened by Enter, and Escape still declines.

**One finding declared rather than fixed.** `.desk-btn`'s border is `var(--line)` = `--line-strong`,
and against the panel it sits on it computes to **1.24:1 in dark and 1.50:1 in light**, against a
3:1 floor for a non-text indicator. That is true of every `.desk-btn` in the app today, including
`Decline` and `Allow action` on this sheet. It is a real row and it is not fixed here, because
`--line-strong` is a global token and a restyle of every button in the product does not belong
inside a permission-sheet change. The control added today carries no border for exactly that
reason, and is identified instead by its label (5.78:1 dark, 6.38:1 light) and its focus ring
(6.36:1 dark, 3.83:1 light).

## Row 6 — the two ratios, and which one is the floor

**Raised to the CEO as `esc-20260918T143512Z-f198ca29`, and nothing in the composition was
changed.**

Measured on Ray's own frame, `2026-09-18-nightly-9-onscreen/01-launch-window.png`, with the WCAG
relative-luminance formula. For every glyph pixel, the ratio against **the darkest pixel within
4 px of it** — which is the halo `field-engine.js` strokes under every label at `lineWidth` 5, and
is the ground a reader's eye resolves the glyph's edge against:

| | vs. the ground it sits on | vs. the crop's most common value |
|---|---|---|
| `CUSTOMERS` | **5.27:1** | 1.96:1 |
| `REVENUE` | **7.02:1** | 1.00:1 |
| `CAPITAL` | **7.85:1** | 7.51:1 |
| `LEGAL & RISK` | **7.73:1** | 18.58:1 |
| `1,318` | **5.80:1** | 1.00:1 |
| `558` | **6.82:1** | 7.15:1 |
| `362` | **7.20:1** | 7.66:1 |
| `424` | **6.77:1** | 8.33:1 |

The compositing algebra agrees and is the worst case rather than a sample: ink `223,228,238` at the
resting floor alpha 0.86, over a halo `10,15,28` at `0.98 × 0.86`, composited over **pure white**
nebula — the brightest ground anywhere on that screen — is **7.60:1** for a name and **6.28:1** for
a count.

The same ink laid straight onto white with no halo under it is 1.20:1, which is where Ray's
1.00:1 and 2.99:1 come from: the crop's ground is the nebula several pixels away, not the ground
under the glyph.

**Both numbers are true about different things, and choosing between them is a design decision
about a composition the CEO ruled on** — the only fix for the second reading is a plate or scrim
behind every label, and the minimum plate that holds 4.5:1 over white is alpha 0.72
(`rgb(79,82,92)`), which is a visible dark box behind every category name on the picture. That is
his call, not mine.

**One honest caveat about my own method.** `866` came out at 2.97:1, and the pair is
`(255,255,255)` on `(255,99,35)` — pure white against saturated orange. That is a nebula spark
inside the crop passing my neutral-hue filter, not a glyph. It is a limitation of the filter,
reported rather than dropped.

---

## The checks this left behind

| File | What it holds |
|---|---|
| `app/ui/tests/front-door.js` | rows 1 and 3, under WebKit, no screen needed — 7 checks, 24 assertions |
| `app/ui/tests/setup.js` case 17 | row 4, with 150 ms of deliberate bridge latency |
| `app/ui/tests/permissions.js` check 4 | row 5 |
| `app/scripts/front-door.test.sh` | row 2, on the real window through AppKit, with both preconditions declared and refused by name |

Every one of them was run red before its fix and green after, and the red output is quoted in the
commit that carries it.

---

# POSTSCRIPT, same day, 17:01Z — row 2 put to the real window

Written by Echo after the screen came back. The branch above was paused at `c8f7f9d2` with row 2
open and an instrument that had never completed a run; this is what the instrument found once it
could. Everything below was measured on `v1.2.0-nightly.20260918.3`, `CFBundleVersion`
`1.2.0-nightly.20260918.3`, `RichOSSourceCommit` `794eac7f`, driven through AppKit.

## The answer

**Row 2 does not reproduce. Escape closes the settings menu on the shipped window.** Three
consecutive runs — 16:46:41Z, 16:47:57Z and 17:00:50Z, the last on the branch rebased onto
`60458045` — each 7 of 7 green, exit 0:

```
PASS  C4  Escape closed the settings menu  (Techy Mode 95x20 -> absent)
```

and the accessibility dumps say it by name and box rather than by a count. With the menu open
(107 nodes):

```
AXMenu       | 1375,196 267x637 | name=Settings
AXStaticText | 1392,287 95x20   | name=Techy Mode
AXCheckBox   | 1591,286 38x22   | name=Techy Mode
AXStaticText | 1392,323 123x20  | name=Opening screen
AXMenuItem   | 1382,513 253x36  | name=Memory folder
```

and after one Escape (48 nodes) the `AXMenu` and every row inside it is gone, leaving only the
`AXPopUpButton | 1602,148 40x40 | name=Settings` that opens it. Both dumps are committed beside
this file, in [`front-door-2026-09-18-logs/`](front-door-2026-09-18-logs/), so the claim can be
read rather than taken.

**The expectation was written before the run and it holds.** The paused note recorded *"`C1` or
`C2` — the positive controls — are what I expect to go red, not `C4`"*; I ran with that standing
and it was half right in the most useful way. `C1` and `C2` did go red, repeatedly, and `C4`
never reproduced Ray's finding once the instrument could reach it. Every red was the harness's
own.

**What this does NOT settle, and it is the honest half.** A synthesized key is not a person's
finger. Ray pressed Escape himself. This says the path from the window server to `main.js`'s
document listener is sound on that surface today, three times; it cannot say what his keyboard
did. `C3` is the control that keeps it honest — if the Escape this harness sends ever stops
arriving, `C4`'s verdict is void rather than wrong.

## Four defects in the instrument, in the order they were found

**1. Every position and size in every dump was `? ?`.** `item 1 of (position of e)` reads like an
index into a list and is not: `e` is a reference into `entire contents`, so AppleScript composes
one specifier and System Events cannot resolve it. Both forms, same window, 4 of 4 elements each:

```
A  ((item 1 of (position of e)) as text)    ->  ERR Can't make item 1 of «class posn» of item 1 of {…}
B  set p to position of e, then item 1 of p ->  260,102 1400x881
```

**2. The name was read from the wrong awk field.** A dump line is `role | x,y WxH | name=… |
value=…`; `size_of`, `on_screen` and `middle_of` all tested `$4`, the value. Every lookup returned
empty for every node in every dump the file has ever taken, which is why the door was never
clicked and `Settings` looked absent from a tree it was plainly in:

```
field 4 (shipped)  Talk to Rich  size=[]        middle=[]
field 3 (fixed)    Talk to Rich  size=[174x52]  middle=[381,705]
```

**3. `cliclick kp:esc` does not reach this app.** One launch, each step dumped:

```
A  Cmd-K   by cliclick (kd:cmd t:k ku:cmd)   ->  search overlay OPEN
B  Escape  by cliclick (kp:esc)              ->  search overlay STILL OPEN
C  Escape  by System Events (key code 53)    ->  search overlay CLOSED
```

Same window, same second, same frontmost process; its typing and its Cmd-K arrive and its Escape
does not. **This is the one that would have shipped a false defect report** — the 16:30:15Z run
said *"Escape did not close the search overlay"* about a key it never delivered. Escape is now
sent by `key code 53`, still a synthesized key through window server -> NSApplication -> key
window -> WKWebView -> document, still not WebKit's automation protocol.

**4. The assertions were line counts, and they lied in both directions.** The search overlay is
modal, so opening it takes the rest of the page out of the tree — 66 nodes to 17. *"More lines
than before"* called a working Cmd-K broken; *"no more lines than before"* called an overlay still
on screen closed, a false PASS at 16:27:45Z where `ax-4-esc` was byte-identical to `ax-3-cmdk`.

## Two calibrations this record had wrong about its own subject

**An unrendered subtree is not 0x0.** The Row 2 section above says to assert on size, *"0x0 for an
unrendered subtree"*. It is not. All three `display:none` sheets report `260,130 1400x10` — the
web area's own origin and a degenerate full-width 10pt strip:

```
AXGroup | 260,130 1400x10 | name=Connected repositories
AXGroup | 260,130 1400x10 | name=Allow this action?
AXGroup | 260,130 1400x10 | name=Quit while work is running?
```

A rule rejecting only zero would have called **every closed sheet in this app open**. The strip is
now calibrated from a known-closed sheet on each run (C5 checks all three agree) and rejected by
value.

**A closed search overlay stays in the tree at its full box.** `260,130 1400x853`, byte-identical
to the open state — the row-1 residue class, fixed on this branch and not in the .9 bundle. So
nothing asks "is the overlay gone". The desk chrome is the signal, and it is exact: `Settings` is
in the tree with a `40x40` box precisely when no modal covers the desk, and absent when one does.

**And a first run is a queue of questions, not one.** `main.js:7294` defers the company question
behind the setup and memory ones and `closeMemorySetup` asks it *"the moment that one is
answered"* (`main.js:5250-5256`). One Escape does not return the desk — it advances the queue,
which is what made three runs read `Which company is this copy of Rich for?` in the dump taken
after C3 and conclude Escape had failed. **This is also a live hypothesis for what Ray saw**: a
person pressing Escape on one popup and immediately meeting another can only report that nothing
happened. It is a hypothesis and not a finding; nothing here measured his run.

## Two things this harness put on the CEO's screen, and the fixes

Both were the harness reaching outside the app it launched. Both are fixed structurally rather
than by care.

**A modal alert, for two minutes.** The 16:11:56Z run left *"RichOS could not open"* standing and
he sent a screenshot. The scratch HOME was built under `$TMPDIR`, `/var` is a symlink to
`private/var`, and `richos-user-update::root` (`crates/richos-user-update/src/lib.rs:147`) refuses
a HOME that is not already its own `canonicalize()`.

> **The first account of this blamed the doubled slash `${TMPDIR}/…` produces, and that account is
> wrong.** Measured with a five-line probe on rustc 1.98.0: `Path::new("/a//b") ==
> Path::new("/a/b")` is **true**; `/var/folders/…/T/pathprobe/home` with no doubled slash anywhere
> canonicalizes **unequal**; `/private/var/folders/…/T//pathprobe//home` with two of them
> canonicalizes **equal**. `Path`'s equality is component-wise. Trimming the slash would have
> fixed nothing.

And the alert is this harness's own doing, which is why the fix is structural: it asks for
`RICHOS_ACTIVATION=regular` because a key window is what it measures, `activation.rs:72` grants
that, and `startup_alert.rs:110-112` arms the CEO-facing modal on **exactly**
`Presentation::Regular`. It is the one harness in this repository that can speak to the person at
the Mac. So P4 now mirrors `root()`'s whole rule before launching (refusal with nothing launched,
proved by pointing `$TMPDIR` at a 0777 directory), and P5 watches the boot log for
`^\[richos\] application startup:` — which `cannot_start` writes **before** it raises the alert
(`startup_alert.rs:222-228`) — and ends the instance at once. The alert's own timeout is ten
minutes (`ALERT_TIMEOUT_SECONDS = 600.0`). Red then green on a stub bundle, so no dialog was put
on anyone's screen to measure it: **135s of exposure before, 0.6s after.**

**Finder's "Connect to Server" window, left open.** Same run. `cliclick` does not type into an
application — it posts to the window server, which delivers to whatever is frontmost. The app copy
had already quit, so C1's probe text and C2's Cmd-K went into his desktop. Every synthesized event
now passes through one `send`, which reads the frontmost process's **unix id** immediately before
posting and refuses by name on a mismatch; a failed launch stops the run at C0 before any key is
sent. By id and not by name, because `process "richos-tauri"` matches his own installed RichOS
just as happily — the tree dump and both `set frontmost` calls are addressed by id for the same
reason. Proved both ways against a recorder standing in for `cliclick`, so "nothing was sent" is a
line count on disk: wrong target -> refused, **0** recorder calls; right target -> sent, **1**.

> One thing to own rather than bury: the *red* measurement of that guard was taken by running the
> pre-fix script against a stub, and it posted its probe text and a Cmd-K into a **Terminal**
> window at 17:19 local. No document of his was open to it and Finder had no window left behind
> (checked), but it is the same class of leak and it is recorded here rather than left out.

## Still open, still declared, still not mine

`.desk-btn`'s border is `var(--line)` = `--line-strong`, **1.24:1 in dark and 1.50:1 in light**
against a 3:1 floor for a non-text indicator, on **every** `.desk-btn` in the app including
`Decline` and `Allow action`. Unchanged by this work and deliberately so: `--line-strong` is a
global token and a restyle of every button in the product is a slice of its own. Row 6
(`esc-20260918T143512Z-f198ca29`) remains the CEO's and nothing in that composition was touched.

## What the checks hold now

| File | What it holds |
|---|---|
| `app/scripts/front-door.test.sh` | row 2 on the real window — P1-P5 declared and refused by name, C0-C5 and Z, 7/7 green three times |
| `app/ui/tests/front-door.js` | rows 1 and 3 under WebKit — 7 checks, 24 assertions |
| `app/ui/tests/setup.js` case 17 | row 4, with 150 ms of deliberate bridge latency |
| `app/ui/tests/permissions.js` check 4 | row 5 |

Re-run on the rebased branch, one at a time, all exit 0: `front-door` (24 assertions), `home`,
`setup`, `permissions`, `escape`, `affordances`, `contrast`, `splash`, `appearance`, `onboarding`,
`first-run-sheet`, `control-names`, and `phone` (new on `60458045`).

## One more thing the rebase had to re-derive

`ui/tests/contrast-debt.json` was the only conflict against either main. This branch raised every
surface's `considered` floor by **+2** (the approval sheet's disclosure label, shared markup); the
phone channel that landed at `88499da5` raised the same floors by **+68** and reformatted the
whole file to one-space indent. The resolution takes main's file and applies the +2 to all **39**
surfaces — 37 before, plus `phone-pairing` and `phone-paired` — rather than replaying this
branch's numbers over it. That is a claim, so it was checked the only way that counts: `contrast`
exits 0 on the rebased tree, which is check 9z agreeing that no floor is now clearable by a bare
shell. `floorReference.shell` is left at 448/92, as all five amendments before this one left it.
