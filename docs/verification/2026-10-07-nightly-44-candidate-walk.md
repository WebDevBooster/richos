# Walk of nightly candidate 44 (`v1.2.0-nightly.20261007.44`), 2026-10-07

**Verdict: NOT READY.** One of the brief's passes fails on candidate 44's own signed bundle, in
the test VM. Asked about a video that has captions a person uploaded, Rich used those captions in
only one run of four. In the other three he skipped them and transcribed the audio himself
(D16 below). Everything else the candidate adds passes:

1. **The essentials download at first launch: PASS.** The speech models start arriving with
   nothing pressed. The company name, its folder and the first conversation are all done while
   the download is still running. The tools are then installed and verified, and voice is ready
   with no relaunch.
2. **The video skill: FAIL on its captions half (D16), PASS on its transcribe half.** On a video
   with no uploaded captions, Rich checks for captions, transcribes the audio with the large
   model and summarizes it.
3. **The wording: PASS.**
   - The fast-use line no longer names a pause point the account has already passed (D15 is
     fixed).
   - Every answer the video walks recorded keeps Rich's notices as separate paragraphs. No
     sentence runs into the next one.

Only the brief's three items were walked. Everything else passed on candidate 43
(`docs/verification/2026-10-07-nightly-43-candidate-walk.md`) and was not walked again.

## Identity, checked before any claim: PASS

- **The zip.** `shasum -a 256` of `RichOS-1.2.0-nightly.20261007.44-macos-aarch64.zip` gives
  `f5d94b5f2b533c306f87b610a674d007ce402ac020caf8653d395dc15b51ee37`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- **The engine.** `richos-engine-1.2.0.tar.gz` gives
  `e4a2a731fd7d21112fb46a7a6998e7ef37dde52d2a93873ca74e959647a888bd`, its `SHA256SUMS` line.
- **`candidate.json` `info`:**
  - `source_commit` `f2cbeeaad9f413acdd9f2949d9d7bd678dbfe0b0`;
  - `run_id` `20261007T193741Z-644592ff`;
  - `version` `1.2.0-nightly.20261007.44`;
  - `build_commit` `787e4f0e91337c10b2f3f827b79a74ba4731872c`.
