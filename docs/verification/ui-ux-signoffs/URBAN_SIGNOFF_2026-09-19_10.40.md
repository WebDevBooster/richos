# URBAN SIGNOFF — "Use Rich from your phone", re-walked on candidate .13: G1–G14 against their fixes

**Date:** 2026-09-19
**Reviewer:** Urban, Principal Product Designer
**Branch:** `cc/urban-opus-phoneflow2`
**Worktree:** `/Users/alex/ab/richos-wt/urban-opus-phoneflow2`
**Reviewed at:** `a2cef8eeedc31cc0363c9589a9a7756ccc7f4c3c` — read from `git rev-parse`, never typed.
**Build audited:** `1.2.0-nightly.20260919.2`, source `43f9c289756030c2173bc54bcbc5983f8102271e`
(read from the bundle `Info.plist`, `RichOSSourceCommit`), **pid 68309**.
**Fixes proved present in the binary, not assumed:** `git merge-base --is-ancestor` says **YES** for
`6acfaf80` (G2–G8, G10, G12–G14) and **YES** for `2c95c27d` (G1, `serving_via`) against `43f9c289`.
**Scope:** the whole phone flow from Settings → `Use Rich from your phone` — the chooser, both
routes, the identity/ready screen, the code, expiry, recovery, the paired card, the Settings panel.
**Predecessor:** `docs/verification/ui-ux-signoffs/URBAN_SIGNOFF_2026-09-19_05.14.md` (6/10, withheld).

> **Why this file is not at `ui-ux-signoffs/` in the repository root.** The permanent nine-entry root
> ruling. All five predecessors put it here and all five were right to.

---

## VERDICT

**Score: 7 / 10. SIGNOFF WITHHELD. He may be shown the Tailscale route; he must not be shown the
chooser until its second door is honored.**

**Every one of G1–G14 that was in scope for this round is fixed, and I re-derived all of them from my
own pixels rather than accepting Ray's.** G1 — the blocker I withheld on — is genuinely dead: close
the sheet mid-pairing, reopen it, and the Tailscale screen comes back with the same live code, the
no-certificate tripwire sentence on screen, no trust QR and no sixteen-step list (frames 05, 06). The
code is now the first thing under the opening sentence (03, 15). The socket dump is gone (04, 16).
The expired screen is one heading, one paragraph and the way out, in one viewport (08, 17). Nothing
in this flow fails WCAG AA in either theme, and this audit declares **zero** contrast exemptions.

**And then I answered the chooser's other question, and the flow broke in the same way it broke last
time.** Press `At home only` — the option whose own sentence says *"with no account and no third
party"* — then `Set my phone up`, and the screen that appears is the **Tailscale** screen: *"Your
phone reaches this Mac over your own Tailscale network… it costs one free Tailscale account signed in
on both devices"*, the pairing URL `https://mm1.tail770f6e.ts.net:8443/#pair=XYX3G3SR`, and four
numbered steps that begin *"Install Tailscale from the store"* and *"Sign in with Google as
&lt;his account&gt;"*. Frames **11** and **12**.

**This is not a copy bug and it is not a render bug.** `phone_begin_pairing` takes **no route
argument** (`richos/app/src-tauri/src/main.rs:706`), and `serving_plan` picks the tailnet whenever
Tailscale TLS is available, with no input from the user's answer
(`richos/app/src-tauri/src/phone/mod.rs:504-534, 783`). The route button's own comment still says
*"'At home only' is the shipped flow with nothing changed"* (`phone.js:1226`) — which was true when
there was one path and stopped being true when the backend learned to prefer the tailnet. **So on
every Mac signed in to Tailscale — which is his Mac, and the only Mac this ships against — one of the
two answers to "Where do you want to use it?" is discarded in silence.**

