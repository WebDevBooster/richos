# URBAN SIGNOFF — "Use Rich from your phone": the Tailscale screens, pairing, expiry and the paired card

**Date:** 2026-09-19
**Reviewer:** Urban, Principal Product Designer
**Branch:** `cc/urban-opus-phoneflow1`
**Worktree:** `/Users/alex/ab/richos-wt/urban-opus-phoneflow1`
**Reviewed at:** `61568ee1cf85b7de532c45843a2cdde9c065bec5` — read from `git rev-parse`, never typed.
**Build audited:** `1.2.0-nightly.20260919.1`, source `a08cc788`, binary `f74d25e6`, **pid 9587**.
**Scope:** the phone flow reached from Settings → `Use Rich from your phone` — the route chooser,
the identity screen, `This Mac is ready`, the pairing code, expiry and recovery, the paired card.

> **Why this file is not at `ui-ux-signoffs/` in the repository root.** The permanent nine-entry
> root ruling. All four predecessors put it here and all four were right to.

---

## VERDICT

**Score: 6 / 10. SIGNOFF WITHHELD. The CEO must not be shown this flow yet.**

**The reason is one state, and it is the worst one this feature could have.** Start the
`Anywhere` route, press `Set my phone up`, close the sheet, reopen it while the code is still
live — four ordinary actions, no trickery — and the sheet comes back **on the home path's
screen**: `Two things before you start.`, the `Unverified` certificate paragraph, the iOS
18.0/18.1 paragraph, a live trust QR at `http://mm1.local:8444/ca`, and the sixteen certificate
taps — wrapped around **the Tailscale pairing URL**. On the one path that installs no
certificate at all, the app hands the user a certificate to install, for a hostname that will not
resolve away from home. The sentence written to catch exactly this — *"There is no certificate to
install on this path. If your phone asks you to install a profile, something is wrong — tell
me."* — is **not on screen**, because it lives in the block the same condition hides.

Frames 13, 14, 15. Reproduced, then re-confirmed after an interruption on a second run.

**This is not a copy bug. It is candidate .11's defect 3.2 with half the fix applied.** 3.2 was
"the sheet describes the wrong path because `route` is forgotten on open". The fix keyed the
**paired card** off the Mac's record (`status.pairedVia`). The **pairing screen** still keys off
`route`, which is forgotten on open by design. So the defect survived in the state nobody
re-walked: not paired, still serving.

**Everything else in this flow is good work, and some of it is very good.** The route chooser
states both real costs and hides neither. The identity trap is stated three times where it
renders and names the account rather than gesturing at it. The expired state is calm, honest and
names its own recovery. Contrast passes in both themes at every node I measured, computed from
pixels, with zero exemptions declared and zero needed. That is why this is a 6 and not a 3 — but
a flow with a state that tells the user to do the opposite of what their path requires does not
go in front of the CEO, and §61.1's *"ABSOLUTELY UBER MEGA SUPER CRYSTAL-CLEAR"* is the
requirement it fails against.

---

## Verification mode

- **Surface:** the real RichOS desktop app on this Mac — the installed candidate bundle, launched
  by Rich at 03:44Z under a scratch `HOME`. Not a browser, not a mockup, not a fixture render.
- **Window:** **1024 × 700 pt at (438, 92), scale 1**, so screen pixels map 1:1 to window points.
  Confirmed: every frame below is exactly 1024 × 700 px. This is also `tauri.conf.json`'s
  `minWidth`/`minHeight` and the size Ray walked.
- **One window** for frames 01–15 (captured 04:48–05:06). **See "What I disturbed" — a second
  RichOS instance, another agent's, appeared at 05:06:26 and everything I captured after that is
  excluded from this audit.**
- **Both themes:** light and dark, switched through the product's own Theme control.
- **Contrast:** every ratio below is **computed from the captured pixels** with the WCAG
  relative-luminance formula — background = the modal color of the box, foreground = the pixel
  furthest from it in luminance, i.e. the glyph stroke core. Nothing was eyeballed and no ratio
  was carried over from a token table.
- **Pace:** human-paced. Clicks with settle waits, a real five-minute code expiry filmed at 30 s
  intervals, no teleporting into states through hidden shortcuts.