- **The build commit.** Its parent is `f2cbeeaad`. `git diff --stat f2cbeeaad 787e4f0e9`
  touches only four files: `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and
  `tauri.conf.json`.
- **The running app.** Every walk's identity step read "built from `787e4f0e9…`" and passed.
- **The Settings version line.** It reads "RichOS 1.2.0-nightly.20261007.44 is up to date."
  (run I1's accessibility find, `value='RichOS 1.2.0-nightly.20261007.44 is up to date.'`; frame
  `i-version-menu`).

## 1. The essentials download at first launch: PASS

The walk is `setup-walk.py --memory not-now`, run S3 (`walk-6aa050fcab37`), exit 0, every step
PASS. The guest has Claude Code and the engine, and no video tools.

**One timeline, on the guest's clock.** Each moment carries how much of the two models (1,061,655,396
bytes in all) was on disk at that moment:

| Seconds after launch | On disk | Moment |
|---|---|---|
| 4.6 | 0.2% | the walk begins, nothing pressed |
| 5.3 | 1.5% | the models are arriving, nothing pressed |
| 32.8 | 33.8% | memory question: "Not now" pressed |
| 41.2 | 45.3% | the company question is up |
| 50.1 | 53.2% | company name typed |
| 54.7 | 57.7% | folder given |
| 58.6 | 59.1% | "Add this company" pressed |
| 58.9 | 59.3% | the first conversation is created |
| 76.1 | 80.3% | business questions: "Not now" |
| 98.8 | 100% | the app says "My video tools are installed." |
| 102.9 | 100% | yt-dlp and both models verified against their pins |
| 103.9 | 100% | the walk reads the app's "voice: ready on this machine" line |

- **meanwhile.** The download started before anything was pressed. Every first-setup moment came
  while it was still running.
- **arrived.**
  - `tools/yt-dlp` is the launcher RichOS writes. Its version file hashes to its own record,
    `36de87e6…`, and answers `--version` with `2026.09.27.232945`.
  - `ggml-small.en.bin` is `c6138d6d58ec…` and `ggml-large-v3-turbo-q5_0.bin` is
    `394221709cd5…`. Both match their pins.
- **voice, with no relaunch.**
  - The app printed "[richos] voice: ready on this machine (ready) — whisper.cpp 1.9.1
    bin:fe7b744a4b31 model:small.en@c6138d6d58ec …". It prints this line every time the window
    asks voice whether it can hear, so the window asked again when the models arrived.
  - The talk control was pressed once and turned into "Stop talking" (frame `s-voice-pressed`).
    It did not put up the offer to download a model.
  - The microphone was a stand-in: two seconds of silence in a WAV file. No sound was played. "I
    can't hear anything" in the frame is that stand-in running out.
- **relaunch.** The boot says `first-run setup: nothing missing.` No sheet comes up (frame
  `s-relaunch`).

**New in this walk: the voice step.** The walk had no check for "voice ready with no relaunch".
Run S1 recorded only the launch's own "not ready (model-missing)" line. It read the log 24 s
after "My video tools are installed." and never looked again. The voice step (commit `cc328ccd4`) waits
up to 60 s for the ready line, then presses the talk control the way a person does.

**Seen, not judged: the first press took about 95 s to start listening in the guest.** The press
was at 115.4 s and "Stop talking" came at 210.0 s. The app's own lines in between show voice
timing both models before it opened the stand-in:

- `large-v3-turbo-q5_0 too slow here at 24.664s/utt`;
- `this 13.070s/utt` for small.en;
- the same pair again, at 20.211 and 12.197 s.

The guest is a virtual machine that shared the host with a second walk, and the host was at
about 98% CPU. These are guest numbers and say nothing about a real Mac. What the walk does show
is that, now that setup installs the large model, the first press measures it too. Not measured:
whether the second press measures again, and how long the first press takes on a real Mac.

## 2. The video skill: FAIL on the captions half (D16), PASS on the transcribe half

The walk is `video-watch-walk.py`. Its setup step is the background download, and its speech-env
step reads every running provider's `RICHOS_SPEECH_MODEL`. Both passed in all five runs: the
step read `ggml-large-v3-turbo-q5_0.bin`.

### Transcribe, on a video with no uploaded captions: PASS

The video is `fl1DSmwQKKY`, "What is Claude Code?", 175 s. Its subtitle list on YouTube has no
uploaded track (`yt-dlp --print "%(subtitles)#j"` gives `NA`). The run is V2
(`walk-58383e74da50`), with `--min-words 150`. Exit 0, every step PASS.

- **Captions first, as the skill says.** Rich first ran `yt-dlp --skip-download --write-subs
  --sub-langs "en" …` and got none.
- **Then the large model.** He ran `ffmpeg … -vn -ar 16000 -ac 1 …` and then
  `whisper-cli -m "$RICHOS_SPEECH_MODEL" -f audio.wav -l en -t 4 -fa -mc 0 -np -otxt -of
  transcript`, which is the skill's flags exactly.
- **No auto-generated captions** were fetched.
- **The transcript** is `~/Downloads/video-transcript.txt`, 438 words.
- **The answer** summarizes the video in plain words: what Claude Code is, how it differs from
  regular Claude, examples, three things to keep in mind. It ends: "The video had no captions
  uploaded by a person, so I transcribed the audio on your Mac." It also says that the
  transcription heard "Claude" as "Cloud" or "Clawd", and that he corrected those in the file
  (frame `v-transcribe-answer`).
- **Not measured.** The word error rate against YouTube's auto-generated captions:
  `yt-dlp --write-auto-subs` from this Mac answered HTTP 429. The full-length benchmark
  (`D8PikZ1KhUo`) is the development build's, as the brief says.

### Captions, on a video with uploaded captions: FAIL in three of four runs

The video is `jNQXAC9IVRw`, "Me at the zoo", 19 s. YouTube lists uploaded English and German
tracks for it ("Available subtitles … en English").

| Run | VM | Captions fetched | Transcribed | What the answer says about its words |
|---|---|---|---|---|
| V1 | `walk-b601aeeab1ca` | no | yes, `whisper-cli -m "$RICHOS_SPEECH_MODEL"` | "Here's what he says, transcribed from the audio" |
| V3 | `walk-d4dc0f1f2315` | **yes**, `--write-subs --sub-langs "en"` | no | "The words come from the captions uploaded with the video" |
| V4 | `walk-9f23af99182a` | no | yes | "I worked out the words by transcribing the audio on your Mac" |
| V5 | `walk-77e4b07b3cee` | no | yes | "I downloaded the video, watched it and transcribed the sound" |

- **What a user sees when it goes wrong** (V1, frame `v-captions-answer-fail`). The answer quotes
  the transcription and adds: 'The transcription software heard "fronts," but he almost
  certainly means "trunks."' The uploaded captions have the right word. That is the CEO's reason
  for putting a person's captions first. The answer is honest about its source and right in
  substance, but it took the slower, less accurate path the skill tells him not to take.
- **No run fetched auto-generated captions,** so the CEO's harder rule held every time.
- **The passing run** (V3, frame `v-captions-answer-pass`) used the captions alone and said so.

## 3. The wording: PASS

### The fast-use line (D15 from walk 43)

The walk is `handoff-walk.sh single`, run H1 (`walk-516d168504e4`), exit 0, every check ok:

- the gate's order reached the helper;
- the continuation waited while the account was at its point, with no turn;
- it went on after the fake's reset;
- "Handed over cleanly." appears once;
- no work record says failed.

**The sentence.** On 43 it read "will pause them at 44%, not 51%" while the account was already
at 51%. It now reads (frame `h1-4-after-order`, `qa/ocr-find.sh` hit):

> Usage is climbing fast: 1 agent took the weekly window from 50% to 51% in 1 minute. I'm
> checking every minute now, and the team is being told to hand over now, so it never reaches
> 100%.

**The way back.** On 43 it named the five-hour line, 93%. It now names the weekly line (frame
`h1-5-after-handoff`):

> Usage is back to normal. I'm checking every 5 minutes again, and the weekly line is back at
> 51%.

`ocr-find.sh` over both frames finds neither "will pause them at" nor "line is back at 93".

### Notices as paragraphs

Every answer the five video runs recorded was checked for a sentence run into the next one
(`video-watch-walk.py`'s new `glued` rule, commit `e6a44f526`). There were none:

| Run | Paragraph breaks | Glued sentences |
|---|---|---|
| V1 | 6 | none |
| V2 | 5 | none |
| V3 | 4 | none |
| V4 | 3 | none |
| V5 | 4 | none |

The case the fix was for is in V2. One turn said "The transcript is done; now I'm saving it to
your Downloads folder and cleaning up.", ran its tools, and then said "I downloaded the video
and saved its full transcript…". The two arrive as two paragraphs.

## D16 (new, from candidate 44's video skill, blocking)

**Asked about a video that has uploaded captions, Rich usually transcribes it instead of reading
the captions.**

**Where.** The conversation's answer to "Please download this YouTube video for me and tell me
what is in it: https://www.youtube.com/watch?v=jNQXAC9IVRw".

**Steps.**
1. A fresh install. The video tools are installed by the background download.
2. Send that message.
3. Approve what the panel asks.

**Expected.** The brief's pass, from the CEO's caption rule: captions a person uploaded first,
used alone, and the answer says so. The skill (`crates/richos-core/skills/video/SKILL.md` §4)
says "Three sources, in this order", with uploaded captions first.

**Actual.** Three runs of four never ran `--write-subs`. Each took the video it had just
downloaded, extracted the audio and ran `whisper-cli`. The answer then said the words were
transcribed.

**Cause.** This is a hypothesis from the skill's text, not measured. In all three failing runs
Rich first downloaded the video to `~/Downloads`, as the request asks, and then went straight to
§4b. §4b's heading is "No uploaded captions (or a file on his Mac): transcribe it", and once the
video is downloaded it IS a file on his Mac. §4a ("Captions a person uploaded, through yt-dlp")
never says that a link keeps its captions after the file has been downloaded.

**Why it blocks.** It is the first half of the brief's item 2 pass, and it fails three times in
four. The transcribe half and the "never auto-generated" rule hold. The harm is a slower answer
whose quoted words can be wrong ("fronts" for "trunks"), on exactly the videos where the right
words were available for free.

**What would show it fixed.** The captions half of `video-watch-walk.py` passing in four runs of
four. It now also fails a `whisper-cli` run and an answer that does not say its words came from
the captions (commit `e6a44f526`).

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen. At most two runs at once, one per guest slot. One app window, no two-user test. Guest
  screen 1680x1050 at 1x.
- **Artifact.** The candidate's signed zip, with the same folder's `richos-engine-1.2.0.tar.gz`
  as `--engine`. `--expect-sha 787e4f0e9`, the build commit.
- **Accounts.**
  - The video runs used the real Claude login that `run.sh` copies into each guest. Nothing was
    switched, and no account file on this Mac was written.
  - The handoff run used the committed fake `claude` (`fake-claude-fill-first.pl`).
- **Audio.** No sound was played. The voice step's microphone was a two-second silent WAV written
  in the guest (`RICHOS_VOICE_INPUT_WAV`). The microphone grant was written the way `voice-walk.py`
  writes it.

### Runs

Every run reported "clean: app quit, VM stopped, clone deleted, state removed." and released its
slot.

| Run | VM | Walk (at commit) | Result | Seconds |
|---|---|---|---|---|
| S1 | `walk-7989ed462805` | `setup-walk.py --memory not-now` (f2cbeeaad) | identity, meanwhile, arrived PASS; relaunch: harness, an accessibility read past its 20 s guest deadline | 255 |
| H1 | `walk-516d168504e4` | `handoff-walk.sh single` (f2cbeeaad) | **every check ok, exit 0** | 385 |
| S2 | `walk-b654eaf2d868` | `setup-walk.py` with the voice step (cc328ccd4) | ready line read; the press showed nothing within 30 s with both slots busy (harness) | 249 |
| S3 | `walk-6aa050fcab37` | `setup-walk.py` (376e37ec2) | **every step PASS, exit 0** | 282 |
| I1 | `walk-cb6438f6ea38` | `steps-walk.py`, the Settings version line | version line read; the closing tree hit the guest deadline (evidence only) | 109 |
| V1 | `walk-b601aeeab1ca` | `video-watch-walk.py`, all steps (d7ee89c65) | setup to speech-env PASS; **captions FAIL (D16)**; transcribe not reached | 2088 |
| V2 | `walk-58383e74da50` | `video-watch-walk.py`, transcribe half (d7ee89c65) | **every step PASS, exit 0** | 422 |
| V3 | `walk-d4dc0f1f2315` | `video-watch-walk.py`, captions half (d7ee89c65) | **every step PASS, exit 0** | 309 |
| V4 | `walk-9f23af99182a` | `video-watch-walk.py`, captions half (d7ee89c65) | **captions FAIL (D16)** | 881 |
| V5 | `walk-77e4b07b3cee` | `video-watch-walk.py`, captions half (d7ee89c65) | **captions FAIL (D16)** | 895 |

### Every harness failure, read from its own evidence

- **The video walk's setup step (before V1).** On `f2cbeeaad` it could not have run against this
  candidate, for two reasons:
  - it called `setup_walk.run_outcome`, which `setup-walk.py` lost in `3c614b443`, and an
    `AttributeError` is outside the walk's caught failures;
  - it waited for a "Set it up" that, since `a4facb643`, belongs only to the memory question.

  Fixed in `d7ee89c65`: on a build whose boot says "video tools: downloading in the background"
  nothing is pressed, and the step waits for "My video tools are installed.".
- **S1 relaunch.** `ax.sh find --title "Set it up"` reached its guest deadline (exit 124,
  `guest_deadline`). The host was at 97.8% CPU with both guests up. Since `cc328ccd4`, a find is
  asked again at most twice, as `voice-walk.py` already does.
- **S2 voice.** The press showed neither "Stop talking" nor the offer within 30 s, and the step
  kept nothing to say why. `376e37ec2` gives it 90 s and keeps the app's voice and capture lines.
  S3 then showed the cause, voice timing both models before it opens (above).
- **I1.** The version line was read and shot. The last step, a whole-window tree kept as
  evidence, passed the guest deadline.

## Not walked, and why

- **Everything walk 43 passed.** Candidate 44's other merges are not in the brief's three items:
  the startup lock, the nightly retry reconciliation and the walk-43 record.
- **The full-length transcription benchmark.** The brief: it already passed on a development
  build (`D8PikZ1KhUo`, WER 3.41%).
- **The two-account handoff.** Item 3 names `handoff-walk.sh single` only.

## Seen, outside this candidate's changes (not judged)

**A quotation in an answer shows its `>` mark** (frame `v-captions-answer-fail`). That card also
shows its paragraphs with no space between them. `ui/timeline.js` draws block quotes only for
documents in the Output panel, by design (§7 of that panel's PRD). The answer renderer did not
change between candidates 43 and 44. The only change in `ui/` is `ui/main.js`, from `a4facb643`
(the background download).

## Method and toolkit

All of it is `richos/app/scripts/` on this branch, on top of the candidate's source `f2cbeeaad`.

**`testvm/`:**
- `run-walk.py --wait` and `slots.py status`;
- the walks:
  - `setup-walk.py --memory not-now`, with `TESTVM_APP_ENV=RICHOS_VOICE_INPUT_WAV=…` for the
    voice step;
  - `video-watch-walk.py` (all steps, and `--steps` for each half);
  - `handoff-walk.sh single`;
  - `steps-walk.py` for the version line;
- through them: `ax.sh`, `shot.sh`, `guest.sh` and `relaunch.py`.

**Read-only guest reads during runs V1 and V4.** `guest.sh` read the evidence journal, the
assignment record and the conversation ledger, to see why a captions half was still waiting.

**`qa/`:**
- `ocr-find.sh` (the D15 sentences in the H1 frames);
- `contrast.py` (regions; see below);
- `redact.py --homes`;
- `ocr-gate.sh` with its positive control;
- `wait-for.sh --log`.

**Elsewhere:**
- `nightly-local.py candidate --run 20261007T193741Z-644592ff`;
- `shasum`;
- `yt-dlp --print`/`--list-subs` on this Mac, to choose the transcribe video and confirm the
  captions video's uploaded tracks;
- `sips` (JPEG copies).

**Scripts written from scratch: none.** The walks were fixed and extended, each change its own
commit:

- `d7ee89c65`: video-watch-walk's setup waits for the background download
  (`test/video-watch-walk.test.py`, 4 tests);
- `cc328ccd4`: setup-walk's voice step, and finds retried past the guest deadline
  (`test/setup-walk.test.py`, 14/14);
- `376e37ec2`: the voice step gets 90 s and keeps the app's capture lines;
- `e6a44f526`: the captions half passes only on the uploaded captions alone, said so; both halves
  fail glued sentences; the captions half ends once the answer has settled
  (`test/video-watch-walk.test.py`, 7/7).

**Contrast.** No new text came with this candidate's screens: the sentences in item 3 sit in the
existing "reached out" card. The voice row's "try again" (frame `s-voice-pressed`) measured
4.99:1 (`#5E6166` on `#EAE6DD`, light), which passes AA for normal text. Dark mode was not
walked; no screen this candidate changed has new colors.