**Why that is a blocker rather than a rough edge.** It is the same failure I withheld for in the
previous round, pointed the other way: *a screen that tells the user to do the opposite of what their
chosen path requires.* It lands on §61.1 directly — the user who deliberately picked the route with
no shared account is walked into creating one and signing in with the Mac's identity, and because the
identity screen is gated on `!tailnet.account` (`phone.js:859`) he never sees the warning either. A
product that asks a question and ignores the answer has spent the trust the rest of this flow earned.

**7 and not 6** because the shipped path is finished and measurably good. **7 and not 9** because the
chooser has two doors and one of them lies.

---

## Verification mode

- **Surface:** the real RichOS desktop app on this Mac — the installed candidate bundle launched by
  Rich at 10:10Z under the scratch `HOME` `…/scratchpad/richos-qa-cand13/home`, company "QA Test Co".
  Not a browser, not a mockup, not a fixture render, not a preview.
- **Window:** **1024 × 700 pt at (438, 92), scale 1**, read from System Events, so screen pixels map
  1:1 to window points. Every frame is exactly 1024 × 700 px. This is the app's own `minWidth`/
  `minHeight` and the size Ray walked.
- **One window.** One RichOS instance existed on this Mac for the whole walk; `pgrep -fl
  'richos-tauri'` at the end is empty. No second app instance appeared, unlike the previous round.
- **Both themes:** found on **Dark**, walked dark, switched to **Light** through the product's own
  Theme control, walked light, **restored to Dark**. Both states captured (frames 01–12 dark, 13–17,
  21–22, 24 light).
- **Contrast:** every ratio below is **computed from the captured pixels** with the WCAG
  relative-luminance formula — background = the modal color of the sampled box, foreground = the
  pixel furthest from it in luminance occurring at least three times, i.e. the glyph stroke core.
  Nothing was eyeballed and no value was carried over from a token table or from Ray's audit.
- **Pace:** human-paced. Clicks with settle waits; two real five-minute code expiries filmed at 20 s
  intervals and OCR'd against the wall clock; no teleporting into states.
- **Serving was probed, not assumed:** `curl -sk https://mm1.tail770f6e.ts.net:8443/` at four points
  in the walk (200 while serving, exit 7 after each `Pick a different way`, exit 7 on both the tailnet
  and `127.0.0.1` at the end).
- **Audio:** none. No voice turn, no `say`, no `afplay`, nothing through the speakers.
- **Phone:** **none paired, none touched.** No emulator, no simulator. Tailscale read and never
  modified on either device.
- **Verification basis is stated per finding.** *Seen live* means I watched it on pid 68309's window
  at the moment stated. Source citations are shown as diagnosis, never as verdict.

### Freshness — identity, not metadata

```
$ /usr/libexec/PlistBuddy -c "Print" .../RichOS.app/Contents/Info.plist | grep -iE 'commit|ShortVersion'
    RichOSSourceCommit = 43f9c289756030c2173bc54bcbc5983f8102271e
    CFBundleShortVersionString = 1.2.0-nightly.20260919.2
$ git merge-base --is-ancestor 6acfaf80 43f9c289…   # exit 0
$ git merge-base --is-ancestor 2c95c27d 43f9c289…   # exit 0
```

The product's own Settings panel says `RichOS 1.2.0-nightly.20260919.2 is up to date.` on screen
(frames 18, 22).

---

## G1–G14, each against its fix

