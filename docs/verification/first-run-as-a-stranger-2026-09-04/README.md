# First run as a stranger — RichOS 1.0.0, published macOS artifact

**Ray (QA — functional testing and user advocacy), 2026-09-04, 15:37–16:00 local.**

The question this answers: what happens to a person who is not the author when he
downloads RichOS 1.0.0 and opens it in his lunch break. Nobody had run this application
outside the author's development tree before this session.

## Verification mode

| | |
|---|---|
| Artifact | `RichOS-1.0.0-macos-aarch64.zip`, downloaded from the public GitHub release |
| SHA-256 of the zip | `b2ec84da449c1297cd678bae21756d73d2d179e3f1b8d65ef1810d4a5c4df320` |
| Bundle identity | `com.richos.app`, `CFBundleShortVersionString` 1.0.0, signed `Developer ID Application: Alex Booster (TZ33A4QCZJ)`, notarization ticket stapled |
| Environment | macOS 24.6.0, Apple silicon, two 1920x1080 displays, single window throughout |
| Launch method | Finder open of the extracted `.app` — a real LaunchServices GUI launch, never `open` from a terminal, never `cargo run`, never the local build output |
| Quarantine | Safari-style `com.apple.quarantine` attribute applied to the zip before extraction and confirmed to propagate to the `.app` and its executable |
| Extraction | Archive Utility (macOS default handler), the path a person actually takes |
| Two-user test | No — single user, single window |
| Local state | The operator's own RichOS state was renamed aside before the run and restored afterwards; see "State handling" |

**Verification basis for every finding below: observed live, on the published artifact, in
a Finder-launched window on this Mac.** Nothing here is inferred from source, and nothing
here is inferred from a screenshot taken by somebody else. Where a claim rests on something
other than live observation, it says so in the finding.

## What works, stated first because it was the open question

- **The zip is correctly signed and notarized, and Gatekeeper does not object.** Extracted
  with Archive Utility and Finder-launched with the quarantine attribute present, the app
  opened with **no Gatekeeper prompt of any kind** — no "downloaded from the Internet"
  dialog, no "unidentified developer", no bounce-and-die. `spctl -a -t exec` returns
  `accepted / source=Notarized Developer ID`.
- **The app runs App-Translocated** (from `/private/var/folders/.../AppTranslocation/...`)
  and works from there, so it does not need to be dragged to `/Applications` first.
- **The first-run setup sheet appears, and the engine fetch and digest verification
  SUCCEED from a genuinely empty state.** This was the step nobody had ever seen succeed.
  It correctly detected that Claude Code was already installed, offered only the engine,
  and completed in roughly three seconds. Verified on disk afterwards: 456 files,
  `VERSION` = 1.0.0, `scripts/hooks/` present, `INSTALLED-FROM` marker written, installed to
  `~/Library/Application Support/RichOS/engine`.
- **Contrast meets WCAG AA in both themes at every node measured.** Computed, not
  eyeballed — see "Contrast" below.

## Findings, ordered by what will hurt a first-time user most

### 1. The first message always fails. A restart fixes it permanently. (Blocker)

On a fresh install, the first message a user sends is answered with this, verbatim:

> I'm not connected to my thinking right now, so I can't take that on. Quit RichOS and open
> it again — that clears it most of the time. If it keeps happening, whoever set RichOS up
> has to sign me back in; that part isn't yours to fix. Your words are back in the box
> below, word for word — press Send when you want me to try again.

Quit and reopen, send the identical message, and a full and correct answer comes back.
Broken on run 1, working from run 2 onward.

**This is not authentication, not a missing `claude` binary, and not a missing engine, and
that is proven rather than assumed.** The app really did spawn `claude` (PID 42791, parent
= the app process) with its working directory correctly set to the newly installed engine.
Running the app's own command line by hand in that same directory returned a clean answer
in 1.7 seconds. So the account, the CLI and the engine were all healthy while the app was
telling the user it was not connected. The app's own session handshake is what does not
come up on the run that installs the engine.

Evidence: `shots/shot-16-sent-btn.png` (failure), `shots/shot-21-post-restart-msg.png`
(same message answered after a restart).

**User impact.** Someone with minutes and no patience does the whole setup, types his first
sentence, and is told the product is not connected to its own thinking. Being told to quit
and reopen an application he installed sixty seconds ago reads as "this is not finished".
The workaround is real and cheap, but he has to survive the failure to reach it.

### 2. Voice presents as working when it cannot work. (Blocker for a live demo)

Tapping the talk button asks for microphone permission with well-written copy, and then
shows `listening…` with a live level meter and the hint `headphones recommended · tap to
end voice`. The orange microphone indicator appears in the menu bar. It stayed in that
state for more than 25 seconds. It never transcribed anything and it never said it could
not.