### Frames

- **Format.** JPEG q80 copies of the 1680x1050 PNG originals. Every number above was measured on
  the PNG.
- **Prefixes.**
  - `s-` is setup run S3;
  - `h1-` is H1;
  - `i-` is I1;
  - `v-transcribe-` is V2;
  - `v-captions-answer-pass` is V3;
  - `v-captions-answer-fail` is V1.
- **Redaction.** `v-captions-answer-fail` had the guest's own home path in Rich's answer. It was
  covered with `redact.py --homes`, which then re-read the output clean.
- **The privacy gate.** `ocr-gate.sh` ran over the 10 PNG frames these JPEGs were made from, with
  its positive control: "0 of 10 frame(s) carry something that must not ship".

## Surfaces

**Applied and checked:**
- the Mac desktop app from its signed bundle, on the first-run path and after a relaunch;
- first setup while the background download runs;
- the talk control;
- the conversation (the video answers, the fast-use lines, the handoff);
- the Settings menu's version line;
- the records behind them: the app log, the conversation ledger, the evidence journals, the
  assignment records and `claude-accounts.json`.

**Not applicable:**
- phones: nothing touched;
- battery: no `richos/mobile/**` change;
- the stable channel: nothing was published.

**Test data.** Each guest was a fresh clone with its own empty home. Nothing touched this Mac's
app data.

## Cleanup

- **The runs.** All ten ended clean, each releasing its slot.
- **After the last run:**
  - `slots.py status` read "guest.lock: free" and "guest-2.lock: free";
  - `~/.richos-testvm/tart/vms/` holds only `richos-base`;
  - `~/.richos-testvm/run/` is empty.
- **This Mac.** No app was started on it. `pgrep -fl richos-tauri` and `pgrep -fl 'tart run'`
  both listed nothing, with the checking command's own lines filtered out.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk44/` was deleted after this record was
  committed.

## Defects, in one list

- **D16 (new, from candidate 44's video skill, blocking).** On a video with uploaded captions,
  Rich transcribed the audio instead of reading the captions in three runs of four. In the one
  run that used the captions, they were the only source and the answer said so.
- **D15 (from candidate 43): fixed.** The fast-use line says the team is being told to hand over
  now, and the way back names the weekly line.

Verdict: NOT READY