| # | Gap | Verdict | Frame | Basis |
|---|---|---|---|---|
| **G1** | Reopen mid-pairing renders the home path's certificate screen over a live tailnet code | **FIXED** | 05, 06 | Seen live, dark. Escape from a live code, reopen: the Tailscale screen returns with the **same** code (`ZEF6XXHV`) and countdown continuing at "2 more minutes", the no-certificate tripwire visible, no trust QR, no sixteen steps. Re-confirmed after expiry (24, light). |
| **G2** | No `Pick a different way` on the pairing screen; serving could not be stopped | **FIXED, both halves proved by me** | 04, 09 | Seen live. The button is on the live screen and the expired screen. Pressing it returns to the chooser **and stops serving**: `curl` went **200 → exit 7 (refused)**, twice, on two separate runs. |
| **G3** | Code ~1.5 screens below the fold at 1024×700 | **FIXED on the Tailscale route; correctly NOT moved on the At-home route** | 03, 15 | Seen live, both themes. Heading, QR, URL and countdown sit directly under the opening sentence, fully visible with no scrolling. The At-home call is below. |
| **G4** | `Show me another code` scrolls back to the top | **FIXED** | 07 | Seen live, dark. Pressed from the **bottom** of the dialog; the view lands with the new code (`MPVMAM8J`) at the top of the viewport. Not re-tested on the At-home route — see "What I did not verify". |
| **G5** | Raw socket dump, eight address:port pairs, unconditional | **FIXED** | 04, 16 | Seen live, both themes, whole dialog walked top to bottom on both routes. No socket dump anywhere. |
| **G6** | `.desk-btn` border 1.50:1 / 1.24:1 — sole affordance on the paired card | **FIXED** | 01, 13, and Ray 38 | Computed from my own pixels: **3.79:1** dark `rgb(107,126,168)` on `rgb(24,36,64)`, **4.06:1** light `rgb(118,124,141)` on `rgb(253,252,248)`. Same value on `Close`, `Pick a different way`, the route options and (on Ray's frame) the paired card's two controls. |
| **G7** | Expired screen states the expiry twice with an orphaned six-words paragraph | **FIXED** | 08, 17 | Seen live in **both** themes, on two real expiries. Heading *"That code ran out"*, one paragraph, three buttons, one viewport, no scrollbar. The best screen in the flow. |
| **G8** | Paired card has no heading and one text color for five paragraphs | **FIXED — measured, not seen live** | Ray 38 | I did not pair a phone. Measured from Ray's pixels: heading **12.06:1**, the actionable notifications line **12.06:1** bold, the three housekeeping paragraphs **5.78:1**. The hierarchy is real. This row is supporting evidence, not my own live verdict. |
| **G9** | Two settings doors; the technical view duplicated under two names | **First half FIXED; second half NEXT ROUND by my own ruling** | 18, 23 | Seen live. Both panels now say **"Technical view"**. Both doors still exist and both still carry the control. The one-Settings-sheet ruling stands and is unchanged. |
| **G10** | Four action rows visually identical to the two headings | **FIXED** | 18, 22 | Seen live, both themes. The four action rows carry a chevron (dark **5.51:1**, light **5.37:1** — clears the 3:1 indicator floor); `Settings` and `Updates` do not; `Bust a bug!` keeps its own icon. The type tier is still identical between a heading and a row — the chevron is doing all the work — but it is doing it. |
| **G11** | Panel cannot show its first and last row at 1024×700 | **STILL THERE — deferred by my own ruling, not counted against this build** | 21 | Seen live: scrolled to `Bust a bug!`, `Theme` and `Text size` are off-screen. Subsumed by G9. |
| **G12** | Settings panel reopens at its previous scroll position | **FIXED** | 21 → 22 | Seen live. Scrolled to the bottom, closed, reopened → back at `Theme`. |
| **G13** | Countdown says "2 more minutes" at 61 s (`ceil`), then jumps | **FIXED — proved against the wall clock, twice** | film, OCR'd | Two full code lives sampled every 20 s and OCR'd. Dark run: bands `4 → 3 → 2 → 1 more minute → 45 s → 25 s → 5 s`, each minute band ~60 s, handover to seconds at 60 s, so **at 61 s it reads "1 more minute"** — the exact case named. Light run identical (`58 s`, `38 s`, `18 s`). It never states a number the code cannot meet. |
| **G14** | Identity screen never renders when the Mac is already signed in | **The account-sentence half FIXED; the Screen-0 half NEXT ROUND** | 02, 14 | Seen live, both themes. On `This Mac is ready` the account sentence is `<strong>` and sits **directly under the heading, above the machine name**. Note for the record: in **dark** the emphasis is weight-only — the bold span measures `rgb(151,159,175)`, identical to the plain tail (both 5.78:1); in light it is the same (6.33:1 both). It reads as emphasis and it passes, but the `<strong>` buys weight and not value. |

---

## The At-home G3 call, which was mine to make

**The code stays where it is on the At-home route. I am ratifying the engineer's decision and I am
not asking for the move.**

On that path the three headings are numbered and the numbers are load-bearing: step 1 installs the
certificate that makes step 2's `https://` address open at all. Putting the code first would put step
2 above step 1 and make the screen contradict itself. On the Tailscale path there is no certificate,
no numbering and no dependency — install, sign in, allow the VPN and watch the switch are preparation
that does not gate the QR — so the move was right there and wrong here. One node, two positions, one
reason. That is the correct shape and the comment in `render()` states it accurately.

**What the At-home route needs is not the move, it is the return.** `begin(true)` → `scrollToCode()`
is route-independent in the source, so a returning user *should* land on the code there too — but I
tested that live only on the Tailscale route. Named as unverified below.

---

## New gaps, ranked

### N1 — BLOCKER · `At home only` serves the tailnet, on the screen that promised no account

*Verification basis: seen live, dark theme, frames 10 → 11 → 12. Diagnosis corroborated from source;
the verdict is the screen.*

**Repro, exactly:**

1. Settings → `Use Rich from your phone`
2. `At home only` — the screen that appears is correct and home-shaped: *"Your phone talks to this Mac
   directly, over your own home network. Nothing of what you say goes anywhere else, and there is no
   account to make."* (frame 10)
3. `Set my phone up`

**Expected:** the home screen — the two warnings, the trust QR at `http://mm1.local:8444/ca`, the
sixteen certificate taps, then the code at `https://mm1.local:8443/#pair=…`.
**Actual:** the **Tailscale** screen. Tailnet intro sentence, tailnet pairing URL
(`https://mm1.tail770f6e.ts.net:8443/#pair=XYX3G3SR`), *"On your phone, four things"*, *"Install
Tailscale from the store"*, *"Sign in with Google as &lt;his account&gt;"*, *"There is no certificate
to install on this path"*. Frames 11, 12.

**Root cause.** `phone_begin_pairing` has no route parameter (`main.rs:706`); `serving_plan`
(`phone/mod.rs:504`) returns the tailnet plan whenever `tailnet::fetch_cert` succeeds, and
`pairing_path` is then set from `tailnet_tls.is_some()` (`mod.rs:783`). The UI's `route` never
crosses the bridge. `phone.js:1226`'s comment — *"'At home only' is the shipped flow with nothing
changed"* — records the assumption that expired when the backend learned to prefer the tailnet.

**The fix I require, and there is one.** *The user's answer is an input to the backend, not a label on
a button.* `phone_begin_pairing` takes the chosen route; `serving_plan` takes it too and returns the
home plan when the user said `at-home`, even on a Mac with a valid tailnet certificate; `pairing_path`
follows the plan as it already does. Everything needed is present — both address sets are already
computed, both origins already exist, and `pairing_path` is already the record `onTailscale` reads.
**Do not fix this by removing the At-home option** — §61 keeps both — and do not fix it in the UI:
a screen that says "home" over a tailnet URL is the defect, not the cure.

**Acceptance check.** Choose `At home only`, press `Set my phone up`: the pairing URL host is
`mm1.local`, the trust QR and the sixteen steps are on screen, the four Tailscale steps are not, and
the account is named nowhere. Then choose `Anywhere` and get the tailnet screen, unchanged. Both
themes. And `phone_status.servingVia` reads `home` for the first and `tailnet` for the second.

### N2 — HIGH · The phone sheet reopens at its previous scroll position, below the live code

*Verification basis: seen live, dark, frame 05 versus 06. Corroborated: `open()` at `phone.js:1167`
never touches `panel.scrollTop`; `scrollToCode()` is called only from `begin(true)`.*

The G12 fix — reset scroll on open — was applied to the **Settings panel** and not to the **phone
sheet**. So the reopen that G1 was about lands the user at the **bottom** of a two-viewport screen,
past the live code they came back for (frame 05); the code is a page-up away (frame 06). This is G3
and G4's own principle failing on the third door into the same screen.

**Fix.** In `open()`: if a code is live, call `scrollToCode()`; otherwise `panel.scrollTop = 0`. The
helper already exists and already takes its measurement between the right two boxes.

### N3 — MEDIUM · The At-home route's own screen has no `Pick a different way`

*Verification basis: seen live, dark, frame 10. Corroborated: `#phone-off` at `phone.js:361` carries
only `phone-start` and the sheet's `Close`; the other four screens carry the control
(`:237, :302, :317, :357`).*

`Pick a different way` is on Screen 0, on Screens 2/3/7, on `This Mac is ready` and — since G2 — on
the pairing screen. It is absent from exactly one: the screen you land on by answering the question.
A user who picks `At home only`, reads the two sentences and changes their mind has Close and nothing
else. It is recoverable (the route is forgotten on reopen) but it is a dead end on the screen, and it
is the fifth copy of a control the other four screens already have.

### N4 — LOW · The Tailscale code heading still begins with "Then"

*Verification basis: seen live, both themes, frames 03 and 15.*

`"Then point your phone's camera at this"` is now the **first** instruction on the screen. "Then"
refers backwards to a step that was moved below it. On the home path the same heading is
`"2. Then point it at this, to open Rich"` and the word is correct because there is a 1. above it.
Three words, and it is the one thing on the finished screen that reads like a file that was edited
rather than written. `phone.js:1023` — drop `Then`: *"Point your phone's camera at this"*.

### N5 — OBSERVATION · The paired card names a device class when it knows the device

*Verification basis: Ray's frame 38, read not measured. Not seen live by me.*

The card's heading is **"Android phone"**. Two screens earlier the product writes *"Your phone (HONOR
X6b) is on this network."* — it has the name and uses it. The card is the screen where naming the
device actually matters, because it is the screen with `Forget this phone` on it. Not a defect; a
missed instrument-voice beat, and cheap to fix if the name is in the record.

