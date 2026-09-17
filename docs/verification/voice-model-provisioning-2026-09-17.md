# The installed app provisions its own speech model — 2026-09-17

Branch `cc/echo-opus-voicemodel1`, off `b83e16a47b0f1c79a5686740254bc396566bb657`.

`.github/README.md` line 35 said, of the first public release:

> **Voice does not work yet.** Typing does. Speech needs a model this build does not download for you.

This records what was built, what was run, and what each run actually showed — separated into
source checks, a real network transfer, and the installed bundle, because those establish
different things and a reader deserves to know which is which.

---

## The CEO constraint this work was done under, and what it cost the proof

**No audible sound from anything this work runs, overnight, on this Mac.** Stated 2026-09-17 while
the work was in flight.

Kept as follows, and each is a property of what ran rather than an intention:

- `RICHOS_VOICE_LIVE_AUDIO` was never set. It is the opt-in that turns the four device-opening
  tests from `ignored` into `ok` (`crates/richos-voice/build.rs`), and every run below reports
  `4 ignored`.
- `say` was invoked only ever as `say -o <file> --data-format=LEI16@16000`, the form
  `stt.rs::synthesize_probe` already uses, which writes a file and plays nothing. Its own comment
  states that is the only reason calibrating at voice-mode start is acceptable at all.
- **Talk to Rich was never driven into speaking.** No TTS playback through `playout.rs` happened at
  any point, so the proof below stops at *"the model verifies and the recognizer is resolved and
  ready"* and does not extend to *"Rich answered out loud"*. That last step is the only part of the
  brief's installed proof not performed, it was skipped deliberately, and it is named here rather
  than glossed.
- The microphone was never opened either. That is not a concession — it is the invariant under
  test. Both installed boots below report zero mentions of `listening`, `capture`, `cpal` or
  `microphone`, and `ui/tests/voice-model.js` asserts `start_voice_capture` is never invoked on the
  way to the offer.

**What this means for README line 35: the sentence is now false and it was NOT changed here.**

The brief asked for it to be rewritten if the proof passed. The proof passed and the line was left
exactly as it is, because `.github/README.md` is the GitHub home page and the CEO writes it
himself — a standing ruling of his from 2026-09-04, given after an agent was dispatched to extend
that same file: *"no, that's not Will's job. That's my job."* Its scope is the home page and only
the home page; the forty other READMEs in this tree are ordinary files. A brief cannot authorize
crossing it, so the change is his to make or refuse, and it is raised to him rather than made
quietly. See the escalation at the foot of this file.

**What is actually false about it**, so the decision can be made without re-deriving anything:

> **Voice does not work yet.** Typing does. Speech needs a model this build does not download for you.

- *"this build does not download for you"* — it does now, from inside the app, with no terminal
  and no Homebrew. Section 3 below is the installed binary doing it.
- *"Voice does not work yet"* — still true on a Mac with no `whisper-cli`, which is most Macs, and
  still true in the narrower sense that nothing on this branch drove a spoken exchange. Two
  different reasons, and only one of them stopped applying.

A wording that is true of what was proven, offered for him to take, edit or discard:

> **Voice needs one more piece, and RichOS fetches it itself.** Typing works out of the box. The
> first time you ask to talk, RichOS offers to download the speech model it needs, tells you how
> big it is, and checks what arrives against a hash it was built with. On a Mac that does not have
> the speech engine installed at all, it says so plainly instead of pretending.

Also recorded, per the same day's notice about `df78e57f`: **no step of this proof sees a signing
credential.** The bundle is built by `app/scripts/package-app.sh` in its default `adhoc` mode, never
`--sign developer-id`, and `RICHOS_NOTARIZE` is never set, so no `RICHOS_NOTARY_*`,
`TAURI_SIGNING_*`, `APPLE_*` or `RICHOS_SIGNING_IDENTITY` variable is read. `nightly-local.py` was
not run at all — it publishes. One consequence accepted: an ad-hoc bundle embeds no designated
requirement, so macOS would bind a microphone grant to its raw code hash. Irrelevant here, because
no microphone grant was ever requested.

---

## What was built

| Where | What |
|---|---|
| `app/crates/richos-voice/src/provision.rs` | Every RULE: the pin table, body sniffing, classification, the two vocabularies, disk preflight, resume planning, the part-file state machine, the event contract. Pure or local-filesystem only. No sockets, no async runtime, no new dependency. |
| `app/crates/richos-voice/src/stt.rs` | `SpeechReadiness` — which gap this machine has, as a kind rather than a string — and `model_search_dirs`, which adds `~/.config/richos/models`, the one directory RichOS itself writes to. |
| `app/src-tauri/src/voice_provision.rs` | The TRANSPORT, which decides nothing, plus `provision_speech_model` and `cancel_speech_model_download`. |
| `app/ui/` | Four rows in the existing voice panel: offer, transfer, refusal, finish. No new screen. |

The split is deliberately the one `engine/voice/provisioning/{model-integrity,model-fetch}.js`
already uses, and for the same reason: the failure paths have to be testable without a network.

---

## 1. Source checks — what they establish, and what they cannot