- **Audio:** none. No voice turn, no `say`, no `afplay`, nothing through the speakers.
- **Phone:** **none paired.** No device was touched, no emulator or simulator started, Tailscale
  was never modified.
- **Verification basis is stated per finding.** *Seen live* means I watched it on pid 9587's
  window at the moment stated. Anything else says what it is.

### Freshness

Read off the product's own Settings panel, on screen, in frame 10: **`RichOS 1.2.0-nightly.20260919.1 is up to date.`**
Ray's audit records the same string from the bundle `Info.plist` and `app.log` at
`f74d25e63fe9a737a0412732c17674c87774b599`, with `a08cc788` proved an ancestor.

---

## The three problems that matter

### 1. BLOCKER — reopening the sheet mid-pairing shows the other path's screen

*Verification basis: seen live, dark theme, frames 13/14/15. Reproduced twice.*

**Repro, exactly:**

1. Settings → `Use Rich from your phone`
2. `Anywhere, including away from home`
3. `Set my phone up` — a code goes live
4. Escape (or `Close`)
5. Settings → `Use Rich from your phone`

**Expected:** the Tailscale screen — four phone steps, the account named, the code.
**Actual:** the home path's screen — two warnings, `1. Point your camera at this, to install the
certificate` with a live QR at `http://mm1.local:8444/ca`, the sixteen certificate taps, and then
`2. Then point it at this, to open Rich` carrying the **tailnet** pairing URL.

**Root cause, from source.** `render()` derives `onTailscale` from `route`
(`richos/app/ui/phone.js:718`), and `route` is reset to `null` on every open (`:1016`) — correct,
and Urban §1 consequence 2. But `choosing` requires `!pairing` (`:741`), and a live or expired
code makes `pairing` true, so a reopen falls straight through to `#phone-pairing` with
`onTailscale === false`. Every Tailscale-only node is then hidden and every home-only node shown:
`:838-841`. The comment at `:735` states the assumption that broke — *"A listening, unpaired Mac
is someone MID-FLOW **on the home path**"* — which stopped being true the moment the Tailscale
route also made the Mac listen.

**The fix I require, and it is the same shape as 3.2's.** *Which route the open pairing window
was started for is a fact the Mac holds, not a thing this sheet may remember.* `device.rs` already
writes `paired_via` at pairing; the **open window** needs the same field (`serving_via` /
`window.via`), surfaced on `phone_status`, and the pairing screen's `onTailscale` must read
**that**, never `route`. Do not fix this by persisting `route` — that re-introduces the remembered
choice Urban §1 rules out, and it would still be wrong after a restart.

**Acceptance check.** Steps 1–5 above land on the Tailscale screen with the four phone steps, the
no-certificate tripwire sentence visible, no trust QR, and no sixteen-step list — in both themes,
and again after the code has expired.

**Second half of the same defect: there is no way back.** `#phone-pairing` carries only `Show me
another code` and the global `Close`. It has no `Pick a different way`. Once `Set my phone up` is
pressed, the route chooser is unreachable for the life of the app process — `expired` also sets
`pairing` (`:717`), so waiting does not restore it either. I hit this live: after the walk, the
route chooser and `This Mac is ready` could not be reached again in dark at all. **`Pick a
different way` must be on the pairing screen too**, and it must stop serving.

### 2. The code is two screens below the fold, and asking for a new one scrolls back to the top

*Verification basis: seen live, light theme, frames 04, 05, 06, 08, 09.*

At 1024 × 700 — the app's own minimum — the pairing screen is roughly **three viewport heights
tall**. Pressing `Set my phone up` lands the user on a wall of instruction with the QR, the six
words, the countdown and the only `Close` all out of sight (frame 04). The code is about 1.5
screens down (frame 05).

Then the recovery path makes it worse: `Show me another code` issues the code **and returns the
panel to the top** (frame 08), so the user must scroll the whole way down again to reach the thing
they just asked for (frame 09).

**This contradicts the specification's own first principle** — *"the sheet always shows the one
thing left to do, and nothing else"* (design doc §1). It does not. It shows everything, and the
one thing left to do is last.

