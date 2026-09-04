# Assets — the word-density instrument (2026-08-30)

Everything needed to re-run and audit `../norm-brief-substitution-density-2026-08-30.md`.

**No audio is here, no transcript is here, no line of anybody's speech is here, and nobody's name is here.** The last clause was added 2026-09-04, because it was not true: `tools/normalize.sh` named the second speaker in a source filename, and he found it himself after the repository went public. A filename is personal data even when the audio it names never ships. The script now takes both names as environment variables. This directory
is in `richos`, which gets published. The two source mp3s live in `docs/reference/local/`, which is
gitignored; neither they, nor the normalized `me.wav` / `others.wav`, nor any probe clip, nor any
whisper JSON is committed anywhere. Every file in `results/` was written through `tools/redact.mjs`,
which recursively deletes `recovered`, `text`, `nearbyText` and `transcript` keys and prints the byte
delta for each file — a redactor that silently removed nothing would be the failure it exists to
prevent. The burst grids are committed as **summaries only** (peak, floor, count, seconds): the full
grid is a second-by-second map of when a private recording is speech, it is free to regenerate, and
it does not need to be here.

Paths inside the scripts point at the session scratchpad (`.../scratchpad/sub/`); repoint `SP` to
re-run elsewhere. They import the product's modules from the worktree
`/Users/alex/ab/richos-wt/norm-substitution-2026-08-30` — **never a copy of the logic**. Repoint
those imports at wherever the branch lands. A harness that reimplements the rule it is scoring
proves nothing about the rule that ships.

## `tools/`

| File | Purpose |
|---|---|
| `normalize.sh` | the production normalize step over the two gitignored mp3s, and the sha256s that prove it is the same corpus the 2026-08-29 briefs measured |
| `run-all.sh` | the four 92-minute decodes: `-mc 0` (shipping) on both channels, `-mc -1` on both, `q5_0 -mc -1` on `me` |
| `bursts.mjs` | the physical grid, via the product's own `detectSpeechBursts()` |
| `profile.mjs` | **stage A only, free:** the channel's whole density profile — every window, its detected speech, its emitted words, its rate, and the percentiles. This is where the budget comes from |
| **`score.mjs`** | **the main harness: the product's `guardSubstitution()` over a real 92-minute run**, with a real probe built from the product's own `cutSpan` / `measureSpanVolume` / `transcribeClips`, and the repetition guard run first so the segments judged are the ones that ship. Caches probe decodes so the rule can be swept without re-running whisper |
| `control.mjs` | the surgical SUBSTITUTION control on the 92-minute corpus — dense windows reduced to four invented words, the instrument must fire on each and stay silent on the rest of the same run |
| `build-corpus-timed.mjs` | the 2026-08-29 invented short-call builder plus `reference-timeline.json` (start, end and word count of every synthesized turn) — what makes that corpus a reference for a DENSITY instrument |
| `tts-measure.mjs` | the reference-checked measurement: false positives on 12 correct transcripts, then one turn per channel substituted, scored against the reference |
| `combined.mjs` | both detectors in the pipeline's own order (3.7, then 3.8 with 3.7's spans excluded) plus the whole-transcript inspection of every finding |
| `inspect2.mjs` | second-pass inspection: did the repetition guard take the words, or did the model never emit them? |
| `deltest.mjs` | the deletion detector scored pre-guard vs post-guard — the §9 discrepancy |
| `pipeline-e2e.mjs` | the wiring proof AND the cost measurement: a real `runPipeline()` over both channels, cost read from the product's own record |
| `mutate.py` | the mutation battery — 24 mutations of the shipped source, and it FAILS if any test survives all of them |
| `redact.mjs` | the speech redactor every file in `results/` was written through |
| `all.sh` / `combined-all.sh` | re-score everything |

## `results/`

| File | Contents |
|---|---|
| `score_{ship,bare}_{me,others}.json` | the full instrument report per run per channel: every window count, every candidate, its verdict, its level and its reason |
| `combined_{ship,bare}_{me,others}.json`, `combined_q5bare_me.json` | both detectors in pipeline order, with 3.7's spans excluded from 3.8, plus the inspection verdict for every finding |
| `control_ship_{me,others}.json` | the surgical positive control, 8 windows per channel, including the whole-transcript echo test that §7 turns on |
| `tts_reference.json` | the reference-checked corpus: 12 clean channels and 12 substituted turns, scored against a reference known by construction |
| `inspect2_bare_{me,others}.json` | guard-removed vs model-never-emitted, per finding |
| `e2e_full.json` | the end-to-end run: status, wall clock, and both stages' share of it |
| `mutation.json` | every mutation, and exactly which tests each one drove red |
| `burst-grids.json` | the grid summaries (peak, floor, bursts, speech seconds, wall clock) |

Not committed (regenerable, or private by construction): the four whisper JSONs and transcripts, the
normalized channels, every probe clip, the probe caches, and the full burst grids.
