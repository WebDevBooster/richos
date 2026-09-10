# The hardware-resolution rig, 2026-09-10

Companion to [`hardware-model-resolution.md`](hardware-model-resolution.md), which is the decision
this rig exists to support. Read that first; this file is what each tool does and how to re-run it.

**This is a MEASUREMENT of a scope the two rigs beside it do not cover.**
[`../whisper-model-choice-2026-09-10/`](../whisper-model-choice-2026-09-10/) put two models head to
head at call length and at 92 minutes; [`../whisper-settings-2026-09-10/`](../whisper-settings-2026-09-10/)
settled every `whisper-cli` flag. Neither measured **one conversational utterance**, and neither
measured `small.en` at all — which is the model the live voice path has hardcoded. Nothing here
changes a flag, a pin, or the CEO decision page §10.

## The tools

| File | What it does, and why it did not already exist |
|---|---|
| `tools/utterance-sweep.sh` | Peak RSS and wall clock for all five installed models on a single 3.095 s utterance, at `stt.rs::decode_args(None)` argv copied verbatim. The existing rigs decode 12 channels or 92 minutes; the live path's whole question is the pause after one sentence. |
| `tools/warm-reps.sh` | Eight warm reps of the two models the live decision turns on. Three runs carries a cold page cache in run 1, which is the wrong number to judge a conversation on — and the load sensitivity it exposed (~50% between a busy and a quiet machine) is what made the resolver take a minimum rather than a single sample. |
| `tools/machine-state.py` | What the machine IS and what it is holding, plus six repeated samples of memory pressure and available memory. It exists to answer "which signal should the resolver read?" with data — and it disqualified two of the three candidates. |

## Results

| File | Holds |
|---|---|
| `measurements/utterance-sweep.txt` | the five-model table, three runs each, with the transcript column |
| `measurements/warm-reps.txt` | eight warm reps, `small.en` against `large-v3-turbo-q5_0`, with medians |
| `measurements/machine-state.txt` | identity, current commitment, and the repeated pressure/availability samples |

## Reproducing

```sh
say -o /tmp/utt.wav --data-format=LEI16@16000 "Rich, what is the status of the voice pipeline today?"
bash tools/utterance-sweep.sh /tmp/utt.wav /tmp/hw-out
bash tools/warm-reps.sh /tmp/utt.wav
python3 tools/machine-state.py
```

The probe WAV is deliberately **not committed** — `say` output drifts between renders, so a
committed file would imply a stability it does not have. The sentence, the exact command and the
sha256 of the render these numbers came from are in
[`hardware-model-resolution.md`](hardware-model-resolution.md) §1.

`say -o` writes a file and plays nothing; the sweeps were additionally run with system output
muted at the device level.

## Stack identity

Same binary as both sibling rigs, re-read rather than transcribed — the full capture is in
`measurements/machine-state.txt`.

```
whisper-cli   /opt/homebrew/bin/whisper-cli -> Cellar/whisper-cpp/1.9.1/bin/whisper-cli
sha256        7dc20e3106d70746d61c419646d9bf87f726a5df7da562e26e8529067119f7b8
host          Apple M4, 10 cores (4P + 6E), 25,769,803,776 B, Darwin 24.6.0
```