**The fix.** The code block — heading, QR, address, countdown, six words — moves **above** the
phone instructions, and `Show me another code` restores scroll to the code rather than to the top.
The four phone steps are preparation for a person who has not started; the code is what a person
who is standing there with their phone needs. Order the screen for the second person. Nothing
needs deleting for this, only reordering.

### 3. A raw socket dump on a consumer screen

*Verification basis: seen live, light theme, frame 06.*

> This Mac is answering on 127.0.0.1:8443, 127.0.0.1:8444, 192.168.1.249:8443, 192.168.1.249:8444,
> 100.68.9.4:8443, 100.68.9.4:8444, [fd7a:115c:a1e0::6e31:905]:8443, [fd7a:115c:a1e0::6e31:905]:8444.

Eight address:port pairs, four lines, the largest single block in the lower half of the screen,
sitting between the security sentence and the action button. It is unconditional —
`phone.js:899-902` draws it whenever a code is live, on both routes, for every user, and it is
**not** behind the technical view. It tells the reader nothing they can act on, and it is the one
thing on this flow that looks like a debug log that shipped.

**The fix: remove it from the default screen.** If it earns its place as diagnostics, it belongs
behind Techy Mode with everything else of its kind. This is a deletion, and deletion is the
change I want most on this screen — it costs nothing and it takes 90 px out of the very overflow
problem in finding 2.

---

## The gear-vs-menu ruling

**Asked of me:** invert the doors so the rail gear opens the universal menu, or leave both panels?
**Answer: neither, and the question is one level too low. There is one Settings, it is the
top-right sliders panel, and it stops being a popover.** The rail gear is retired and its rows
move in.

*Verification basis: seen live, light theme, frames 10, 11, 12; Echo's measurement re-read from
`docs/verification/escalations/2026-09-19-echo-opus-phoneflow1-defect-3-4-...md`.*

**What is actually on screen today.** Two settings surfaces, side by side in the same window:

| | rail gear, bottom-left (frame 12) | sliders, top-right (frames 10, 11) |
|---|---|---|
| Titled | **nothing** — opens on "Your name" | **"Settings"** |
| Holds | Your name · How much should Rich interrupt you? · **Technical view** · Keep the stored output | Theme · Text size · **Techy Mode** · Splash screen · Company · Home screen · Connected repositories · Account connection · Memory folder · **Use Rich from your phone** · Updates · Bust a bug! |

**The same switch is in both panels under two different names.** Ray's defect A ("Technical view"
vs "Techy Mode") is not a typo — it is the symptom. Renaming one word leaves two doors, one
duplicated control, and no sign in either pointing at the other. And the panel that says
"Settings" is the one the CEO does *not* reach from the identity corner where every other product
he compares this to puts it.

**Why not (a), invert the doors.** Because the container is the problem, not which button opens
it. **The sliders panel already fails at the app's own minimum size, today.** Frame 10 shows
Theme at the top with `Bust a bug!` below the fold; frame 11 shows `Bust a bug!` with Theme
scrolled off. **At 1024 × 700 this panel cannot show its own first and last rows at the same
time.** Moving four more groups into it makes a present defect a severe one.

**Why not (b), leave both.** Two doors to settings, one control duplicated under two names, is
precisely the product sludge this direction exists to refuse. It is also not stable: three
independent measurements in this repository record the rail popover refusing to grow — Echo's
617 px of content in a 628 px box, `settings-button.js`'s 821 px in a 950 px window with
`techy.js` check 9 unable to click a conversation, and `index.html:1245`'s 581 → 761 px covering
eight rail rows. **A container that has refused three consecutive additions is not one row short;
it is the wrong container.**

**So: Settings becomes a sheet.** The `.overlay` modal shape this app already uses for the phone
sheet, repositories, account connection, the memory folder, the home screen and the techy scope —
every settings-adjacent surface in the product is already a sheet, and the popover is the odd one
out. One door, the sliders control, which is present on every screen including the start screen.
The rail gear goes; its four groups become groups in the sheet. `Technical view` is the surviving
name — it is plain, it is American English, and it reads the same spoken; `Techy Mode` is jargon
in title case and does not survive being said aloud.