This is the case the brief asked about — does an unfinished thing fail as "not ready yet"
or as "this app is broken" — and the answer is that it fails as broken. It does not look
unfinished; it looks like the app is listening to you and ignoring you.

It is made worse by the app inviting it. Rich's own opening line is:

> I'm Rich — your chief of staff. Tell me what you're working on and I'll take it from
> there. You can type, or tap ⏺ to talk to me.

Evidence: `shots/shot-22-voice.png`, `shots/shot-24-voice-wait.png`.

### 3. The window opens small, and on the second launch it opened off the main screen

The window opens at 960x720. On the second launch it was placed at y = -971, entirely
above the main display — on this machine it landed on a second monitor, but on a
single-screen Mac that position is simply not visible. Both launches also opened *behind*
other windows rather than coming to the front.

Someone who double-clicks and sees nothing appear concludes the app did not start.

**Basis note:** the off-screen placement was observed once, on a two-display machine, so
the specific coordinate is not proof of what a single-display Mac does. The observable
facts that are certain are that the window opens at 960x720 and that it does not come
forward on launch.

### 4. The memory step dead-ends with an instruction the user cannot follow

After accepting the memory folder, the app says, verbatim:

> Your memory is on this Mac, but the part of me that reads it isn't installed here — so I
> can't read it back yet. It needs whoever set RichOS up to add it.

For a person who installed RichOS himself, "whoever set RichOS up" is him. No action is
offered and no button is present. The product's headline promise is that Rich remembers
you, and on first run it says memory does not work and somebody else has to fix it.

This sheet also **reappears on every launch**, not only the first, so it is a permanent nag
rather than a one-time notice.

Evidence: `shots/shot-08-corpus.png`.

### 5. The app asks about one path and reports a different one

The consent sheet asks "Where should I keep what you tell me?" and names
`/Users/alex/RichOS/corpus`. After the user agrees, the result names
`/Users/alex/Library/Application Support/RichOS/corpus`.

**These are the same place** — the second is a symlink to the first, verified on disk after
the run. Nothing was written anywhere the user did not agree to. But on the one screen
that is explicitly about trusting the app with personal data, being shown a different path
after consenting than before consenting invites exactly the wrong conclusion. Report the
path he was asked about.

Evidence: `shots/shot-07-closed2.png` (ask), `shots/shot-08-corpus.png` (report).

### 6. Enter does not send, and text typed too early is silently discarded

- Pressing Enter in the composer does nothing — not before a company is chosen and not
  after one is. Only the send arrow sends. There is no visible hint that Enter is not the
  send key.
- Before a company is chosen, both Enter and the send button are silent no-ops. The
  explanation is on screen, but it was already on screen *before* the user typed, so it
  reads as ambient decoration rather than as a response to his action. A person types a
  sentence, presses Enter, and the application says nothing at all.
- The sentence typed before choosing a company was **discarded** when the company sheet
  completed. His words were gone.

Evidence: `shots/shot-10-composer.png`, `shots/shot-14-company-added.png` (composer empty
again).

### 7. Copy defects on the first two sheets the user ever sees

- Singular/plural: **"There's one thing I need on this Mac. I can get them myself — you
  just have to say so."** One thing, "them".
- After the install succeeds, the heading still reads **"There's one thing I need on this
  Mac."** while the body underneath reads **"That's everything. I'm ready."** The two
  sentences contradict each other on screen at the same time.

Evidence: `shots/shot-04-talk-to-rich.png`, `shots/shot-05-setup-running.png`.

### 8. The opening screen shows a dashboard of numbers that are not the user's

The splash presents `LORO · 14 MONTHS · 7,509 MEMORIES`, `18 AI SPECIALISTS · 6 working
now`, `1,596 TASKS HANDLED WITHOUT YOU`, `4,801 SOURCES UNDERSTOOD`, `430 DECISIONS
REMEMBERED`, `2,365 h OF YOUR ATTENTION SAVED`, and a live-looking `WORKING NOW` list of
named specialists — on an installation with no data in it. The counters tick upward while
you watch.

There is a disclaimer, and it is honest and legible: "This is what your home screen could
look like once Rich knows enough about you and your business." It sits top-right, away
from the numbers, and it is one sentence against six large figures and a moving list.

**User impact, and it is specific to a show-and-tell:** if an audience asks what the
eighteen specialists are doing right now, the honest answer is "nothing, that is a
picture of a future state", and that is a bad moment to discover in front of a room.

Evidence: `shots/shot-02-front.png`.

### 9. Rich's first answer volunteers connector state the user did not ask about