---

## Contrast — computed from pixels, both themes, zero exemptions

Panel is `--card`: **rgb(253,252,248)** light, **rgb(24,36,64)** dark, both read from my frames.
**This audit declares ZERO contrast exemptions and needs none.** Every string in this flow is meant to
be read, including the two route limits, the certificate tripwire and the failure note — those are the
sentences that prevent dead ends and are the opposite of fine print. The one line that could have been
claimed as skippable, the `Update server: …` address at the foot of the Settings panel, measures
**5.37:1** and is therefore not claimed.

### Text — floor 4.5:1 normal, 3:1 large

| Screen | Node | Light | Dark |
|---|---|---|---|
| Chooser | Sheet title, intro, "This is an extra" | 6.33:1 | 5.78:1 |
| Chooser | "Where do you want to use it?" | 18.07:1 | 12.06:1 |
| Chooser | Both route labels | 18.07:1 | 12.06:1 |
| Chooser | Both route notes (the two limits) | 6.33:1 | 5.78:1 |
| This Mac is ready | Heading | 18.07:1 | 12.06:1 |
| This Mac is ready | Account sentence, bold span **and** plain tail | 6.33:1 | 5.78:1 |
| This Mac is ready | Machine name (mono) | 18.07:1 | 12.06:1 |
| This Mac is ready | Explanatory note, peer line | 6.33:1 | 5.78:1 |
| This Mac is ready | `Set my phone up` label on gold | 4.72:1 | 7.68:1 |
| This Mac is ready | `Pick a different way`, `Close` | 6.33:1 | 5.78:1 |
| Pairing | Code heading, six-words heading | 18.07:1 | 12.06:1 |
| Pairing | Pair URL (mono), countdown | 6.35:1 | 5.80:1 |
| Pairing | Six words | 18.07:1 | 12.06:1 |
| Pairing | Six-words note | 6.35:1 | 5.80:1 |
| Pairing | "On your phone, four things" heading | 18.07:1 | 12.06:1 |
| Pairing | The why paragraph, the four steps, store URLs | 6.35:1 | 5.80:1 |
| Pairing | "There is no pairing step", peer line | 6.35:1 | 5.80:1 |
| Pairing | Certificate tripwire, failure line | 6.35:1 | 5.80:1 |
| Pairing | `Show me another code` on gold | 4.72:1 | 7.68:1 |
| Expired | Heading | 18.07:1 | 12.06:1 |
| Expired | The paragraph | 6.33:1 | 5.78:1 |
| Paired card (Ray 38) | Heading, notifications line | — | 12.06:1 |
| Paired card (Ray 38) | Housekeeping paragraphs, both buttons | — | 5.78:1 |
| Settings panel | `Settings`, `Updates`, every row label, `Bust a bug!` | 18.07:1 | 12.06:1 |
| Settings panel | Version line | 18.07:1 | 12.06:1 |
| Settings panel | "Checked N minutes ago" | 6.35:1 | 5.80:1 |
| Settings panel | `Update server: …` (NOT claimed exempt) | 5.37:1 | — |
| Rail panel (dark) | Every heading, hint and radio label | — | 5.51 / 5.78:1 |

