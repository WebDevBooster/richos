# Whisper decode settings — the deliberate-decision rig, 2026-09-10

Companion to [`whisper-settings-decisions.md`](whisper-settings-decisions.md), which is the table
this rig exists to fill in. Read that first; this file is how the numbers in it were produced.

**The standing rule this answers,** CEO, 2026-09-10:

> "NEVER use the **default** settings of ANY third-party tool/software for ANYTHING. UNLESS the
> default settings have proven the be the best possible settings."

So every flag `whisper-cli` accepts needs a value we chose and a reason, and "it is the default" is
a reason only where the comparison is on disk. This directory holds the comparisons.

## The four tools

| File | What it does |
|---|---|
| `tools/whisper-argv-shim.sh` | records the REAL `whisper-cli` argv and execs the real binary. Point `RICHOS_WHISPER_BIN` at it. |
| `tools/flag-sweep.mjs` | scores an arbitrary flag set against a KNOWN reference (true WER) through the product's own decode path |
| `tools/longform-decode.mjs` | decodes one long already-normalized channel, same product path, no reference needed |
| `tools/guard-report.mjs` | runs the SHIPPING repetition guard, with its physical speech-burst evidence, over a decode |

Two properties are deliberate and load-bearing:

1. **Nothing here calls `whisper-cli` directly and nothing reimplements a pipeline stage.** Every
   decode goes through `transcribeChannel()`, so the invocation under test is the one the product
   builds. A tuning result measured on a hand-rolled command line would not be a result about this
   product.
2. **Every configuration writes its own `argv.jsonl`.** A results file whose argv does not contain
   the flag it claims to be testing is a broken measurement, and this rig can therefore be caught
   being wrong rather than believed.

## The corpora, and what each can and cannot answer

There will be no new recordings — CEO, 2026-09-10: *"There are no more fucking 'recorded' calls."*
So this is the permanent material, and the honest reach of each piece is part of the record.

| Corpus | Where | What it can answer | What it cannot |
|---|---|---|---|
| 6 invented TTS calls, 47–174 s, 1,852 script words | `richos-hq/docs/briefs/norm-shortcall-wer-2026-08-29-assets/corpus/calls.json`, rebuilt by its own `tools/build-corpus.mjs` | **true WER**, because the script IS the reference | anything about real acoustics, cross-talk, accents, or length past 3 minutes. It is one synthetic voice per channel. |
| 92-minute two-channel real webinar | `richos-hq/docs/reference/local/*.mp3` (gitignored, never committed) | long-form **fabrication** and wall clock, measured by the shipping guard against the physical audio | WER — no verified reference exists, and none is coming |
| 3 private podcast recordings | `richos-hq/docs/reference/local/private-podcast-recordings/` | long-form behavior on a third speaker | WER — `REFERENCE-WORKSHEET-001.md` beside them is the human-verification pass and it is **unfilled** |

**Rebuilding the TTS corpus does not reproduce August's audio.** `say` output has drifted: call-01
is 47.10 s today against the 47.08 s in the committed manifest, and a fresh decode of turbo at
`-mc 0` scores 2.89% where August recorded 4.15%. The rig is not at fault — re-scoring August's
committed hypothesis transcripts against a reference regenerated today reproduces all four recorded
figures **exactly** (4.15 / 10.34 / 3.10 / 4.15, S/D/I identical), which is the check that separates
the two. The consequence is a methodology rule, not a caveat to swallow: **absolute WER is only
comparable inside one sitting on one audio build.** Every A/B in the decision table was run
back-to-back on the same regenerated audio, the same binary and the same day.

## Reproducing

```sh
# 1. rebuild the TTS corpus (no audio is committed anywhere)
cd <richos-hq>/docs/briefs/norm-shortcall-wer-2026-08-29-assets
node tools/build-corpus.mjs corpus/calls.json /tmp/corpus

# 2. score one configuration (repeat with --config/--extra per row of the table)
node <richos>/docs/measurements/whisper-settings-2026-09-10/tools/flag-sweep.mjs \
  --lib <richos>/tools/richos-service/lib --corpus /tmp/corpus --out /tmp/sweeps \
  --wer <richos-hq>/docs/briefs/norm-shortcall-wer-2026-08-29-assets/tools/wer.mjs \
  --config baseline --extra ""

# 3. long form: normalize the real recording the way lib/normalize.js does, decode, then guard
ffmpeg -y -i <mp3> -ac 1 -ar 16000 /tmp/real/me.wav
node .../tools/longform-decode.mjs --lib <lib> --wav /tmp/real/me.wav --channel me \
  --out /tmp/real/runs --config mc0 --extra ""
node .../tools/guard-report.mjs --lib <lib> --segments /tmp/real/runs/mc0__me/segments.json \
  --wav /tmp/real/me.wav --channel me
```

The `--vad` rows additionally need the Silero VAD model, which is **not** part of any current
install: `ggml-silero-v5.1.2.bin`, 885,098 B, sha256
`29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`, from
`huggingface.co/ggml-org/whisper-vad`. That it has to be fetched at all is itself part of that row's
decision.

## Stack identity — the thing every number here is relative to

| Component | Value | How it was read |
|---|---|---|
| whisper.cpp | **1.9.1** (Homebrew, linked) | `whisper-cli --version` |
| ggml backend | **0.17.0** (BLAS + Metal + CPU `apple_m4`) | the backend banner on every run |
| also installed, not linked | whisper-cpp **1.8.3** | `brew list --versions whisper-cpp` |
| host | Apple M4, unified memory, `has tensor = false` | `ggml_metal_device_init` banner |
| models | `ggml-large-v3-turbo.bin` 1,624,555,275 B · `ggml-large-v3-turbo-q5_0.bin` 574,041,195 B | `ls -l ~/Models/Whisper` |

**Neither whisper.cpp nor ggml is pinned by anything this product ships**, and both changed under
the earlier measurements. That is a decision row of its own in the table, not a footnote here.