**What I am NOT asking for in this round.** Not the sheet. That is real work — it moves a
CEO-required control and rewrites drivers in `contrast.js`, `techy.js`, `retention.js`,
`splash.js` and `appearance.js` — and it must not be smuggled into a copy-and-contrast pass. For
**this** round: one name for the technical view in both panels (already dispatched). The sheet is
required **before the next settings row is added to either panel**, whichever comes first.

---

## Contrast — computed from pixels, both themes

Panel is `--card`: **rgb(253,252,248)** light, **rgb(24,36,64)** dark, both read from the frames.
**This audit declares ZERO contrast exemptions and claims none.** Every string in this flow is
meant to be read, including the two limits and the two failure notes — those are the sentences
that prevent dead ends and are the opposite of fine print.

### Text — floor 4.5:1

| Node | Class | Light | Dark | Verdict |
|---|---|---|---|---|
| Sheet title | `.overlay-title` | **6.33:1** | **5.80:1** | pass |
| Every note, step, list item, button label | `.overlay-note`, `.phone-steps li`, `.desk-btn` | **6.33 / 6.35:1** | **5.78 / 5.80:1** | pass |
| Step headings | `.phone-step-title` | **18.07:1** | **12.06:1** | pass |
| Route option labels | `.phone-route > button` | **18.07:1** | (see note) | pass |
| Tailnet name, six words | `.phone-tailnet-name`, `.phone-words` | **18.07:1** | **12.06:1** | pass |
| Pair / trust address | `.phone-url` | **6.35:1** | **5.80:1** | pass |
| Countdown | `.overlay-note` | **6.33 / 6.35:1** | **5.80:1** | pass |
| Account sentence (§61.1) | `.overlay-note` | **6.33:1** | (see note) | pass |
| Confirm button label | `--on-gold` on `--gold` | **4.72:1** | (see note) | pass |
| Paired card, every line | `.overlay-note` | **6.33:1** (Ray frame 21) | **5.78:1** (Ray frame 22) | pass |

### Non-text indicators — floor 3:1

| Node | Light | Dark | Verdict |
|---|---|---|---|
| Route option border, `--line-control` | **4.06:1** rgb(118,124,141) | 3.79:1 (spec; not reachable in dark — see below) | pass |
| Gold confirm fill / focus ring, `--gold` | **3.83:1** rgb(156,124,52) | 6.36:1 (spec) | pass |
| QR modules | **21.00:1** | **21.00:1** | pass |
| **`.desk-btn` border, `--line`** | **1.50:1** rgb(207,208,211) | **1.24:1** rgb(37,52,82) | **FAIL** |

**The one failure, and it is not cosmetic here.** `.desk-btn`'s border is an inherited app-wide
row the design doc knowingly declined to fix, on the grounds that it is somebody else's. **On the
paired card that border is the only thing that makes a button a button.** Every line on that card
is `--ink-soft` at the same size and weight — labels and paragraphs alike (measured: `Forget this
phone` and `Close` both 5.78:1, identical to the four paragraphs above them). So at 1.24:1 in
dark, the card's two controls have **no** visible affordance at all. That promotes the inherited
debt to a required fix on this flow: **`.desk-btn` takes `--line-control`**, which is already in
the product at 3.79 / 4.06:1 and introduces no new color. Frame: Ray's 22.

