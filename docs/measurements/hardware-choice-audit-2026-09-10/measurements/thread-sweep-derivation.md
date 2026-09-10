# What `-t 4` costs, derived rather than quoted

Companion to [`thread-sweep.txt`](thread-sweep.txt), which is the raw capture. This file is the
arithmetic, shown, so nothing below has to be taken on trust.

## The claim under test

`app/crates/richos-voice/src/stt.rs:244` and `tools/richos-service/lib/config.js:596` both pin the
whisper decode thread count to **4**, with the same stated reason:

> the decode is Metal-bound; 8 threads measured byte-identical at the same wall clock
> — `stt.rs:243`
>
> byte-identical to `-t 8` at the SAME wall clock — the decode is Metal-bound, so threads past 4
> buy nothing. Pinned so the value is ours, not the vendor's idea of this machine.
> — `config.js:562`

Two separate things are being claimed and only one of them was measured:

1. **"Threads past 4 buy nothing."** True *when the decode is Metal-bound*.
2. **"The decode is Metal-bound."** A property of the machine it was measured on, asserted here as
   a property of the decode.

## What `whisper-cli --help` says the vendor default is

```
  -t N,      --threads N            [4      ] number of threads to use during computation
```

**The pinned value IS the vendor default, digit for digit.** The comment says the pin exists so the
value is "ours, not the vendor's idea of this machine"; the value chosen is exactly the vendor's
idea of this machine. Passing a default explicitly is still worth doing — it cannot be flipped by a
formula bump, which is the reason `-fa` is passed — but it does not make the number a decision, and
the comment reads as though it does.

## Method

`-ng` (`--no-gpu`) is the local proxy for a host with no usable Metal device: an Intel Mac, or an
Apple Silicon Mac whose Metal backend failed to load. It is a proxy and it is named as one — it
removes the GPU from a machine that still has this machine's CPU. It cannot tell you what an
Intel i7 costs; it can tell you whether thread count matters at all once the GPU stops carrying the
decode, which is the question the pin's reason answers with "no".

argv is `stt.rs::decode_args(None)` verbatim — `-l en -t N -fa -np -nt -mc 0` — plus `-m`/`-f`.
Model `ggml-small.en.bin`. One 3.095 s utterance. Five reps per cell, **minimum** reported, for the
reason `hardware.rs::record_speed` already gives: a busy machine can only make a sample slower.

## Result, with the arithmetic

| threads | Metal on (s) | Metal off (s) |
|---|---|---|
| 1 | 0.538 | 7.586 |
| 2 | 0.513 | 4.178 |
| **4 (shipped)** | **0.503** | **2.842** |
| 6 | 0.503 | 2.689 |
| 8 | 0.510 | **2.295** |
| 10 | 0.508 | 4.762 |

**With Metal, the pin is correct and the reason holds.** Span across 1→10 threads:

```
  0.538 - 0.503 = 0.035 s
  0.035 / 0.503 = 6.96 %
```

Seven percent between the best and the *worst* thread count, with the worst being a single thread.
Nothing to choose. `-t 4` is right on this class of machine and this measurement confirms it.

**Without Metal, the pin costs 19.2 %:**

```
  2.842 - 2.295 = 0.547 s
  0.547 / 2.842 = 19.24 %
```

and the full span is a factor of 3.3:

```
  7.586 / 2.295 = 3.305 x
```

## The part that disqualifies the obvious fix

`-t 10` — this machine's full logical core count, which is what `std::thread::available_parallelism()`
and `os.cpus().length` both return here — is **worse than the shipped `-t 4`**:

```
  4.762 / 2.842 = 1.675 x   (67.5 % SLOWER than the value it would replace)
```

and its five samples were 6.990, 4.762, 47.065, 16.571, 6.573 — a spread of 42.3 s, against 0.133 s
at `-t 8`. Ten threads on 4 P-cores + 6 E-cores does not oversubscribe the core count; it puts the
decode's critical path onto efficiency cores and lets the scheduler move it around.

So **"read the core count and use it" is not the fix.** A resolver that asked the machine for its
core count and believed the answer would make this machine 67.5 % slower on the CPU path while
looking exactly like the thing the CEO asked for. The best value here was 8 — neither the P-core
count (4) nor the logical count (10) — which is to say the optimum is a *measured* property of the
machine, not a formula over its spec sheet.

That is the same conclusion `hardware.rs` already reached about model choice, and it points at the
same mechanism: the speed cache at `~/.config/richos/whisper-speed.json`, keyed by
`cache_key(bin_sha, machine)`, which already calibrates once per machine per whisper binary.

## The signal needed to tell the two rows apart already exists and is free

`app/crates/richos-voice/src/toolchain.rs:262 pub fn parse_backends(stderr: &str)` and
`tools/richos-service/lib/toolchain.js:206` both already read whisper-cli's own `load_backend:`
lines, which name every ggml compute backend the binary actually dlopen'd:

```
load_backend: loaded BLAS backend from /opt/homebrew/Cellar/ggml/0.17.0/libexec/libggml-blas.so
load_backend: loaded MTL backend from  /opt/homebrew/Cellar/ggml/0.17.0/libexec/libggml-metal.so
```

`MTL` present or absent **is** the difference between the two tables above, it is read on every run
already, it costs nothing extra, and no decision consumes it. The app is not failing to detect the
GPU. It detects it, records it in the toolchain lock, and then chooses threads as if it had not.

## Stack identity

```
whisper-cli   /opt/homebrew/bin/whisper-cli
sha256        7dc20e3106d70746d61c419646d9bf87f726a5df7da562e26e8529067119f7b8
host          Mac16,10 (Apple M4), 10 cores (4P + 6E), 25,769,803,776 B, Darwin 24.6.0
probe         3.095 s, 49,525 frames @ 16 kHz, sha256 547d525a0125cc679c47c44b1a467dbd0bb7445409e5e047c725192723510622
```

Same binary and same sha256 as `../hardware-model-resolution-2026-09-10/`, re-read rather than
transcribed, so the two rigs' numbers are comparable.

The probe WAV is deliberately **not committed**, for the reason the sibling rig gives: `say` output
drifts between renders, so a committed file would imply a stability it does not have. Re-render it
with the command in [`../README.md`](../README.md) of this directory.

`say -o` writes a file and plays nothing; the sweep was additionally run with system output **muted
at the device level** (`osascript -e 'set volume output muted true'`, verified `true` before the
first decode).
