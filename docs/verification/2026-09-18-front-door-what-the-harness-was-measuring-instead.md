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
| 2 | Escape does not close the settings sheet | Unsettled. Half the evidence is void (see below); the handler is doubly correct in source; the native path could not be measured today. | **open**, with an instrument |
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