### Non-text indicators — floor 3:1

| Node | Light | Dark |
|---|---|---|
| Route option border, `.desk-btn` border (`--line-control`) | **4.06:1** rgb(118,124,141) | **3.79:1** rgb(107,126,168) |
| Gold confirm fill against the card | **3.83:1** rgb(156,124,52) | **6.36:1** rgb(194,163,92) |
| QR modules | 21.00:1 | 21.00:1 |
| Settings row chevron | **5.37:1** | **5.51:1** |
| Toggle, ON fill against the panel | **3.83:1** | **6.36:1** |
| Toggle, OFF — **knob against its track** | **5.94:1** | **5.14:1** |

**One honest note on the toggles.** The OFF-state *track* is 1.17:1 (light) / 1.18:1 (dark) against
the panel and is effectively invisible as an outline. It passes because the part that identifies the
control and its state — the knob, and its position — is 5.94:1 / 5.14:1 against that track, and the ON
state is additionally carried by a 3.83 / 6.36:1 fill. Recorded rather than glossed, because a reader
who measures the track alone will get 1.17 and should know which number is the right one.

---

## What is genuinely right, and should not be touched

- **The expired screen.** One heading, one paragraph, three buttons, one viewport, both themes. It
  names what happened, says nothing was lost, does not apologize, and names the button that fixes it
  — a button that is on the screen. This is the standard the rest of the flow should be held to.
