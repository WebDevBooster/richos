# Audit — today's main, walked on his screen (development build `1.2.0-dev.aa0165cc`)

Ray (QA, functional testing and user advocacy). 2026-09-17, 09:59Z–10:35Z (10:59–11:35 local).
Target: a development bundle built here from richos main at `aa0165cc`, booted with
`RICHOS_ACTIVATION=regular` on his monitor under a scratch `HOME`, with this Mac's audio
unconstrained.

Ordered by the CEO in `richos-hq/wiki/ceo-decisions.md:2545` (§45 addendum 2), verbatim:

> *"shouldn't the QA be before the nightly build? QA can start now. Audio can be used freely.
> But shouldn't the defects be fixed first?"*

---

## Verdict

**NOT READY TO BUILD THE NIGHTLY. Two blockers, and neither is a matter of polish.**

The product itself walked well and this audit says so at length: every one of the six landed
fixes I was asked to verify does what it claims, on screen; Escape closed **ten** different
popups including the three the old hand-written list never knew about; the speech model
downloaded and verified against its pin; the thread survived a quit and relaunch with both
turns and the theme intact; and **contrast passes at all 118 nodes I measured, in both
themes**. Nothing crashed, nothing was lost, nothing rendered a wrong number.

What stops the nightly is narrower and sharper.

| # | What | Severity | Basis |
|---|---|---|---|
| **B1** | **A development build cannot answer, so the walk the CEO ordered cannot test the thing he cares about.** A plain `package-app.sh` build carries no engine pin and no delivered runtime, so **both** turns I sent — one typed, one spoken — were refused locally before they reached anything. "Fix → QA on a development build → nightly" therefore verifies everything except whether Rich replies. | **Blocker — a decision about the method, before the second walk** | Ran it + the app's own ledger + source |
| **B2** | **The defects his order says to fix first are still on branches, and every one of them reproduces on main at `aa0165cc`.** D4, D5, D6, D7 and D8 reproduce outright; D1 and D2 reproduce in altered form. Cutting the nightly at this SHA ships all seven. | **Blocker — sequence, by his own instruction** | Ran it on screen |
| **N1** | **A white native scrollbar is jammed into the right end of the message box**, through its rounded corner and its focus ring, on an empty box with nothing to scroll. Both themes. It is the first thing the eye catches on the compose bar. | High, user-facing | Ran it on screen, 5 frames |
| **N2** | **"Connected repositories" and "Account connection" render as raw, unstyled macOS buttons — pure white `#FEFEFE`** — on the navy settings panel, in the dark theme, breaking the panel's grid as well as its palette. | High, user-facing (cosmetic but unmissable) | Ran it + sampled pixels |
| **N3** | **The technical-view badge is cut off mid-word and runs underneath the settings gear**: "Technical view · this conversat". No ellipsis; the gear simply sits on top of it. | Medium, user-facing | Ran it on screen |
| **N4** | **One press of Enter submits the turn twice.** A `crash_recovery` action replays the interrupted turn 22 ms later with identical text. On a build that can actually reach the model, that is two requests from one keystroke. | Medium, and it costs money | The app's own ledger |
| **N5** | On the home screen, Escape closes the settings panel but leaves focus on the gear, so the **next Enter re-opens the panel** instead of doing what the "Enter" hint under "Talk to Rich" promises. | Low, user-facing | Ran it on screen |
| **N6** | The same gear in the same corner opens **two different panels** — the home screen's has no Theme row, the app's does. | Low, consistency | Ran it on screen |
| **N7** | Operator-facing: `input silent: … on an OPEN stream - muted mic, gain at zero, or a denied permission` is printed when the input is an injected WAV, where none of the three named causes can apply. | Low, operator-facing | Ran it + `controller.rs:1159` |

**Contrast is not on that list, and that is a result rather than an omission** — see
"What passed, loudly".

### What I recommend, in one line each

- **B1:** decide how a pre-nightly walk reaches a working engine — a documented
  `RICHOS_ENGINE_*` development pin, a locally built runtime, or an explicit
  "turns are not in scope for a development-build walk". Any of the three is fine; the
  current position (a walk that silently cannot test answering) is not.
- **B2:** land the in-flight D1–D8 branches, then re-walk, then cut the nightly. That is
  exactly the order he asked for.

---

## Premise corrections — the brief's own re-derivation clause

The brief flagged its own claims for checking. Here is what checking found.