The first reply ended with "Also worth flagging: Gmail, Calendar, and Drive aren't
authorized in this session. If you want me touching your inbox or schedule, you'd need to
connect those in your claude.ai connector settings first." Nobody asked. It is chatter
about plumbing, in the first impression.

Evidence: `shots/shot-21-post-restart-msg.png`.

### 10. Command-line `unzip` produces an app macOS calls damaged

Not on the main path, recorded because it is cheap to hit and expensive to diagnose.

The published zip contains an AppleDouble entry, `RichOS.app/Contents/._CodeResources`.
Archive Utility and `ditto -x -k` merge it correctly and the signature verifies.
Command-line `unzip` leaves it as a real file and breaks the seal:

```
$ codesign --verify --deep --strict unzipped/RichOS.app
unzipped/RichOS.app: a sealed resource is missing or invalid
file added: .../RichOS.app/Contents/._CodeResources
$ spctl -a -vvv -t exec unzipped/RichOS.app
unzipped/RichOS.app: a sealed resource is missing or invalid
```

Anyone who unzips from a terminal, or moves the app through a tool that does not
understand AppleDouble, gets an app macOS refuses. Producing the archive with `ditto -c -k
--keepParent` and no resource forks would remove the trap.

## Contrast — computed, both themes

Standing rule: WCAG AA, 4.5:1 normal text, 3:1 large text and non-text indicators, in both
light and dark mode. Ratios were computed from the captured pixels, not judged by eye.

| Node | Dark mode | Light mode |
|---|---|---|
| Splash disclaimer sentence | 10.03:1 | not measured |
| Empty-state notice (amber) | 7.86:1 | not measured |
| Splash "Enter" hint | 8.57:1 | not measured |
| Voice status line | 10.28:1 | not measured |
| Sidebar item ("Corrections") | 6.56:1 | 5.83:1 |
| "Set your name" | 6.18:1 | 4.99:1 |
| Search shortcut hint | not measured | 4.84:1 |
| Composer placeholder | not measured | 5.37:1 |
| "Copy" affordance | not measured | 4.99:1 |

Every node measured passes AA in the theme it was measured in. The narrowest margin is the
search shortcut hint in light mode at 4.84:1. **No exemptions are claimed anywhere in this
audit** — nothing here was set aside as skippable text.

The measuring script is `contrast.py` alongside the screenshots: it converts sRGB to
relative luminance per the WCAG formula and takes the glyph core (brightest 2% of pixels on
dark, darkest 2% on light) against the modal background of a tight box around the text.

## State handling — what was moved and what was restored

To make this an honest first run, operator state the stranger would not have was renamed
aside before launch and renamed back afterwards. Nothing was deleted.

Moved aside and **restored, verified**:

| Path | Restored |
|---|---|
| `~/Library/Application Support/com.richos.app/` | yes — all seven entries back with original timestamps and byte-identical `config.json` and `entities.json` |
| `~/Library/Application Support/RichOS/loro-root` (symlink to `~/ab/richos-hq`) | yes |
| `~/.claude/richos-engine` (symlink to `~/ab/richos/engine`) | yes, and reachable — `VERSION` reads 1.0.0 through it |

Artifacts the stranger run created, **parked rather than deleted** so they can be inspected
or removed deliberately:

- `~/Library/Application Support/com.richos.app.RAY-STRANGER-RUN-2026-09-04/`
- `~/Library/Application Support/RichOS/engine.RAY-STRANGER-RUN-2026-09-04/` (the fetched engine)
- `~/Library/Application Support/RichOS/corpus.RAY-STRANGER-RUN-2026-09-04` (symlink, now dangling)
- `~/RichOS.RAY-STRANGER-RUN-2026-09-04/` (the corpus repository the app created)
- `~/Downloads/RichOS-1.0.0-macos-aarch64.zip` and `~/Downloads/RichOS.app`

**Two declared exceptions, with reasons, because an undeclared exception is a gap wearing a
justification:**

1. `~/Library/Application Support/RichOS/ecs/` was **left in place**. It is the executive
   event store, it was being written by live sessions during this run, and it is not app
   state the application reads. Moving it risked losing the operator's data to no
   diagnostic benefit. The engine-install slot it shares the directory with
   (`RichOS/engine`) was empty before the run, so the engine fetch was still exercised
   from a genuinely empty state.
2. `~/.richos-signing/` was **left in place**. It holds signing and notarization
   credentials, it is read only by build scripts, and `strings` on the shipped binary
   contains zero references to it — so it cannot affect a first run. Another teammate's
   packaging work depends on it being where it is.

Microphone permission was granted to the App-Translocated copy during the voice test. That
grant is bound to a temporary path and disappears with it; no permission was granted to any
application the operator uses.