- **`Pick a different way` that actually stops the socket.** Proved twice from outside the app.
  A back button that undoes the side effect is rarer than it should be.
- **The code above the steps, on the path where nothing gates it.** The screen now opens on the thing
  a person standing there with their phone needs, and the preparation is below it. Two viewports
  instead of three.
- **The route chooser itself** — both real costs stated on the option, `Anywhere` first and fixed, no
  scrolling at the app's minimum size. Nothing to change in it except making the second answer true.
- **Escape.** Tested on the chooser, `This Mac is ready`, the At-home route screen, the live pairing
  screen, the expired screen and both settings panels. Closes from every one, both themes, without
  clicking into the sheet first. No Escape defect exists.
- **Naming the account rather than saying "the same one".** Still the whole §61.1 fix, and still right.

---

## What I did NOT verify, and what would verify it

| Not verified | Why | What would settle it |
|---|---|---|
| The paired card, live | I did not pair a phone, by instruction | Ray's frame 38 is supporting evidence; I measured it but did not see the card live |
| `Show me another code` landing on the code on the **At-home** route | I tested G4 on the Tailscale route only | One press from the bottom of the home pairing screen; the source says it is route-independent |
| The home path's own screens (trust QR, sixteen steps, `mm1.local` URL) | **Unreachable on this Mac** — N1 sends every At-home run to the tailnet | Fix N1, then walk the home route; or a Mac with Tailscale signed out |
| The identity screen (Screen 0) rendered | Gated on `!tailnet.account`; this Mac is signed in | A Mac with Tailscale installed and signed out — G14's deferred half |
| Screens 2, 3, 7 (install / sign in / no name yet) | Same — this Mac is `ready` | The same |
| The one-Settings-sheet ruling (G9/G11) | Deferred to the next round by my own ruling | Not counted against this build |