**Dark-theme coverage, stated honestly.** The route chooser, `This Mac is ready` and the gold
confirm button **could not be re-reached in dark** on this instance, because of blocker 1 — once
serving starts, those screens are gone for the life of the process. Their dark values above are
the specification's, marked "(spec)", not mine. **Every class they use I did measure in dark on
the screens I could reach** (`.overlay-title`, `.overlay-note`, `.phone-step-title`, `.phone-url`,
`.desk-btn`, and `.phone-words` via `.phone-step-title`'s `--ink`), and all pass. When blocker 1
is fixed, those two screens are re-measured in dark before this signoff is revisited.

---

## Gaps — every one, with the frame and the fix

| # | Gap | Frame | Basis | Fix required |
|---|---|---|---|---|
| G1 | **BLOCKER** — reopen mid-pairing renders the home path's certificate screen over a live tailnet code | 13, 14, 15 | seen live | `onTailscale` on the pairing screen reads the Mac's record for the open window, never `route` |
| G2 | No `Pick a different way` on the pairing screen; the route chooser is unreachable once serving starts | — | seen live (could not re-reach) + `phone.js:717,741` | add it, and stop serving |
| G3 | Code is ~1.5 screens below the fold at 1024×700 | 04, 05 | seen live | code block above the phone steps |
| G4 | `Show me another code` scrolls back to the top | 08, 09 | seen live | restore scroll to the code |
| G5 | Raw socket dump, 8 address:port pairs, unconditional | 06 | seen live + `phone.js:899` | delete from the default screen; Techy Mode or nowhere |
| G6 | `.desk-btn` border 1.50:1 / 1.24:1 — sole affordance on the paired card | Ray 22 | computed from pixels | `.desk-btn` border → `--line-control` |
| G7 | Expired screen states the expiry twice, with an orphaned six-words paragraph between | 07 | seen live | `phone.js:146` paragraph has no `hidden` toggle — hide it with `#phone-words-title` (Ray defect B, dispatched) |
| G8 | Paired card has no heading and one text color for all five paragraphs — the actionable line reads like housekeeping | Ray 21, 22 | computed + read | device name becomes a `.phone-step-title`; the push line gets `--ink` |
| G9 | Two settings doors; the technical view duplicated under two names | 10, 11, 12 | seen live | one name now; one Settings sheet before the next row is added |
| G10 | Four action rows in the Settings panel are visually identical to its two headings | 10 | seen live + `style.css:5415,5424` | `.bugbtn` and `.setmenu-title` are both `1rem/600/--ink`; the action rows need the icon `.bugbtn` was built for, or a chevron |
| G11 | Settings panel cannot show its first and last row at 1024×700 | 10, 11 | seen live | subsumed by G9 |
| G12 | Settings panel reopens at its previous scroll position | — | seen live | reset scroll on open |
| G13 | Countdown says "2 more minutes" at 61 s remaining (`Math.ceil`), then jumps to "59 more seconds" | filmed 30 s apart | seen live | a countdown must never overpromise — `floor`, not `ceil` |
| G14 | **The identity screen (§61.1 Screen 0) never renders for a user whose Mac is already signed in to Tailscale** | — | **not seen live** — `phone.js:745` gates it on `!tailnet.account` | see below |

**G14 deserves its own paragraph, and it is a design question rather than a bug.** The identity
screen is shown only while the Mac has no Tailscale account — correct, and the reasoning in the
source is sound: that is the window in which the choice can still be made freely. But it means
the user who already installed and signed in to Tailscale months ago **never sees it**, and that
user is squarely inside §61.1's *"ever user of RichOS"*. What they get instead is one
unemphasized sentence in a stack of four on `This Mac is ready` — *"You signed in with Google as
&lt;account&gt;. Use exactly this on your phone."* (frame 02) — set in `--ink-soft` at 6.33:1,
visually identical to the paragraphs either side of it, with the account **not** given weight.
Two screens later the same account **is** set in bold (`<strong>`, frame 04). That asymmetry is
backwards: the screen that names the account first is the one that whispers it.

**The fix I require for G14 is small.** On `This Mac is ready`, the account sentence gets the same
`<strong>` treatment the phone-steps screen already uses, and it moves directly under the heading,
above the machine name — it is the thing that decides whether this works, and the machine name is
not. `phone.js:819-825` uses `textContent`; the two screens below it use `innerHTML` with
`<strong>`. One of the three is wrong and it is the first one.

---

## What is genuinely right, and should not be touched

- **The route chooser.** Two places, not two mechanisms; both real costs stated on the option
  itself — *"two app installs, one free Tailscale account, and no certificate at all"* against
  *"sixteen taps, once"*. `Anywhere` first, fixed. The limit sentence is on the option where the
  commitment is made. It fits in the window without scrolling. Frame 01. Nothing to change.
- **The route is not remembered.** Verified live: escape, reopen, the question is asked again.
  Frame 03.
- **The expired state's substance.** *"Pairing codes run out on purpose, so one left on a screen
  cannot be used later. Nothing is wrong and nothing was lost."* Calm, honest, names its own
  recovery, does not say sorry. Frame 07. Only the lines around it are wrong (G7).
- **Naming the account instead of saying "the same one".** The whole §61.1 fix rests on this and
  it is right. It just needs the weight fixed on the first screen that does it (G14).
- **The peer line as evidence rather than advice** — *"Your phone (HONOR X6b) is on this
  network."* (frame 02). That is the instrument voice this product is supposed to have.
- **Escape.** Works on every screen I reached, both themes, without clicking into the sheet first.
  **Correction to my own process:** my first three Escape attempts appeared to fail. That was my
  keypress harness (`cliclick kp:esc` in a separate invocation does not reach the app), not the
  product. Re-tested through System Events: closes from the route chooser, `This Mac is ready`,
  the live code screen and the dark pairing screen. **No Escape defect exists.**
- **One `Close`, always on screen, outside every state block.** Held on every screen.
- **The six words as the largest thing on the screen.** 20 px, 18.07:1 light. Correct.

---

## What I did NOT verify, and what would verify it

| Not verified | Why | What would settle it |
|---|---|---|
| The identity screen rendered (Screen 0) | This Mac is signed in to Tailscale, so `tailnet.account` is set and the screen is gated off (`phone.js:745`) | a Mac with Tailscale installed and signed out, or a stubbed `tailnet.account` |
| Screens 2, 3, 7 (install / sign in / no name yet) | same — this Mac is `ready` | the same |
| The paired card, live | I did not pair a phone, by instruction | Ray's frames 21/22 are supporting evidence only; the card has **not** been seen live by me |
| Route chooser and `This Mac is ready` in **dark** | unreachable after serving starts — blocker G1/G2 | re-measure both in dark once G1 is fixed |
| The `At home only` route | out of scope for this audit | a separate walk |

---

## What I disturbed, and what it means

**A second RichOS instance appeared mid-audit and I drove it by mistake.** At **05:06:26** another
agent in this session launched its own RichOS from `scratchpad/sixsec/before/`. It took the front
and my fixed capture region started showing **its** window. Between 05:07:20 and 05:08:45 I sent
it two Tab presses and one Enter, and captured three frames of it.

- **No finding in this signoff rests on any of that.** Frames 01–15 were all captured **04:48:15
  – 05:06:20**, before that instance existed — timestamps read from the files, not recalled. The
  blocker was captured at 05:06:20, six seconds before, and then **independently re-confirmed** on
  pid 9587 at 05:09 after I re-established which window was which (frame 15).
- **The three contaminated frames are excluded and not committed.**
- **What I did to the other agent's app:** dismissed its start screen. I did not connect an
  account, did not send a message, did not change a setting. I stopped touching it the moment I
  identified it, and I did not quit it — it is not mine to quit. It exited on its own at ~05:11.
- **Lead: another agent's app instance and mine were on one screen at one time.** That breaks the
  one-window rule for any visual audit running concurrently, and it is worth knowing before the
  next two visual passes are scheduled together.

**On pid 9587, mine, I changed two things and reverted one.** I toggled `Splash screen` on by
accident — the Settings panel reopens at its previous scroll position (G12) and my click landed a
row off — and toggled it straight back off, verified by pixel: rgb(96,99,103) before, rgb(156,124,52)
on, rgb(96,99,103) after. Theme was left on **dark**; it was found on light. Both live only in the
disposable scratch `HOME`, and the app has been quit.

**I also left the Mac serving.** `Set my phone up` starts a socket that stays up after the sheet
closes, and there is no control anywhere in the flow that stops it (G2). It went away with the
process.

---

## Cleanup

- **App quit with its own Quit (⌘Q)**, after verifying pid 9587 was the frontmost process so the
  keystroke could not reach the other instance. **pid 9587 is gone.**
- `pgrep -f 'richos-qa-cand12'` → **no residue**: no orphaned provider supervisor, no orphaned
  `claude` child, no stray MCP process from the scratch `HOME`.
- `pgrep -fl 'richos-tauri'` → **empty**.
- The background capture loop I started to film the expiry was **bounded to 14 frames** and was
  killed the moment I had the expiry; `pgrep -f 'film-expiry.sh'` → gone.
- No emulator or simulator started. Tailscale never touched. No phone touched. No WebKit site data
  cleared.

## Privacy gate

Every frame below was OCR-scanned before commit for an email address and for the operator's
username:

```
/opt/homebrew/bin/tesseract <frame>.png stdout 2>/dev/null \
  | grep -iE '@[a-z0-9.-]+\.[a-z]{2,}|<his username>'
```

**FINAL GATE: 15 frames, 0 hits.** Four frames needed redaction to get there — the Mac's Tailscale
sign-in name is the CEO's email and it is printed on `This Mac is ready` and twice on the code
screen. Each redaction is a black box over tesseract's own word box, padded, and the frames were
re-scanned afterwards to prove it holds. The address is not written anywhere in this document.

**One thing worth recording about the gate itself:** a word-box pass using a bare four-letter
username matched OCR noise from the Theme control's icons and blacked out a load-bearing control
in three frames. I caught it by looking at the redacted frames, restored those three from the
originals, confirmed by re-scan that they trip nothing, and re-gated. **A redaction is checked by
eye after it is applied, not only by the re-scan that follows it** — a re-scan cannot tell you that
you covered the wrong thing.

## Frames

`docs/verification/2026-09-19-urban-phone-flow/`, in walk order. All 1024 × 700, pid 9587.

| # | Frame | What it shows |
|---|---|---|
| 01 | `01-route-chooser-light.png` | the two options, both costs, fits without scrolling |
| 02 | `02-this-mac-is-ready-light.png` | the §61.1 account sentence, given no weight (G14) |
| 03 | `03-reopen-route-not-remembered-light.png` | the route is asked again on reopen |
| 04 | `04-code-screen-top-light.png` | what `Set my phone up` actually lands on (G3) |
| 05 | `05-code-screen-middle-light.png` | the QR, the address, the countdown, the six words |
| 06 | `06-code-screen-bottom-bound-dump-light.png` | the socket dump (G5); focused `Close` |
| 07 | `07-expired-orphan-six-words-light.png` | expiry stated twice, orphan paragraph between (G7) |
| 08 | `08-fresh-code-returns-to-top-light.png` | `Show me another code` scrolls to the top (G4) |
| 09 | `09-fresh-code-live-light.png` | the fresh code, 5 more minutes |
| 10 | `10-settings-panel-top-light.png` | four action rows styled as headings (G10); Theme at top |
| 11 | `11-settings-panel-overflows-light.png` | `Bust a bug!` at the bottom, Theme gone (G11) |
| 12 | `12-second-settings-door-rail-gear-light.png` | the other settings door, "Technical view" (G9) |
| 13 | `13-BLOCKER-home-path-warnings-and-trust-qr-dark.png` | **G1** — home warnings + trust QR on the tailnet route |
| 14 | `14-BLOCKER-sixteen-steps-over-tailnet-url-dark.png` | **G1** — sixteen certificate taps above the tailnet pair URL |
| 15 | `15-BLOCKER-reconfirmed-after-interruption-dark.png` | **G1** re-confirmed on pid 9587 after the interruption |

---

## What has to be true before I sign this off

1. **G1 fixed at the root** — the pairing screen's path comes from the Mac's record for the open
   window, not from `route`. Re-walked in both themes, and again after an expiry.
2. **G2** — `Pick a different way` on the pairing screen, and it stops serving.
3. **G3 + G4** — the code above the instructions; `Show me another code` returns to the code.
4. **G5** — the socket dump gone from the default screen.
5. **G6** — `.desk-btn` border at `--line-control`, measured in both themes.
6. **G7, G14** — the orphan paragraph hidden; the account sentence given weight and moved up.
7. **The route chooser and `This Mac is ready` re-measured in dark**, which G1/G2 currently make
   impossible.

G8, G9 through G13 are documented and required, but they do not hold the signoff on their own.

**Until then: signoff WITHHELD, and this flow does not go in front of the CEO.**

— Urban