| The brief's claim | Verdict |
|---|---|
| CEO, verbatim: *"shouldn't the QA be before the nightly build? QA can start now. Audio can be used freely. But shouldn't the defects be fixed first?"* | **Holds verbatim**, `richos-hq/wiki/ceo-decisions.md:2545`. |
| *"That is now allowed"* (audio) — flagged by the brief as sourced-but-not-established | **It IS established, and by a source that carries authorization rather than measurement**: the same §45 addendum 2 says *"the no-sound constraint of the night is lifted — QA may use this Mac's audio freely."* The brief was right to flag its own evidence and wrong about the conclusion; the ruling exists. |
| *"Your previous two audits of this app"* — flagged as unsourced | **Both exist**: `2026-09-17-nightly-1.2.0-20260917.1-silent-audit.md` and `…-onscreen-audit.md`. I read the second one's method section and reused its technique. |
| Escape via a DOM-derived enumeration, `62f716c3` | **Holds.** `62f716c3` is "Escape closes every popup, and the version on screen is the running build's". |
| *"the version on screen is the running bundle's and `package-app.sh` stamps a development build … (`aa0165cc`)"* | **Two changes, two commits.** The version-on-screen half is `62f716c3`; only the dev stamp is `aa0165cc`. Nothing turns on it, but the SHA in the brief is attached to the wrong half. |
| Home temporary line + window blind path, `36db2058` | **Holds.** "the temporary line carries its own shadow, and the window fits the screen it opens on". |
| Readiness sentence for a missing speech model, `b05581be` | **Holds**, and I verified the sentence itself in the running app's boot log, not only in source. |
| D1–D8 are on branches and not on main | **Holds as to the branches; does NOT hold as to their absence from the screen.** All of them still reproduce on `aa0165cc` — see B2. |

One record note, not a defect: **§45 addendum 2 is filed physically inside §47** in
`ceo-decisions.md` (line 2545, under "47. The merged Codex worktrees are deleted"). A reader
scrolling to §45 will not find it.

---

## Verification mode

- **Environment:** this Mac, macOS 24.6.0 (arm64). Three displays attached — BenQ GC2870
  1920x1080, HP E243 1080x1920 **portrait**, VA2246 1920x1080, all scale 1. The window opened
  on a 1920x1005 pt work area. **On screen, driven through the window**, with
  `RICHOS_ACTIVATION=regular` per §45.
- **Artifact:** a development bundle built here, `1.2.0-dev.aa0165cc`, ad-hoc signed.
  Identity confirmed from `Info.plist` and from the shipped binary before anything was opened.
- **Window count:** one, at 1400x881 pt. Never two. No two-user test — it is a desktop app.
- **Driving:** **every click went through the accessibility tree by control name**
  (`click button "Download my speech model"`), never by screen coordinate. The one control
  with no name — the talk toggle, which is D8 — was reached by its structural path. This is
  the fix the previous walk arrived at after a coordinate click landed in his Chrome; nothing
  in this walk touched another application.
- **Screenshots:** `screencapture -x` (silent), **window region only, never full screen**,
  through a helper that refuses to save unless `richos-tauri` is frontmost immediately before
  *and* after the shot. It refused twice and deleted the frame both times. No frame of his own
  work is committed.
- **Data isolation:** a fresh scratch `HOME`. `CLAUDE_CONFIG_DIR=/Users/alex/.claude` and
  `RICHOS_CLAUDE_BIN=/Users/alex/.local/bin/claude` per the brief. `PATH` kept Finder-minimal.
- **Sound: allowed and unconstrained.** The authorization is the CEO ruling quoted at the top
  of this audit and nothing else — `ceo-decisions.md:2545`, *"QA may use this Mac's audio
  freely"*; no command run here establishes it. What the machine reports is separate: output
  device **Mac mini Speakers**, volume 60, unmuted, so anything spoken would have been audible
  in the room. **Nothing was spoken, because no turn ever produced an answer (B1).**
- **Microphone: never opened.** Input was injected from a WAV
  (`RICHOS_VOICE_INPUT_WAV`) and the app said so in its own words.
- **Model turns spent: 0.** The ceiling of 8 is the brief's; the count of 0 is read from the
  app's `conversation-ledger.jsonl`, which records both prompts as `TurnInterrupted` with
  `reason: "cognition io: RichOS runtime setup is incomplete…"` — a local refusal before any
  request was made, so nothing reached his subscription. That the refusal is local is read
  from `crates/richos-core/src/runtime.rs:53`, not inferred from the ledger.