**One thing I did not expect and am recording rather than filing.** Opened from the start screen, the
Settings panel has **no Theme row** (frame 20). That is deliberate — `settings-button.js:441` omits
the row when `RichTheme.forcedDark()`, and the start screen forces dark. Correct behavior, stated here
because a reviewer comparing frame 20 against frame 18 will otherwise read it as a missing control.

---

## What I disturbed

- **Theme:** found **Dark**, switched to **Light** through the product's own control for the light
  pass, **restored to Dark**, verified on screen.
- **Splash screen** was **on** when I arrived (left by the previous walk). I did not change it.
- **Three pairing windows were opened and all three were closed** — two on the Tailscale route, one on
  the At-home route. Each was ended with `Pick a different way`, and serving was probed from outside
  the app after each: `curl` exit 7. Final state probed on **both** the tailnet name and
  `127.0.0.1`: not serving.
- **No phone was paired, no device was touched, Tailscale was not modified on either device.**
- Everything above lives only in the disposable scratch `HOME`.

## Cleanup

- **App quit with its own Quit (⌘Q)** after confirming it was frontmost. **pid 68309 is gone**
  (`ps -p 68309` → no such process).
- `pgrep -fl 'richos-tauri'` → **empty**. `pgrep -fl 'richos-qa-cand13'` → **empty**: no orphaned
  provider supervisor, no orphaned `claude` child, no stray MCP process from the scratch `HOME`.
- Both capture loops were **bounded** (26 and 22 frames) and both were **killed** the moment the
  expiry was in hand; `pgrep -f 'urban2/film'` → gone.
- No emulator or simulator started. No WebKit site data cleared. No phone touched.
- Working files (unredacted captures, the contrast and OCR scripts, both films) stay in the session
  scratchpad and are not committed.

## Privacy gate

Every committed frame was OCR-scanned for an email address and for the operator's identifiers
**before** commit, the hits were black-boxed, and the set was re-scanned to zero:

```
tesseract <frame>.png stdout | grep -iE '@[a-z0-9.-]+\.[a-z]{2,}|<his mail handle, org and name>'
scanned 24 frames, 0 with a hit
```

His email appears on five screens of the Tailscale route — `This Mac is ready` and twice inside the
four-step block, on both routes. Every occurrence is boxed in the committed frames (02, 04, 05, 07,
12, 14, 16) and the sentence around it is left intact, because the sentence is the evidence.

---

## What has to be true before I sign this off

1. **N1.** `At home only` serves the home path: `mm1.local` in the URL, the trust QR and the sixteen
   steps on screen, no Tailscale step and no account named. Both themes.
2. **N2.** Reopening the sheet with a live code lands on the code, not at the bottom of the screen.
3. **N3.** `Pick a different way` on the At-home route's own screen.
4. **N4.** The Tailscale code heading does not begin with "Then".
5. **G4 on the At-home route**, walked once, after N1 makes that route reachable.

G9's second half, G11 and G14's Screen 0 remain next-round and are not conditions of this signoff.
Nothing else on this flow is outstanding: G1–G8, G10, G12 and G13 are closed, by me, from pixels.