```
cargo test --workspace          (app/)   55 suites, 0 failed, 4 ignored
node ui/tests/run.js                     36 suites, 588 checks, 0 failed
```

The four `ignored` are the device-opening tests: `RICHOS_VOICE_LIVE_AUDIO` is unset, which is the
sound constraint above holding rather than a gap. `cargo test -p richos-voice` alone is 257.

**THE FIRST TIME I REPORTED THIS I REPORTED IT WRONG**, and it is recorded rather than tidied
away. An earlier full UI run reported exit 0 and I wrote "36 suites all green" into two commit
messages on the strength of it. Re-running it at HEAD found four real failures, all in
`docs-claims.js` and all mine:

  - `app/README.md` named no `tests/model_provisioning.rs`
  - `app/README.md` said `richos-voice` has 229 tests; the tree had 257
  - `app/ui/tests/README.md`'s table did not describe `voice-model.js`
  - `app/STREAMING.md` did not document `rich://voice-model`

All four are fixed. The lesson is the one this repository already keeps about deploys: an exit
code is a claim about a command, and the artifact is the evidence. I had also broken one of those
runs myself by deleting the harness's `node_modules` while it was still going, which produced 26
suites reporting "NO evidence" — a failure mode that looks nothing like a green run and everything
like a catastrophe, and was neither.

Within those:

- **`crates/richos-voice/tests/model_provisioning.rs` — 23 tests, no socket opened by any of them.**
  Captive portal; a portal padded to the exact pinned length; right-size/right-magic/wrong-content;
  an interrupted transfer; a resume that still verifies; a partial that is not a model prefix; a
  full disk; a declared length that disagrees; an unpinned model; an installed-but-corrupt copy; an
  empty body; an oversize body. Every refusal is paired with a positive control over correct bytes
  through the same driver.
- **`ui/tests/voice-model.js` — 10 checks** over the four rows, driven by the real
  `rich://voice-model` payload shape.
- **`ui/tests/affordances.js` — 94 checks.** It classifies all 29 new user-visible strings and
  holds every ACTIONABLE one to naming a control that is present, visible and enabled in the same
  view. Three new fixtures drive the offer, refusal and finish rows for exactly that.
- **`ui/tests/docs-claims.js`** joins this branch's code to `app/README.md`,
  `app/STREAMING.md` and `app/ui/tests/README.md`, and refused it until all three described what
  had been added.
- **`ui/tests/contrast.js`** walks three new surfaces (`voice-model-offer`, `-progress`, `-failed`)
  in both themes: 98 of 460 / 462 / 464 nodes measured, 0 new failures, 0 worsened.

**A five-mutation audit over the new rules**, each removing exactly one guarantee, to establish the
tests can fail:

| mutation | caught by |
|---|---|
| the sha256 comparison removed | 3 tests |
| content sniffing skipped | 4 tests |
| the disk preflight always passes | 2 tests |
| a failed part file renamed into place anyway | 3 tests |
| a non-model partial resumed onto rather than restarted | 2 tests |

None survived. The source was restored afterwards and `git diff` carries no trace.

**What a source pass does NOT establish** — `engine/voice/README.md` says it in as many words: it
does not show that a released app has its speech dependencies. That is what sections 2 and 3 are
for.

---

## 2. The real transfer

The shipped fetch loop, the shipped `reqwest` client, the real bytes, on a machine made to look
fresh. `app/src-tauri/examples/provision_model.rs` compiles `src/voice_provision.rs` by path — the
same file `main.rs` compiles — and substitutes only the observer.

**Isolation is `HOME`**, because `HOME` is what `resolve_model` derives its four search directories
from. A first attempt set only `RICHOS_MODEL_DIR` and correctly downloaded nothing: this Mac
already carries `~/.config/open-wispr/models/ggml-small.en.bin`, so readiness answered `ready` and
the fetch returned `already-present` without opening a socket. That is the product behaving
correctly and it is not the state under test.

```
HOME=<scratch>  RICHOS_MODEL_DIR=<scratch>/.config/richos/models
PATH=/usr/bin:/bin:/usr/sbin:/sbin

readiness      model-missing (ModelMissing(small.en: … not found in <four directories>))
provisionable  true
offer          { "modelId": "small.en", "bytes": 487614201, "sizeLabel": "487.6 MB",
                 "needFreeBytes": 536375622, "freeBytes": 9597739008,
                 "enoughRoom": true, "alreadyHave": 0, "singleWitness": false }

[   0.01s] rich://voice-model started    0 of 487,614,201
[   3.35s] rich://voice-model progress   10%
…
[  25.26s] rich://voice-model progress   90%
[  27.72s] rich://voice-model verifying  487,614,201 of 487,614,201
[  28.74s] rich://voice-model installed

ok  { "status": "installed", "bytes": 487614201,
      "sha256": "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d" }
```

Checked afterwards by something that did not do the downloading:

```
$ shasum -a 256 <scratch>/.config/richos/models/ggml-small.en.bin
c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d
$ stat -f '%z' …
487614201
```

