# Assets — the hallucination guard's residual, 2026-08-30

Companion to `../norm-brief-repetition-residual-2026-08-30.md`.

**No audio and no transcribed speech is here, and none may be added.** The 92-minute source is the
CEO's own webinar recording, gitignored at `docs/reference/local/`; this repository is PUBLISHED
(`.publication-boundary` at the root). Everything under `measurements/` is offsets, counts and
verdicts. The one place speech IS quoted anywhere in this work is sample C, which is macOS `say`
TTS of an invented script and was already committed in full as
`tools/richos-service/test/fixtures/captured-hallucinations.js`.

Every path inside the scripts points at this session's scratchpad; repoint `SP` to re-run elsewhere.

## `tools/`

| File | Purpose |
|---|---|
| `decode-all.sh` | the four 92-minute channels at BARE whisper.cpp defaults — byte-for-byte the 2026-08-29 command, so the 72 hand-verified findings reproduce |
| `decode-mc0.sh` | the same four at the SHIPPED decode args (`-mc 0`), for the cost in the world we actually run |
| `segs.mjs` | whisper `-oj` timelines -> the segment shape the guard consumes |
| `bursts.mjs` | the PRODUCT's `detectSpeechBursts` grid for both channels, imported not re-derived |
| `sweep72.mjs` | first-pass sweep of the veto's two parameters over the 72 findings, using the product's `burstCapacity` |
| `eval72.mjs` | **the acceptance measurement** — the same arithmetic as the 2026-08-29 brief's `veto-eval.mjs`, three configurations in one table, plus the full parameter sweep |
| `endtoend.mjs` | genuine deliveries deleted through ALL FOUR classes, class-agnostic, so class 4 cannot delete a retake behind class 1's back |
| `siblings.mjs` | can the deletion detector or the word-density instrument see a short retake the loop class destroyed? |
| `insertion-baseline.mjs` | what the shipped insertion class finds on the captured artifact, and which markers are suspect |
| `insertion-probe.mjs` | cuts and decodes all 57 suspect segments in isolation, through the product's `cutSpan` / `transcribeClips` |
| `insertion-rescore.mjs` | re-scores those 114 decodes under three candidate strip rules, so the rule is chosen by measurement |
| `insertion-control.mjs` | the false-positive control: the speaker's GENUINE spoken list, probed the same way |

## `measurements/`

Every table the brief cites, as the tools printed it.
