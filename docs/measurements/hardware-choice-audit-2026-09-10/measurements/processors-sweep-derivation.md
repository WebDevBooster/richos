# `--processors`: a vendor default, examined, and it wins

Companion to [`processors-sweep.txt`](processors-sweep.txt).

## Why this flag and not another

`whisper-cli -p N` / `--processors N` splits the input audio into N chunks and decodes them
concurrently. Of every flag this binary accepts, **it is the one whose right value most obviously
scales with the machine** — it is audio-level parallelism, so "a bigger machine should use more of
it" is the natural expectation, and it is exactly the expectation the CEO's question is about.

**Nothing in this repository has ever passed it.** `stt.rs::decode_args` does not emit it;
`config.js::whisperArgs` does not emit it; a repo-wide grep for `--processors` returns nothing, and
the only `"-p"` in the tree is `richos-user-update/src/lib.rs:756`, an unrelated `-p <profile>`.
So every decode on every machine runs at whisper-cli's own default:

```
  -p N,      --processors N         [1      ] number of processors to use during computation
```

That is the same shape as the `-mc -1` that sat unexamined under both tiers and cost two weeks —
a vendor default holding a decision nobody made. The CEO's standing rule is that a default is
allowed only where it has *proven* to be the best possible setting. This is that proof, or it is
not; either way it stops being an inheritance.

## Method

`-p` means nothing on a 3.095 s utterance — there is nothing to split, so the live path is out of
scope by construction. The path where it could matter is the batch/call-transcription one, which
decodes 92-minute channels. The probe is 61.906 s of audio (the utterance concatenated 20 times),
decoded through `ggml-large-v3-turbo-q5_0.bin` — `DEFAULT_TIER` since the CEO decision page §10.

argv is `config.js::whisperArgs()` verbatim minus `-oj` (an output shape, not a decode cost).
Three reps per cell, minimum reported, peak RSS from `/usr/bin/time -l`.

## Result

| `-p` | wall clock (s) | peak RSS (B) |
|---|---|---|
| **1 (the default, and what ships)** | **3.488** | **872,873,984** |
| 2 | 4.372 | 1,029,455,872 |
| 4 | 4.726 | 1,334,525,952 |

**More processors is slower, monotonically:**

```
  4.372 / 3.488 = 1.2534   ->  -p 2 is 25.3 % SLOWER than -p 1
  4.726 / 3.488 = 1.3549   ->  -p 4 is 35.5 % SLOWER than -p 1
```

**And it costs memory at the same time:**

```
  1,334,525,952 / 872,873,984 = 1.5289   ->  -p 4 holds 52.9 % more resident
```

Both directions are explained by the same fact and neither is a surprise once it is said out loud:
the decode is carried by **one** Metal device, so N concurrent decoders contend for it rather than
adding throughput, and each carries its own copy of the working state. Parallelism across a
resource you have exactly one of is not parallelism.

For scale, `-p 1` decodes at

```
  61.906 / 3.488 = 17.75 x real time
```

which is the figure the batch gate in `hardware.rs::resolve_batch` cares about, and it is 17.75x
clear of needing help.

## Verdict

**`-p 1` is correct, on this machine and on every machine with one GPU — which is every Mac.** It
is now correct *because it was measured*, not because whisper-cli chose it. It does not need to
become hardware-resolved and it should not: a resolver that raised `-p` on a machine with more
cores would make that machine slower and hungrier, which is the failure the naive reading of
"pick things based on the actual hardware" produces.

**The honest limit of this measurement:** it was taken with Metal carrying the decode. On a host
with no usable Metal backend the contention argument weakens, because the work would spread over
independent CPU cores instead. That case is already served better by `-t` (see
[`thread-sweep-derivation.md`](thread-sweep-derivation.md)), which adds no per-processor memory,
so `-p 1` remains the right answer there too — but the *reason* is different and only the Metal
half is measured. What would settle the other half is this same sweep with `-ng`, on a machine
where the CPU path is the shipping path rather than a proxy.

## Stack identity

```
whisper-cli   /opt/homebrew/bin/whisper-cli
sha256        7dc20e3106d70746d61c419646d9bf87f726a5df7da562e26e8529067119f7b8
host          Mac16,10 (Apple M4), 10 cores (4P + 6E), 25,769,803,776 B, Metal 3
probe         61.906 s, 990,500 frames @ 16 kHz, sha256 ff957e99c4b573eec790bae4f684129163d9eea2cd19d62d7c9483e69c5ee3c8
              (built by repeating the 3.095 s utterance 20x; not committed, for the reason the
               sibling rigs give — `say` output drifts between renders)
```

Run with system output **muted at the device level**; `say -o` writes a file and plays nothing.