Both agree with `engine/voice/models/model-pins.json`'s `small.en` row, byte for byte and hash for
hash. `~/Models/Whisper` and `~/.config/open-wispr/models` were untouched, and
`~/.config/richos/models` does not exist on the operator's real HOME.

Then the product's own question, asked again by the same function the microphone path runs:

```
readiness  ready (Ready(small.en))
weights    <scratch>/.config/richos/models/ggml-small.en.bin
binary     /opt/homebrew/bin/whisper-cli
provenance whisper.cpp 1.9.1 bin:7dc20e3106d7 [BLAS/MTL/CPU] model:small.en@c6138d6d58ec
           | model:small.en (hw-resolved top rung, 0.970s/utt <= 1.000s)
```

---

## 3. The installed bundle

`app/scripts/package-app.sh` (default adhoc mode), booted through
`app/scripts/lib/gui-launch.sh` — the library `gui-boot.test.sh` is built on — so the launch is the
measured one: `env -i HOME=… USER=… PATH=/usr/bin:/bin:/usr/sbin:/sbin`, cwd `/`, and the binary
copied into a bundle OUTSIDE the repository so the dogfood checkout cannot answer on its behalf.

**The binary is identified by sha256 before it is booted.** This is not decoration: the first two
attempts at this section reused an existing test machine and therefore booted the PREVIOUS build
for two full runs, reporting "no ready line" about a binary that did not contain one. The machine
is now rebuilt every run and the copied binary's hash is compared with the packaged one first.

```
packaged : c951fd9ede4d1194937e8fc4f50f6e00c79aebdacc5679720c9648973483a02b
to boot  : c951fd9ede4d1194937e8fc4f50f6e00c79aebdacc5679720c9648973483a02b
Identifier=com.richos.app   CDHash=90d2b95e9f1f735408a1efc706d3d896de4b220b
```

**Boot 1 — no speech model in any of the four directories** (2 s after launch):

```
[richos] voice: not ready on this machine (model-missing) — My ears aren't installed on this
         machine yet — whoever set RichOS up adds those. I can still read what you type.
```

`model-missing`, not `toolchain-missing`: the gap is one RichOS can close, so the talk button is
offered and opens on the offer row.

**Boot 2 — the same binary, one file added** (3 s after launch):

```
[richos] voice: ready on this machine (ready) — whisper.cpp 1.9.1 bin:7dc20e3106d7 [BLAS/MTL/CPU]
         model:small.en@c6138d6d58ec | model:small.en (hw-resolved top rung, 0.706s/utt <= 1.000s)
         mem:4851286016B/25769803776B pressure:warn
```

The recognizer resolved the weights RichOS had installed, hashed them against the pin, and reported
an utterance cost inside the 1.000 s ceiling. **The microphone was not opened on either boot:** zero
mentions of `listening`, `capture`, `cpal` or `microphone` in either log.

The ready line is new. Before this branch `voice_readiness` printed only on a refusal, so "voice
works here" was reported by SILENCE — in the one log `gui-boot.test.sh` exists to hold every line of
to account. An absence reads identically to a command never invoked and a window that died before
`init()`.

---

## What this does not show, stated rather than left to be discovered

1. **A spoken exchange.** No TTS playback and no live microphone, by the CEO's constraint. The
   proof ends at a resolved, verified, ready recognizer.
2. **The button pressed in the real window.** The four rows and their controls are proven under
   WebKit by `ui/tests/voice-model.js`, and the real transfer is proven by section 2, but no run
   below clicked `#voice-model-get` inside the shipped bundle. The two halves meet at
   `provision_speech_model`, which both exercise.
3. **A machine with no `whisper-cli`.** RichOS fetches pinned WEIGHTS. The decoder is not pinned and
   cannot be — `model-pins.json` explains that a Homebrew binary's sha256 is a property of an arch
   and a bottle revision — so `toolchain-missing` is still a gap somebody else closes, and it is
   still told to the CEO in those words. **Nothing on this branch changes that**, and it is the
   remaining half of "voice works on a stranger's Mac".
4. **Windows.** Untouched, as ever.

## One finding worth the next person's attention

After provisioning, the resolver reports `hw-resolved top rung`. That is true of the ladder it was
given and misleading about the machine: `retain_installed` filters the ladder to what is INSTALLED,
so with only `small.en` present it is index 0 and therefore `TopRung`, and no notice is emitted. On
this same Mac with the operator's full model set, the identical resolver says
`large-v3-turbo-q5_0 too slow here at 1.384s/utt` — a different and more informative sentence.

So a provisioned machine is never told "a better recognizer exists and was not downloaded". That is
a property of `hardware.rs`'s existing filter rather than of this work, it was not changed here, and
deciding whether a second model should ever be offered is a product question rather than an
engineering one.

---

## Escalation raised

`.github/README.md` line 35 is now false in one of its two claims and this branch did not touch it,
for the reason given at the top. The decision — leave it, take the wording above, or write his own —
is the CEO's, and it is the one thing this work produced that somebody else has to finish.

Raised 2026-09-17 as **esc-20260917T013254Z-b70644da**, for the CEO, state `work-complete` —
the work is done and this is the one thing in it somebody else has to finish. Its own record is
beside this file under `docs/verification/escalations/`.