- **Contrast:** 118 nodes, 72 dark and 46 light, method and limits declared below.

**Verification basis is stated per claim**, in three kinds that are never blurred: *ran it on
screen against this bundle* · *read from the built artifact, the app's own log or its ledger* ·
*read from source at `aa0165cc` (a hypothesis, not a verification)*.

---

## The walk, item by item

### 0. Identity — is this the artifact, and does it say what it is?

**Basis: read from the built artifact.**

```
$ bash richos/app/scripts/package-app.sh
…
  development build — stamping the version 1.2.0-dev.aa0165cc so it can never be
  mistaken for a release. Pass --release or --nightly <version> to ship this as one.
…
verifying the artefact that was produced (not the builder's exit code)...

  Gatekeeper assessment (spctl): rejected

  version         : 1.2.0-dev.aa0165cc   (app/src-tauri/Cargo.toml, the only copy)
                    development build — not a release.

OK: RichOS.app is bundled, ad-hoc signed and verified — real icons,
cdhash 5c00804a08c7be231aa8ec16785d2882b90cdb3e, microphone usage string present;
NOT notarized, Gatekeeper rejects it, and its permission grants die on the next build
that changes a shipped byte.

$ /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" …/Info.plist
1.2.0-dev.aa0165cc
$ strings -a …/MacOS/richos-tauri | grep -c "1.2.0-dev.aa0165cc"
1
```

**PASS.** The stamp is in the plist and in the binary, the tree was clean so there is no
`.dirty` suffix, and the line a person reads says "development build — not a release" in
words rather than in a version convention only a builder knows.

### 1. Escape closes every popup — TEN surfaces, each opened and each closed

**Basis: ran it on screen. Each surface was opened, confirmed present in the accessibility
tree, Escaped, and confirmed gone, with a positive control proving the tree was readable
throughout (86 elements after the first dismissal, not zero).**

| Surface | How it was opened | After Escape |
|---|---|---|
| Home screen preferences (`#home-prefs`) | gear on the home screen | gone |
| Company picker (`#entity-picker`) | first run, and again from "Choose the company" | gone |
| Search overlay | ⌘K | gone (6 matching nodes → 1, the sidebar item) |
| Corrections overlay | sidebar "Corrections" | gone |
| Feedback overlay | sidebar "Feedback" | gone |
| Settings menu (`#set-menu`) | gear in the app | gone |
| Assertiveness popover | ⚙ at the foot of the rail | gone |
| Engine setup sheet (`#setup-sheet`) | second launch | gone, and by doing what **Close** does |
| Corpus sheet (`#memory-setup`) | revealed underneath the setup sheet | gone, and by doing what **Not now** does |
| Thread actions menu (`#thread-menu`) | "Actions for Running" | gone |

This is the fix working exactly as its own comment says it should: the two `control:` surfaces
did not close *themselves*, they pressed the control the person would have pressed, and the
seven that carry `data-dismiss="escape"` closed outright.

**What I could NOT test, said plainly:** *"the setup sheet mid-install must NOT close"*. On
this build there is no engine to install (B1), so no install can be in flight and the state
cannot be reached. The refusal path is asserted by `setup.js` case 14 in source and is
**unverified on screen here**. It needs a build with an engine pin.

Also untested for the same reason or lack of a trigger: the permission sheet, the repositories
sheet, the inspector and the slideover.

### 2. The version on screen is the running build's — `21-settings-light.png`, `22-update-check.png`

**Basis: ran it on screen, in both themes.**

> RichOS **1.2.0-dev.aa0165cc** is up to date.
> Checked just now.  [Check for updates]

The string on screen is character-for-character the bundle's stamp. I pressed **Check for
updates** and it went out and came back ("Checked 20 minutes ago." → "Checked just now.").

**And "up to date" is honest**, which I checked rather than assumed:

```
$ curl -sS -L https://github.com/WebDevBooster/richos/releases/latest/download/latest.json
{ "version": "1.0.2", … }
```

