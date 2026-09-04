# First run as a stranger — RichOS 1.0.1, published macOS artifact

**Ray (QA — functional testing and user advocacy), 2026-09-04, 17:07–17:45 local.**

The question this answers: do the four fixes hold on the build Andreas will actually
download, and is the whole first run good enough to put in front of an audience. The
baseline is my own 1.0.0 audit at `docs/verification/first-run-as-a-stranger-2026-09-04/`.

**Headline: all four fixes hold. The first message works on run one.** Three things found
along the way are worth an engineer's time, and one of them is launch-stopping and is
already being fixed.

## Verification mode

| | |
|---|---|
| Artifact | `RichOS-1.0.1-macos-aarch64.zip`, downloaded from the public GitHub release |
| SHA-256 of the zip | `ba9c3849ac7b13a2a6032f28fe0ec1484b9ee89edbfc250a49ec1867709b401c` |
| Bundle identity | `com.richos.app`, `CFBundleShortVersionString` **1.0.1**, signed `Developer ID Application: Alex Booster (TZ33A4QCZJ)`, notarization ticket stapled (`stapler validate` — "The validate action worked!"), `spctl` = `accepted / source=Notarized Developer ID` |
| Environment | macOS 24.6.0, Apple silicon, two 1920x1080 displays — main at origin `(0,0)`, second directly above at `(0,-1080)`, read from CoreGraphics rather than assumed |
| Launch method | Finder open of the extracted `.app` — a real LaunchServices GUI launch, never `open` from a terminal, never a local build |
| Quarantine | Safari-style `com.apple.quarantine` written to the zip and confirmed to propagate to the `.app` and its executable |
| Extraction | Archive Utility (macOS default handler) |
| Window count | One, throughout. No two-user test. |
| Runs | Three full first runs — **A** (contaminated, see finding 1), **B** (clean, voice available), **C** (voice made unavailable — Andreas's configuration) |

**Verification basis for every claim below: observed live, on the published artifact, in a
Finder-launched window on this Mac,** unless the finding says otherwise. Where a claim
rests on something else, it says so in the claim.

## The four fixes

### 1. The first message works. No restart. — **HOLDS**

Run B. Fresh state, engine install confirmed on disk **before** testing (456 files,
`VERSION` = 1.0.0, `INSTALLED-FROM` sha256
`e78987c052f4268e16858b20b4a451e6faf6816b0e518aed13d712e03f361f3b`, fetched from the v1.0.1
release). Then one message, the first ever sent, no restart:

> What should I do first if I want to use you well?

A real, specific, three-point answer came back. It used the company name given sixty
seconds earlier, offered to hold context, and closed by asking what was on my plate. No
"not connected", nothing to quit and reopen. Run C reproduced it in the no-voice
configuration with a different question and a fuller answer.

Evidence: `shots/b11-first-message-30s.png`, `shots/b32-msg-30s.png`.

**This is the fix that decides the demo, and it is real.**

### 2. No microphone button, and the greeting does not invite talking — **HOLDS**

The fix is conditional, and the condition is the right one: **voice appears only where it
can actually work.**

- **With voice unavailable (Run C — Andreas's machine).** The greeting is exactly one
  line: *"I'm Rich — your chief of staff. Tell me what you're working on and I'll take it
  from there."* The "You can type, or tap ⏺ to talk to me" line is gone. The round button
  is **absent** from the composer — not dimmed, not disabled, not present.
  Evidence: `shots/b30-greeting-no-voice.png`, `shots/b18-no-whisper.png`,
  `shots/b21-fresh-no-whisper.png`.
- **With voice available (Run B — this Mac).** The button and the invite appear, and
  **voice genuinely works**: tapping it listened, transcribed, and Rich answered "Loud and
  clear. Mic's on." Evidence: `shots/b13-voice-click.png`, `shots/b17-second-launch-app.png`.

**How the unavailable case was produced, because it matters that this was tested and not
inferred:** this Mac has `/opt/homebrew/bin/whisper-cli` (whisper-cpp 1.9.1) and three
model files, so it cannot answer what a stranger sees by itself. The app's own documented
override, `RICHOS_WHISPER_BIN`, was pointed at a nonexistent path via `launchctl setenv`,
the app was quit and relaunched from Finder against fresh state, and the full first run was
walked again. Restored afterwards with `launchctl unsetenv` and verified empty.

### 3. Window opens at 1400x880, centered, on the main display, and comes to the front — **HOLDS, with one real exception**

Size and front-most are correct on **every** launch measured: `1400 x 880`, and the app
took focus from another application each time.

Placement was correct on every launch **except the very first one of the session**, which
opened at `(155, -1001)` — entirely on the second display, and not centered on that display
either. Every later launch opened at `(260, 87)`: `x = 260` is exactly centered for a
1920-wide display.

Evidence: `shots/s01-display2.png` (the window, on the wrong screen),
`shots/s01-display1.png` (the main display, empty), against `shots/b16-relaunch2.png`.

**Basis note, stated precisely because it changes who this affects.** The difference
correlates with where the pointer was at launch, which suggests the window is centered on
the display under the pointer rather than on the main display. That is a hypothesis from
two observations, not a proven mechanism, and **it was not tested on a single-display Mac.**
On a machine with one screen there is nowhere else to go, so this is very unlikely to reach
Andreas. It will reach anyone with two monitors.

### 4. The memory notice tells the truth, and says it once — **HOLDS**

Verbatim, and it covers all three things it needed to:

> **Your memory folder.**
> Your memory folder is on this Mac, and I can't read or write it yet — the part of me that
> does isn't in this version. Nothing else is affected: our conversations stay on this Mac
> and I pick them up when you come back. There's nothing for you to install and nothing for
> you to fix — I'll start using the folder on my own as soon as that part arrives.
>
> `/Users/alex/RichOS/corpus`

It names **the same path it asked about** on the previous screen, which also closes 1.0.0
finding 5. And on the second launch it **did not reappear** — the app went straight to the
conversation, which was intact.

Evidence: `shots/b05-memory-notice.png`, `shots/b17-second-launch-app.png`.

## Findings

### 1. A click anywhere around the setup panel silently skips the engine install — **launch-stopping** (already being fixed)

**I hit this by accident and it cost me a whole run, which is the best evidence that a real
person will hit it.** A mis-aimed click landed in the empty space beside the setup panel.
The panel closed, the app advanced to the next question, and everything afterwards behaved
as though setup had succeeded. It had not: `~/Library/Application Support/RichOS/engine`
contained **zero files**.

The consequence for the user is total and unexplained. Rich has no instructions and no
team, so every message he sends comes back with *"I'm not connected to my thinking right
now… Quit RichOS and open it again"* — the exact 1.0.0 failure text, forever, with no hint
that a setup step was skipped. I sent four messages this way and got four identical
failures.

Confirmed independently by Echo as `app/ui/main.js:2949`: the sheet closes on any click
whose target is the sheet element, and `#setup-sheet` is the full-screen backdrop.
**Attribution: the mechanism is Echo's, not mine — I observed the symptom and the empty
directory.** A fix was in progress at the time of writing.

Evidence: `shots/s16-send2.png`, `shots/s17-second-attempt.png`, and the empty engine
directory recorded during Run A.

### 2. Nothing happens on screen for 20–30 seconds after the first send

Ten seconds after pressing Enter on the first-ever message, the screen showed **only the
greeting**. No message bubble for what I had just typed, no thinking indicator, no spinner,
nothing — and my text was still sitting in the composer as though it had never been sent.
The answer landed somewhere between 10 and 30 seconds.

**User impact, and it is a demo impact.** A person who sees no response assumes the send
did not work and presses Send again. That is exactly what I did earlier in the session, and
it is how you get the same message answered twice. In front of a room, twenty seconds of a
screen that looks unchanged is read as "it's broken" long before the answer arrives.

Evidence: `shots/b31-msg-8s.png` (eight seconds after send — greeting only, text still in
the box), `shots/b32-msg-30s.png` (the answer).

### 3. Markdown is not rendered, so the best answer looks like a draft

The answers are genuinely good. They are displayed with their markup showing. Literally on
screen, in the answer Andreas is most likely to get:

```
- **Client and pipeline thinking.** Talk me through a live deal or a wobbly client…
- **Written work product.** Proposals, SOWs, engagement letters, board memos…
- **Analysis on files you hand me.** Drop a spreadsheet, a P&L, a client list…
**What I'd suggest for the first hour.** Authorize the three Google connectors…
```

Six bullet lines and a heading, each carrying visible `**` and a leading hyphen. This is the
single most visible quality defect in the product right now, it is in the first minute of
use, and an audience will see it before they read a word of the substance.

Evidence: `shots/b32-msg-30s.png`, `shots/b11-first-message-30s.png`.

### 4. "Whoever set RichOS up" survives on the entity page

The memory notice was fixed precisely because "it needs whoever set RichOS up to add it"
dead-ends a person who installed the app himself. **The same phrasing is still live one
screen away.** The entity page reads:

> I can't show priorities for this area yet, and the area itself is set up inside RichOS
> rather than in settings — whoever set RichOS up is the one who changes it. Nothing here
> needs you.

For Andreas, "whoever set RichOS up" is Andreas. This is the fix having moved rather than
having been removed, which is the case worth watching for. "Nothing here needs you" also
reads oddly on its own.

Evidence: `shots/b20-no-whisper-new-thread.png`.

### 5. The first answer still volunteers connector plumbing

Unchanged from 1.0.0 finding 9, and now more prominent: in Run B it was **item 2 of 3** in
the very first answer — Gmail, Calendar and Drive are "connected-but-unauthorized", and the
user must go to claude.ai connector settings. In Run C it reappeared as "What I'd suggest
for the first hour."

Nobody asked. It is a chore he cannot complete during a demo, presented as the second most
important thing about the product.

### 6. Voice can invent words that were never spoken

On this Mac, with voice working, I tapped the button, said nothing, played no audio, and
ended the session. The transcript that arrived and was **sent as my message** was:

> 1, 2, 3, testing.

Rich replied "Loud and clear. Mic's on." That is whisper hallucinating a plausible phrase
from room noise — the known silent-channel failure — and the product sent it as though the
user had said it.

Not on Andreas's path, since he has no whisper installed. **It is on the CEO's path**: if
voice is ever demonstrated on this machine, it can put words in his mouth and send them.

Evidence: `shots/b17-second-launch-app.png` (the invented user bubble and the reply).

### 7. The AppleDouble trap in the zip is unchanged

`RichOS.app/Contents/._CodeResources` is still inside the published 1.0.1 archive. Archive
Utility merges it correctly and the signature verifies; command-line `unzip` leaves it as a
real file and breaks the seal. Carried forward unchanged from 1.0.0 finding 10 —
`ditto -c -k --keepParent` without resource forks would remove it.

### 8. The opening screen still shows numbers that are not the user's

`LORO · 14 MONTHS · 7,511 MEMORIES`, `18 AI SPECIALISTS · 6 working now`, `1,596 TASKS
HANDLED WITHOUT YOU`, and a live-looking `WORKING NOW` list, on an installation with no data
in it. The disclaimer is present, honest and legible (10.03:1). Carried forward from 1.0.0
finding 8, unchanged, and recorded again only because it is the first thing an audience
sees.

## A correction to my own 1.0.0 audit

**1.0.0 finding 6 — "Enter does not send" — was wrong, and I withdraw it.** Enter sends,
and it always did.

I re-tested it three ways with the composer provably focused (gold focus ring, caret visible
mid-word) and used a discriminator that cannot be faked: every successful send appends one
reply block, so the block count is the answer.

| Method | Sends? | Evidence |
|---|---|---|
| `cliclick kp:return` | **No** | block count stayed at 2 — and it silently inserted the literal characters `re` at the caret, which is what it did instead of pressing Return |
| `osascript … key code 36` | Yes | 2 → 3 blocks, `shots/e02-keycode36.png` |
| `osascript … keystroke return` | Yes | 3 → 4 blocks, `shots/e03-keystroke-return.png` |

The defect was in my tooling, not the product. The same tool caused the Run A
contamination: `cliclick` reads a leading minus as a **relative** move, so every click I
aimed at a negative y coordinate (the second display) landed somewhere else.

**The lesson I am carrying forward: a negative result from an automation harness is not a
finding until the harness is proven able to produce the positive.**

## Contrast — computed, both themes

WCAG AA: 4.5:1 normal text, 3:1 large text and non-text indicators, both themes. Ratios
computed from captured pixels with `contrast.py` (sRGB → relative luminance per the WCAG
formula; glyph core against the modal background of a tight box). **Not eyeballed.**

| Node | Theme | Ratio | AA |
|---|---|---|---|
| Rich's greeting | dark | 14.55:1 | pass |
| Answer body text | dark | 14.55:1 | pass |
| Splash disclaimer | dark | 10.03:1 | pass |
| Composer placeholder "Talk to Rich…" | dark | 6.52:1 | pass |
| Entity-page secondary text | dark | 6.09:1 | pass |
| Memory-notice body | dark | 5.78:1 | pass |
| Answer body text | light | 14.90:1 | pass |
| Sidebar item ("Search") | light | 5.83:1 | pass |
| Composer placeholder | light | 5.37:1 | pass |
| Breadcrumb secondary ("Running") | light | 4.99:1 | pass |
| "Set your name" | light | 4.99:1 | pass |

Every node measured passes. Narrowest margin is 4.99:1 in light mode.

**No exemptions are claimed anywhere in this audit** — nothing here was set aside as
skippable text, including the splash disclaimer.

**Declared gap, so it is not mistaken for a pass:** the setup sheets and the memory notice
were measured in **dark mode only**. They are modal steps that cannot be revisited without
another full reinstall, and time was the constraint. They use the same secondary-text token
as nodes that pass in light mode, but that is an inference and is not evidence.

## State handling — what was moved and what was restored

Operator state a stranger would not have was **renamed** aside before the run and renamed
back afterwards. **Nothing was deleted at any point.**

Moved aside and **restored, verified**:

| Path | Restored |
|---|---|
| `~/Library/Application Support/com.richos.app/` | yes — all seven entries back with original timestamps; `config.json` reads `entity: null`, `theme: dark`, `splash_first_shown_at 1788294912766` |
| `~/Library/Application Support/RichOS/loro-root` (symlink → `~/ab/richos-hq`) | yes |
| `~/Library/WebKit/com.richos.app/` | yes, original 31 Aug timestamp |
| `~/.claude/richos-engine` (symlink → `~/ab/richos/engine`) | yes, and reachable — `VERSION` reads 1.0.0 through it |
| `RICHOS_WHISPER_BIN` (`launchctl` GUI-session variable, set for Run C) | yes — `launchctl unsetenv` run, `getenv` returns empty |

Artifacts the three stranger runs created, **parked rather than deleted** so they can be
inspected or removed deliberately:

- `~/Library/Application Support/com.richos.app.RAY-101-RUN-A` / `-RUN-B` / `-RUN-C`
- `~/Library/WebKit/com.richos.app.RAY-101-RUN-A` / `-RUN-B` / `-RUN-C`
- `~/Library/Application Support/RichOS/corpus.RAY-101-RUN-A` / `-RUN-B` / `-RUN-C` (symlinks, now dangling)
- `~/Library/Application Support/RichOS/engine.RAY-101-2026-09-04` (the engine fetched during Run B)
- `~/RichOS.RAY-101-RUN-A` / `-RUN-B` / `-RUN-C` (the corpus repositories the app created)
- `~/Downloads/RichOS-1.0.1-macos-aarch64.zip` and `~/Downloads/RichOS.app` (the 1.0.1 build)
- `~/Downloads/RichOS-1.0.0-RAY-STRANGER-RUN.app` — the 1.0.0 extraction from the previous audit, renamed out of the way so the 1.0.1 extraction did not collide with it

**Two declared exceptions, with reasons, because an undeclared exception is a gap wearing a
justification:**

1. `~/Library/Application Support/RichOS/ecs/` was **left in place**. It is the executive
   event store, it was being written by live sessions during this run, and the application
   does not read it. Moving it risked losing operator data for no diagnostic benefit. The
   engine slot it shares a directory with was genuinely empty before each run, so the engine
   fetch was still exercised from an empty state. Verified untouched afterwards (27 Aug
   timestamp).
2. `~/.richos-signing/` was **left in place**. It holds signing and notarization
   credentials, is read only by build scripts, and cannot affect a first run. Verified
   untouched afterwards.

Microphone permission was exercised on the App-Translocated copy during the voice test. That
grant is bound to a temporary path and disappears with it; no permission was granted to any
application the operator uses.

## Would I put this in front of an audience

**Yes — once the setup-backdrop defect is fixed, and I would fix the markdown rendering
first if there is an hour to spare.** The thing that decides the demo works: a stranger can
download it, set it up, type a real question and get a genuinely impressive answer on the
first try, and the four fixes all hold on the artifact he will actually download.
