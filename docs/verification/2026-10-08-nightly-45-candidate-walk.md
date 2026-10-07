# Walk of nightly candidate 45 (`v1.2.0-nightly.20261007.45`), 2026-10-08

**Verdict: READY.** D16 is fixed on candidate 45's own signed bundle, in the test VM. Asked about
a video that has captions a person uploaded, Rich used those captions in all three runs. He used
only those captions, and every answer says the words came from the captions. On candidate 44
this held in one run of four.

The brief asked for this half only. Everything else passed on candidate 44
(`docs/verification/2026-10-07-nightly-44-candidate-walk.md`) and was not walked again.

## What changed since candidate 44, re-derived

- **The product change is the video skill only.** `git diff --stat f2cbeeaad c04e3f381` (44's source
  to 45's) touches three files outside walk tools and records:
  - `crates/richos-core/skills/video/SKILL.md`, 6 lines;
  - `crates/richos-core/src/skills.rs`, 17 lines (one new test);
  - `richos/app/README.md`, a test count.
- **What the skill now says.** Commit `79d4f2452` adds, before source a: "For a link, always start
  with a, even when you have already downloaded the video in step 2 or step 3". Source b's heading
  no longer says "(or a file on his Mac)". It says "or a file the CEO gave you from his Mac".
- **No change in `ui/`,** so no screen in this candidate has new text or colors.

## Identity, checked before any claim: PASS

- **The zip.** `shasum -a 256` of `RichOS-1.2.0-nightly.20261007.45-macos-aarch64.zip` gives
  `32394f827068c15f2bd66ed594675212f451278aee44fde1f914c37cd1fe2dd4`. Both of its lines in
  `SHA256SUMS` carry that hash: the versioned name and `RichOS-macos-aarch64.zip`.
- **The engine.** `richos-engine-1.2.0.tar.gz` gives
  `e4a2a731fd7d21112fb46a7a6998e7ef37dde52d2a93873ca74e959647a888bd`, its `SHA256SUMS` line. It is
  the same engine as candidate 44's; the skill lives in the app.
- **`candidate.json` `info`:**
  - `source_commit` `c04e3f381be5f459e05358e720b920fb04e3b911`;
  - `run_id` `20261007T221215Z-232ded35`;
  - `version` `1.2.0-nightly.20261007.45`;
  - `build_commit` `4f3a37431bede721f9c83c75d19e350145590d55`.
- **The build commit.** Its parent is `c04e3f381`. `git diff --stat c04e3f381 4f3a37431` touches
  only four files: `nightly-build.json`, `Cargo.toml`, `Cargo.lock` and `tauri.conf.json`.
- **The running app.** Each captions run's identity step read "built from
  `4f3a37431bede721f9c83c75d19e350145590d55`" and passed.
- **The Settings version line.** It reads "RichOS 1.2.0-nightly.20261007.45 is up to date."
  (run I2's accessibility find, `value='RichOS 1.2.0-nightly.20261007.45 is up to date.'`; frame
  `i-version-menu`).

## The captions half: PASS, three runs of three

The walk is `video-watch-walk.py --steps identity,setup,first-run,connect,speech-env,captions`.
The video is `jNQXAC9IVRw`, "Me at the zoo", 19 s, which has uploaded English captions. The message
is "Please download this YouTube video for me and tell me what is in it:
https://www.youtube.com/watch?v=jNQXAC9IVRw".

**What the walk requires to pass** (commit `e6a44f526`, on this source):
- a Bash run of `yt-dlp --write-subs`;
- no run with `--write-auto-subs`;
- no run of `whisper-cli`;
- the video saved in `~/Downloads`;
- an answer that names the elephant and says its words came from the captions;
- no sentences run together.

In every run each earlier step passed too: setup waited for the background download, and
speech-env read `ggml-large-v3-turbo-q5_0.bin` on every provider lease.

| Run | VM | Captions fetched | Transcribed | Auto-generated | What the answer says about its words |
|---|---|---|---|---|---|
| C1 | `walk-f125d2c1643a` | **yes**, `--write-subs --sub-langs "en"`, got `jNQXAC9IVRw.en.vtt` (440 B) | no | no | "I got the words from the captions someone uploaded with it" |
| C2 | `walk-e90cc376926d` | **yes**, the same, the same 440 B file | no | no | "What he says (from the captions uploaded with the video)" |
| C3 | `walk-a397d6bab957` | **yes**, the same, the same 440 B file | no | no | "Going by the captions that come with the video" |

**The order is the one the fix asks for.** In all three runs Rich first downloaded the video to
`~/Downloads`, as the message asks, and took still frames from it with `ffmpeg`. With the video
already on disk, he still ran the uploaded-captions check on the link. That is the exact situation
that sent three runs of four to transcription on candidate 44.

**What a user sees** (C1, frame `v-captions-answer`):
- the trunks line is right ("really, really, really long trunks");
- the answer says the words came from "the captions someone uploaded with it";
- it says the picture came from still frames.

On candidate 44 the transcribed runs heard "fronts" for "trunks".

**C3's wording** says "the captions that come with the video", not "uploaded". The commands show
it fetched only the uploaded track (`--write-subs`, never `--write-auto-subs`), so the claim is
true, just less exact than C1's and C2's.

## Not walked, and why

- **Everything candidate 44 passed:** the transcribe half, the essentials download at first launch,
  the fast-use wording and the notices as paragraphs. The brief: they passed on 44, and the only
  product change since is the skill text above.
- **A fourth captions run.** The 44 record named "four runs of four" as what would show D16 fixed.
  This brief asked for three, and three were run.

## Seen, outside this candidate's changes (not judged)

- **A paragraph that starts in bold shows no space above it** (frame `v-captions-answer`: "It's
  saved at:", the path, then "What's in it:" with no gap; the same before "Why it matters:"). The
  source text has a blank line there. Walk 44 saw the same thing, and the answer renderer has not
  changed since.
- **C2 and C3 quote the full path to the saved video.** In the guest that path holds the test home
  (`/Users/admin/testvm/walk-…/home/Downloads/…`). On a real Mac it would be the user's own
  Downloads folder. C1 wrote `~/Downloads/…`. Neither frame went into the record.

## Verification mode

- **Environment.** The test VM, one fresh guest per run through `run-walk.py`, never this Mac's
  screen. At most two runs at once, one per guest slot. One app window, no two-user test. Guest
  screen 1680x1050 at 1x.
- **Artifact.** The candidate's signed zip, with the same folder's `richos-engine-1.2.0.tar.gz` as
  `--engine`. `--expect-sha 4f3a37431`, the build commit.
- **Account.** The real Claude login that `run.sh` copies into each guest. Nothing was switched,
  and no account file on this Mac was written.
- **Audio.** No sound was played. The captions half plays nothing.

### Runs

Every run reported "clean: app quit, VM stopped, clone deleted, state removed." and released its
slot.

| Run | VM | Walk | Result | Seconds |
|---|---|---|---|---|
| C1 | `walk-f125d2c1643a` | `video-watch-walk.py`, captions half | **every step PASS, exit 0** | 418 |
| C2 | `walk-e90cc376926d` | `video-watch-walk.py`, captions half | **every step PASS, exit 0** | 456 |
| C3 | `walk-a397d6bab957` | `video-watch-walk.py`, captions half | **every step PASS, exit 0** | 314 |
| I1 | `walk-f633c249ef01` | `steps-walk.py`, `steps/walkI.json` as first written | harness: the list's second "Not now" press hit the company question's own "Not now" | 127 |
| I2 | `walk-4a28907c9ff5` | `steps-walk.py`, `steps/walkI.json` as committed | **every step exit 0**; version line read | 106 |

**I1, read from its own evidence.** The list pressed "Not now" on the memory question and then,
in case a second sheet was up, pressed "Not now" again. With the background download there is no
second sheet, so that press declined the company question itself, and "Add this company" never
came back. The extra press was removed. I2 ran the corrected list, which is the one committed.

## Method and toolkit

The walk and its tools are `richos/app/scripts/` on this branch, on top of the candidate's source
`c04e3f381`. The `qa/` tools are the same as at `abe345a99`.

**`testvm/`:**
- `run-walk.py --wait 900` and `slots.py status`;
- `video-watch-walk.py --steps identity,setup,first-run,connect,speech-env,captions`;
- `steps-walk.py --steps docs/verification/2026-10-08-nightly-45-candidate-walk/steps/walkI.json`,
  and `--check` on that list.

**`qa/`:**
- `wait-for.sh --log`, to wait on each run's log;
- `ocr-gate.sh` with its positive control.

**Elsewhere:**
- `nightly-local.py candidate --run 20261007T221215Z-232ded35`;
- `shasum`, `jq` and `git diff --stat`;
- `sips` (JPEG copies).

**Scripts written from scratch: none.** One data file was added: `steps/walkI.json`, the Settings
version-line step list. Walk 44 read that line with a list it never committed. The new list is
declared in `steps-walk-data.test.sh`'s inputs and covers rows, and that suite passes
(3 ok lines).

**Contrast.** Not measured: this candidate changes no screen (no change under `ui/`).

### Frames

- **Format.** JPEG q80 copies of the 1680x1050 PNG originals.
- **Which.** `v-captions-answer` is C1's answer. `i-version-menu` is I2's Settings menu.
- **The privacy gate.** `ocr-gate.sh` ran over the 2 PNG frames these JPEGs were made from, with
  its positive control: "0 of 2 frame(s) carry something that must not ship".

## Surfaces

**Applied and checked:**
- the Mac desktop app from its signed bundle, on the first-run path;
- the conversation (the video answer) and the Settings menu's version line;
- the records behind them: the app log, the conversation ledger and the provider leases'
  environment.

**Not applicable:**
- phones: nothing touched;
- battery: no `richos/mobile/**` change;
- light and dark themes: no screen changed;
- the stable channel: nothing was published.

**Test data.** Each guest was a fresh clone with its own empty home. Nothing touched this Mac's app
data.

## Cleanup

- **The runs.** All five ended clean, each releasing its slot.
- **After the last run:**
  - `slots.py status` read "guest.lock: free" and "guest-2.lock: free";
  - `~/.richos-testvm/tart/vms/` holds only `richos-base`;
  - `~/.richos-testvm/run/` is empty.
- **This Mac.** No app was started on it. `pgrep -fl 'richos-tauri|tart run'`, with its own line
  filtered out, listed nothing.
- **Scratch.** `/Volumes/E1TB/tmp/claude/ray-opus-walk45/` is deleted after this record is
  committed.

## Defects, in one list

- **D16 (from candidate 44): fixed.** On a video with uploaded captions, Rich used only those
  captions and said so in three runs of three.
- **No new defect.**

Verdict: READY