`1.2.0-dev.aa0165cc` is genuinely ahead of the published latest, so there is nothing to offer.
**PASS.** (The separate claim that a `-dev.` version sorts *older* than the `1.2.0` it
precedes is `480b928c`'s, and this endpoint does not exercise it — **source-level only**.)

### 3. The home screen's temporary line — `strip-templine.png`

**Basis: ran it on screen; fourteen frames two seconds apart, the same rectangle stacked into
one strip so the fade is read rather than inferred.**

The line appears on its **own rounded dark plate** over the artwork —

> *Cadence learned from a document · Customers → 8 new memories*

— and when it goes, **the picture comes back completely**. In the strip, the frames between
lines show the nebula and the `TALENT 579` label underneath it at full strength: no residual
scrim, no dimmed rectangle, no ghost of the plate. **PASS on both halves of the claim.**

Contrast on the plate, dark (the only lighting the home screen has — `home.css:27` declares
"its palette is the ruled dark five, always", which is also why the home screen stays dark
after the app is switched to the light theme; **that is declared behavior and I am not filing
it**):

| Node | Ratio |
|---|---|
| white italic body on the plate | 7.32:1 |
| gold category word ("Customers") | 5.96:1 |
| "8 new memories" | 6.69:1 |

### 4. The window opens inside this display — `boot1.log`, `boot2.log`

**Basis: ran it on screen, plus a read-only dry run over all three of his panels.**

```
[richos] window: derived 1400x880 pt at (260,102), min 1024x700 — Monitor #30942
         work area 1920x1005 pt at (0,25), scale 1 — the preferred size fits, so it caps
         the window
```

Right edge 1660 of 1920, bottom 983 of 1030. Fully inside. On the second launch:

```
[richos] window: restored 1400x881 pt at (260,102), min 1024x700 — where it was left,
         still inside Monitor #30942 …
```

so a saved rectangle is re-validated against a display that is present now, not trusted.

`cargo run --release --example window_placement` (opens nothing) says the same for **all
three** of his displays, including the portrait one:

```
BenQ GC2870   1920x1080 → 1400x880 at (260,126)   fully on screen
HP E243       1080x1920 → 1032x880 at (24,546)    fully on screen   (the display decided)
VA2246        1920x1080 → 1400x880 at (260,126)   fully on screen
saved 1032x880 at (5320,600) from an unplugged display → discarded, derived afresh
floor on every panel: 1024x700 pt
```

**PASS.** The **blind path** itself — the 1024x700 last resort when no monitor can be read at
all — is unreachable while a window server exists, so it is **verified in the decision
function and not on screen**; that is the honest limit of what a live walk can say about it.

### 5. The two sign-in strings

**Basis: read from source at `aa0165cc`. NOT verified on screen.**

```
crates/richos-core/src/provider_auth.rs:21
  AuthState::Cancelled => "Sign-in was canceled. You can try again when you are ready.",
ui/main.js:4147
  … {state: "connecting", message: "Sign-in could not be canceled. Try again."}
```

Both are American. A sweep for the British spelling across `ui/` and `src-tauri/src/` returns
only a Rust enum identifier, its serde wire value, and the test that plants the wrong spelling
on purpose — no prose.

**I did not drive the sign-in path**, because reaching those strings means starting an OAuth
flow against his real Anthropic account in his browser. So this is a source reading, and it is
labeled as one.

### 6. The speech model — offer, download, and the hash

**Basis: ran it on screen + hashed the file myself.**

Pressing the talk control on a model-missing machine gave exactly the offer the fix promises
(`15-talk-pressed.png`):

> I can hear you once I download my speech model. It's 487.6 MB, and it's a one-time
> download.  [Download my speech model]

and on completion (`16-download-progress.png`):

> My ears are installed. Start listening whenever you're ready.  [Start listening]

The app's own account, and then mine:

```
[richos] voice model: ggml-small.en.bin — no partial file
[richos] voice model: ggml-small.en.bin installed and verified against its pinned sha256
         (487614201 bytes, resumed from 0)
[richos] voice: ready on this machine (ready) — whisper.cpp 1.9.1 … model:small.en@c6138d6d58ec

$ shasum -a 256 …/home1/.config/richos/models/ggml-small.en.bin
c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d
$ grep -rn "c6138d6d58ecc8…" --include=*.rs .
crates/richos-voice/src/toolchain.rs:674   (the pin)
```

**PASS**, and the bytes are right rather than merely reported right.

**One thing I did not capture and should have:** the progress ladder. My sampler read the
wrong level of the accessibility tree and returned empty for fifty seconds while the download
ran to completion behind it. The previous audit sampled that ladder successfully and found it
monotonic and honest; **this walk did not re-verify it**, and I am not going to claim it from
a log line.

### 7. The readiness sentence for a missing model — VERIFIED IN THE RUNNING APP

**Basis: the running app's boot log, not source.**

```
[richos] voice: not ready on this machine (model-missing) — My speech model isn't on this
         machine yet. I can fetch it myself now, so I'll offer to download it the next
         time you turn voice on. I can still read what you type.
```

The previous audit's open item was that this still said *"whoever set RichOS up adds those"*
for a gap RichOS can close by itself. **It no longer does. PASS.**

### 8. A text turn, a voice turn, and B1

**Basis: ran it on screen + the app's own ledger + source.**

I typed `What is 17 times 3? Answer in one short sentence.` and pressed Enter. On screen
(`18-text-sent.png`):

> **Stopped**
> I hit a snag mid-thought and had to stop — say the word and I'll pick it back up.
> Everything I'd already written above is saved.
> [Pick it back up]

In `conversation-ledger.jsonl` at the same instant:

```
{"event":"TurnInterrupted","turn_id":"turn_0cc5570d…",
 "reason":"cognition io: RichOS runtime setup is incomplete: the selected engine has no
           delivered runtimes"}
```

The voice turn, from an injected WAV, failed identically. **This is B1, and it is a fact about
how the bundle was built rather than about the product:**

```
[richos] engine directory: …/richos/engine (via repo layout above the executable)
[richos] first-run setup: this build carries NO engine pin, so it cannot install one.
         Build with RICHOS_ENGINE_VERSION / RICHOS_ENGINE_URL / RICHOS_ENGINE_SHA256 set.

$ ls -d …/richos/engine/runtime                     → absent
$ ls -d /Users/alex/.claude/richos-engine/runtime   → absent
```

`crates/richos-core/src/runtime.rs:53` resolves `<engine>/runtime` with **no override in the
production path** (the `explicit` argument is used only by examples), and
`scripts/make-engine-asset.sh` says *"Since 1.2.0 a separately built runtime also ships"* — it
is produced and pinned by the release path, which `make-release.sh` drives. So a **nightly**
would carry one and this development build cannot.

**What that costs, stated rather than buried: a development-build walk can verify every screen
in this audit and cannot verify that Rich answers at all.** That is the half of the product the
CEO actually uses. It needs a decision before the second walk.

**The app's own first-run sheet says all of this to the person, and says it well**
(`24-relaunch-thread.png`):

> This copy of RichOS wasn't built with an engine to install, so I can't fetch one. It needs
> whoever set RichOS up to publish one and pin it.

That is an honest, plain, correctly-aimed sentence, and it is worth saying so.

### 9. Quit and relaunch — `24-relaunch-thread.png`

**Basis: ran it on screen.**

- Clean ⌘Q, and the app recorded it as clean: `[richos] launch: fresh (start 2, 1 window(s))`.
- **Both turns were still there**, in order, with their full content, and the scroll position
  held.
- **The light theme persisted** into the thread view.
- The company registry persisted (`1 compan(ies)`), the voice model persisted and came back
  `ready` with no re-download, and the window geometry was restored and re-validated.

**PASS, cleanly.**

---

## The defects, in order of how much they cost him

### N1 — a white scrollbar is jammed into the message box (High) — `strip-composer-3x.png`

**Basis: ran it on screen; five frames, and a negative control.**

Once a thread exists and the composer has focus, a **native macOS scrollbar with a white
track** appears at the right end of the input box, straight through its rounded corner and its
gold focus ring. The box is **empty**. There is nothing to scroll.

The strip is the proof: the first three frames (before the company was added) show a clean
rounded box; the last two show the white block. It is stable across frames captured seconds
apart, and it is present in **both** themes — in the dark theme it is a bright white rectangle
in the middle of the most-used control in the product.

This is the kind of thing a person sees before they read anything.

### N2 — two buttons are raw macOS, in a hand-finished panel (High) — `zoom-settings-inapp.png`

**Basis: ran it on screen + sampled pixels.**

**Connected repositories** and **Account connection** render as plain, unstyled native
buttons. Sampled from the frame, their fill is **`#FEFEFE`** — pure white — on a `#182440`
panel, with black text. They also break the panel's label/control grid: every other row is
"label left, control right", and these two sit flush against the left edge, full width,
stacked.

The dark home-screen panel renders the same two controls slate gray (`#525B70`), so **the same
two buttons have two different wrong appearances** depending on which screen you opened the
panel from.

Contrast is not the problem and I measured it rather than assuming: 5.45:1 for the gray form,
17.00:1 for the white one, 14.81:1 in the light theme. All pass. **The problem is that they
are visibly not part of the product.**

### N3 — the technical-view badge is cut off and sits under the gear (Medium) — `zoom-techy-badge.png`

**Basis: ran it on screen.**

⌘⇧T turns on the technical view and puts a badge in the top right that reads:

> ● Technical view · this conversat

No ellipsis — the settings gear is simply painted on top of the last characters. The badge's
whole job is to tell him the technical view is on *for this conversation only*, and the part
that says "only for this one" is the part that is covered.

### N4 — one Enter, two turns (Medium, and it costs money)

**Basis: the app's own ledger, on both the text turn and the voice turn.**

```
PromptReceived   turn_7ba34774…  "What is 17 times 3? …"     at …297651
TurnStarted      turn_7ba34774…                              at …297658
TurnInterrupted  turn_7ba34774…  "cognition io: …"           at …297664
ActionRecorded   act_fa1397b0…   crash_recovery
                                 "replay interrupted turn turn_7ba34774…"
PromptReceived   turn_0cc5570d…  "What is 17 times 3? …"     at …297673   <- same text
TurnSuperseded   turn_7ba34774…  by turn_0cc5570d…
TurnInterrupted  turn_0cc5570d…  "cognition io: …"           at …297680
ActionUpdated    act_fa1397b0…   failed
```

**One keystroke, two prompts, 22 ms apart.** The same pattern repeated on the spoken turn
(`turn_f8214909…` → `turn_6ae9e5fd…`).

Here both attempts were refused locally, so nothing was charged. **On a build that reaches the
model, this is two requests for one question**, and against a permanent condition — an expired
subscription, say — the retry cannot ever succeed and he pays for it anyway. An immediate
automatic replay is the right instinct for a crash and the wrong one for a refusal the app has
already read.

### N5 — the "Enter" hint stops being true after any popup (Low)

**Basis: ran it on screen.**

On the home screen, opening the gear panel and pressing Escape closes it and returns focus to
the gear — which is correct, and is what the fix's own comment promises. But the home screen
carries a standing hint under the main button:

> [ ● Talk to Rich ]
>       Enter

After that Escape, pressing Enter **re-opens the settings panel**. Reproduced. Both behaviors
are individually right and together they make the one hint on the screen wrong.

### N6 — one gear, two panels (Low)

**Basis: ran it on screen.** The gear in the top-right corner of the **home screen** opens a
panel with Text size / Techy Mode / Opening screen / Company / Home screen / Updates. The gear
in the top-right corner of the **app**, in the same place, opens the same panel **plus a Theme
row**. Same icon, same position, different contents.

### N7 — an operator line names three causes, none of which can apply (Low, operator-facing)

**Basis: ran it + `crates/richos-voice/src/controller.rs:1159`.**

```
[richos-voice] input silent: nothing above -80.00 dBFS for 3.008 s on an OPEN stream
               - muted mic, gain at zero, or a denied permission
```

This was printed while the input was an injected WAV that had been fully consumed. There was
no microphone, no gain and no permission involved. The line is emitted from the capture layer
without reference to the source.

**And the user-facing half of the same event is NOT a defect, which I want on the record
because it looks like one.** The band said *"I can't hear anything. Check your mic isn't muted,
then try again."* immediately after correctly transcribing my sentence — which reads as the app
contradicting itself. It is not: the injection is one-shot, the next listen genuinely received
silence, and the message is right for that state. My harness caused it. What a person would
still notice is that the button is labeled **"try again"** in lower case where every other
button in the product is sentence case, and it wraps onto two lines in its box.

---

## The previous audit's D1–D8, re-checked on this build (B2)

| # | Status on `aa0165cc` | Evidence |
|---|---|---|
| **D1** — setup completes, next launch asks again | **Reproduces in altered form.** The empty-candidate line is still there — `first-run setup: the RichOS engine is NOT installed — looked in:` with **nothing after the colon** — and the setup sheet re-appeared on the second launch. This build adds an honest second line naming the real reason (no engine pin), which the nightly will not have. | `boot1.log`, `boot2.log`, `24-relaunch-thread.png` |
| **D2** — a failed turn hides the cause | **Reproduces in form, with a different cause.** Same "I hit a snag mid-thought", same untrue "Everything I'd already written above is saved" with nothing above it, same retry that cannot work; the ledger again holds the exact, actionable reason and the screen again shows something else. | `18-text-sent.png` + ledger |
| **D3** — model refused, voice vanishes | **Not tested.** I did not repeat the corrupted-model negative control on this build. | — |
| **D4** — a failed text turn logs nothing | **Reproduces exactly.** The boot log's last line before and after the failed text turn is the same voice-ready line; the failed **voice** turn did log `[richos] voice turn failed: …`. | `boot1.log`, `boot2.log` |
| **D5** — first run stacks sheets | **Reproduces.** Escaping the engine setup sheet revealed the corpus sheet directly underneath it, and on first run the company question arrives with no "Not now" of its own. | `24-…`, `25-after-setup-escape.png` |
| **D6** — "Pick it back up" hands the work back | **Reproduces exactly.** Pressing it put my text back in the composer; no new turn, no log line. | `19-pick-it-back-up.png` |
| **D7** — unstyled controls, truncated label, mid-word wrap | **Reproduces, all three.** "Company but…" / "Company butt…" still truncated; the Company dropdown still a raw macOS select in both themes; the update-server URL still breaks as `…/releases/la` `test/…`, and the corpus sheet breaks his own path as `…/RichOS/co` `rpus`. N2 and N3 are two more members of the same family. | `zoom-settings-inapp.png`, `zoom-settings-light.png`, `25-after-setup-escape.png` |
| **D8** — the talk control has no accessible name | **Reproduces exactly.** Read directly: `get {name, value, role description} of checkbox 1 …` → `missing value, 0, toggle button`. The value does flip 0 → 1 correctly, so the **state** reads right and the **subject** does not — VoiceOver announces "toggle button, on" with no idea what was turned on. `pop up button ⚙` and `button ▷` are still named by their glyph only. | accessibility tree |

**Improved since that audit and worth recording:** the sidebar controls that were bare are now
named — `Collapse Acme Coaching`, `Acme Coaching overview`, `New thread in Acme Coaching`,
`Actions for Running` — and the home screen's gear now exposes the name `Settings` rather than
a glyph.

---

## What passed, loudly

At the same volume as the defects, because it is the larger half of the walk.

- **Escape on ten popups**, including the three the old list never had, and correctly doing
  *nothing but press the right control* on the two that must not vanish.
- **The version a person reads is the version that is running**, and the build refuses to let
  a plain run wear a bare release number.
- **The temporary line gives the picture back** — no residue of any kind, read across fourteen
  frames.
- **The window fits, on the display it opened on and on all three of his panels**, and a saved
  rectangle from a vanished display is thrown away rather than honored.
- **The model download verifies its own bytes against a pin** I re-hashed myself.
- **The readiness sentence now tells the truth** about what RichOS can do for itself.
- **Thread, theme, company, model and window geometry all survive a quit**, and a clean quit is
  recorded as clean.
- **The updater is honest** on a development build: it went out, came back, and "up to date"
  is true against the published manifest.
- **The microphone was never opened**, and the app said so itself rather than leaving it to be
  inferred.
- **Contrast: 118 of 118 nodes pass, in both themes.**

### The contrast measurements

**Method, declared because it decides what the numbers mean.** Each node is sampled from the
committed frame. Background is the modal color of the rectangle, quantized to 8 levels per
channel so a gradient surface still resolves to one background. Foreground is **the color
furthest from that background in luminance that occurs at least three times** — the ink, not an
average and not an extremum. Ratios are sRGB relative luminance, WCAG 2.1.

**Both halves of that rule were learned the hard way in this session and both are recorded
because the numbers move by more than a verdict's worth.** An extreme-decile *mean*
UNDERSTATED two nodes as 4.24:1 and 3.81:1 whose ink is really `#E5E6E9` and `#9DA3B0`
(5.45:1 and 5.14:1) — antialiasing drags an average toward the background. A *most-common*
value among the far pixels understated the hairline ⌘K key cap as 3.78:1 when its ink,
`#5E6167`, is the same token as "Set your name" beside it at 4.94:1 — an 11px glyph has an ink
plateau about seven pixels wide, and a hairline has none. **Every node that moved was re-read
by hand at the pixel level before it was published.** A sampling rule is an aid; it is never
the verdict.

**One exemption, declared rather than taken quietly:** chrome **behind an open modal sheet** is
deliberately dimmed by the app and is not measured. The control is that the same chrome
measures 6.40–6.56:1 dark and 5.78:1 light in the clean state, so the dimming is
de-emphasis of what is not the focus rather than a failing color.

Lowest true values: **5.14:1 dark**, **4.66:1 light**. The floor is 4.5:1.

| Node | Dark | Light |
|---|---|---|
| Home temporary line — body / category / count | 7.32 / 5.96 / 6.69 | (home screen is dark-only, declared) |
| Settings — row labels, headings, version line | 12.06:1 | 18.07:1 |
| Settings — "100%" in its pill | 5.14:1 | 5.89:1 |
| Settings — Company select value | 13.05:1 | 13.67:1 |
| Settings — "Company but…" / "Check for updates" | 14.78:1 | 15.58:1 |
| Settings — the two native pills | 5.45 (slate) / 17.00 (white) | 14.81:1 |
| Settings — "Checked N minutes ago." | 5.78:1 | 6.28:1 |
| Settings — update server URL | 5.51:1 | 5.32:1 |
| Assertiveness popover — labels, radios, hints (16 nodes) | 5.51–5.78:1 | — |
| Company sheet — title, body, field label, typed value | 5.78–12.06:1 | — |
| Company sheet — "Add this company" (dark on gold) | 7.59:1 | — |
| Sidebar — Search / New thread / Corrections / Feedback | 6.56:1 | 5.78:1 |
| Sidebar — ⌘K key cap | 6.18:1 | **4.94:1** |
| Sidebar — "Set your name", thread count | 6.18:1 | 4.94–4.99:1 |
| Sidebar — selected thread "Running" | 12.35:1 | 13.19:1 |
| Breadcrumb | 6.48:1 | 5.78:1 |
| Interview offer — title / body | 13.02:1 | 16.87:1 |
| Interview offer — "Not now means…" | 6.09:1 | 6.10:1 |
| Interview offer — "Start the questions" (dark on gold) | 7.59:1 | **4.66:1** |
| User bubble text | 5.73:1 | 5.50:1 |
| "Stopped" (red) | 7.04:1 | 6.63:1 |
| Stopped card — body / "…is saved." / button | 12.06 / 5.51 / 12.06 | 18.07 / 5.32 / 18.07 |
| Voice offer sentence / download button / footnote | 14.55 / 6.16 / 14.01 | — |
| Voice band message / "try again" / "listening…" | — | 14.76 / **4.94** / 5.78 |
| Setup sheet — title / bold lead / body / red refusal / Close | — | 6.28 / 18.07 / 6.28 / 8.12 / 6.28 |
| Technical view — badge, headings, body | — | 5.78–6.28:1 |

**Two margins worth a designer's eye even though they pass:** "Start the questions" at
**4.66:1** in light, and the sidebar's whole secondary token at **4.94:1** in light. Both clear
the floor by less than a rounding error, and both are text a person is expected to read.

---

## His data was not touched by this walk

```
$ find "/Users/alex/Library/Application Support/com.richos.app" -newermt "2026-09-17 10:55"
(empty)
$ find "/Users/alex/.config/richos" -newermt "2026-09-17 10:55"
(empty)

# POSITIVE CONTROLS — the same finds with an old cutoff, proving they can see those paths:
…/com.richos.app -newermt 2020-01-01 | wc -l   → 23
…/.config/richos -newermt 2020-01-01 | wc -l   →  3
```

`/Applications/RichOS.app` does not exist on this machine and was never created.
`~/.richos-signing` was never touched and no signing or notarization variable was set.
`nightly-local.py` and `make-release.sh` were never run. Nothing under `.github/` was touched.
Output volume was read before and after every step and never changed (`60, muted:false`).

```
$ pgrep -fl 'RichOS.app|richos-tauri'      # before the walk, and after it
(no output, both times)
```

**One honest exception, and it is not mine.** `find /Users/alex/RichOS -newermt "2026-09-17
10:55"` is **not** empty — `corpus/state/writer-lock.sqlite` and a set of
`corpus/ceo/unfiled/ws-google-calendar-*-richos-seed-*.md` files were written at 11:10. Those
are the calendar-seed work of another teammate running concurrently, not this walk: my scratch
`HOME` has no `RichOS/` directory at all (I declined the corpus offer), the app's own boot log
says `loro Tier C: no corpus configured`, and the corpus sheet it showed me named
`…/scratchpad/devwalk/home1/RichOS/corpus`, which was never created.

---

## Scratch left in place

`…/scratchpad/devwalk/` — `home1/` the walk's HOME, `logs/` the build log and two boot logs,
`shots/` every frame, `probe.wav` the injected voice input, and the helpers
(`shot.sh` with its frontmost guard, `click.sh` by accessible name, `contrast.py`, `band.py`,
`strip.py`). Anyone repeating this walk should start from `shot.sh` and `click.sh`.
