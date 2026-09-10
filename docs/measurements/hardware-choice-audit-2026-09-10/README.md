# The hardware-choice audit, 2026-09-10

The CEO asked when the customer's hardware choices would **permanently** stop being hardcoded into
the app. `echo-opus-hw1` fixed the instance he found — which whisper model the voice path and the
call-transcription path run — and landed it at `c1df6f24`. This directory is the follow-up: the
**whole class**, and the measurement that settles the one finding in it that could not be settled
by reading.

| File | Holds |
|---|---|
| [`../../hardware-choices-2026-09-10.md`](../../hardware-choices-2026-09-10.md) | **the enumeration** — every site, its verdict and its reason |
| `measurements/thread-sweep.txt` | raw capture: decode wall clock at 1/2/4/6/8/10 threads, Metal on and Metal off, five reps each |
| `measurements/thread-sweep-derivation.md` | the arithmetic on that capture, shown rather than asserted |
| `tools/thread-sweep.sh` | the rig |

## Reproducing

```sh
osascript -e 'set volume output muted true'
say -o /tmp/utt.wav --data-format=LEI16@16000 "Rich, what is the status of the voice pipeline today?"
bash tools/thread-sweep.sh /tmp/utt.wav
```

The probe WAV is not committed — `say` output drifts between renders, so a committed file would
imply a stability it does not have. The sentence and the sha256 of the render these numbers came
from are in `measurements/thread-sweep-derivation.md`.

## The one-line result

`-t 4` is **right** on a machine whose Metal backend loaded (7.0 % span across every thread count
from 1 to 10) and **costs 19.2 %** on one whose Metal backend did not (2.842 s against 2.295 s).
Nothing in the codebase distinguishes the two, although
`toolchain.rs::parse_backends` already reads which backends the binary loaded on every single run.

And the obvious fix is wrong: `-t 10`, this machine's own logical core count and what
`available_parallelism()` returns here, is **67.5 % slower** than the shipped `-t 4`.
