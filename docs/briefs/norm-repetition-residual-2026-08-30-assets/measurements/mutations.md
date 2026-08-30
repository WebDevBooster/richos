| # | mutation applied to the shipped source | suite | result | first check to go red |
|---|---|---|---|---|
| 1 | class-1: the 3-word veto floor put back (minWordsForBurstVeto 1 -> 3) | `test/run.js` | 1 check(s) RED | a SHORT repeated phrase is clamped to what the audio holds — the 2026-08-30 residual, closed |
| 2 | class-1: the keep floor lowered below one delivery (max(1, ...) -> max(0, ...)) | `test/run.js` | 7 check(s) RED | the guard collapses the real large-v3 4x repetition loop to a single line |
| 3 | class-2: an EMPTY isolated decode counted as proof of fabrication | `test/run.js` | 3 check(s) RED | a marker is only ever stripped on POSITIVE, agreeing evidence from both paddings |
| 4 | class-2: the numeral matched in DIGIT form only | `test/run.js` | 5 check(s) RED | numeralInText reads a numeral in EITHER form, anywhere, and says "empty" rather than "absent" |
| 5 | class-2: the numeral test anchored to the HEAD of the clip | `test/run.js` | 3 check(s) RED | numeralInText reads a numeral in EITHER form, anywhere, and says "empty" rather than "absent" |
| 6 | class-2: 'spoken' requires BOTH paddings to recover the numeral, not either | `test/run.js` | 1 check(s) RED | a marker is only ever stripped on POSITIVE, agreeing evidence from both paddings |
| 7 | class-2: a thrown probe no longer falls back to detect-only | `test/run.js` | the suite CRASHED (the guard is load-bearing) | — |
| 8 | class-2: the per-channel probe budget removed | `test/run.js` | 1 check(s) RED | the probe BUDGET caps the decodes and the markers past it stay in the text, named |
| 9 | class-2: the channel name no longer reaches the probe | `test/run.js` | 1 check(s) RED | the insertion probe is routed PER CHANNEL — it is told which wav to cut |
| 10 | class-2: the KEPT-because-spoken warning dropped from verification.json | `test/run.js` | 1 check(s) RED | a repaired insertion says what it removed AND what it left, and the two never merge |
| 11 | class-2: unadjudicated markers no longer warned about | `test/run.js` | 1 check(s) RED | an insertion NOTHING adjudicated warns that it was not adjudicated — never that it was clean |
| 12 | class-3: the hand-off removed — the stutter class may collapse what class 1 preserved | `test/run.js` | 2 check(s) RED | class 3 does NOT collapse the deliveries class 1 preserved on the audio |
| 13 | class-3: the hand-off widened to any segment touching a protected span | `test/run.js` | 1 check(s) RED | the hand-off is scoped to the protected span — a real stutter outside one is still caught |
| 14 | class-1 -> class-3 hand-off: only PRESERVED runs handed over, not clamped ones | `test/run.js` | 1 check(s) RED | a CLAMPED run is handed over too, not only a fully preserved one |
| 15 | pipeline: stage 3.5 no longer passes a probe to the guard at all | `test/e2e.mjs` | 1 check(s) RED | the insertion class was wired with a way to REPAIR, not only to detect |
| 16 | pipeline: the wiring flag hard-coded instead of read back from the guard | `test/e2e.mjs` | GREEN — mutant SURVIVED | — |
| 17 | guard: the report claims a probe reached it when none did | `test/run.js` | 1 check(s) RED | the report says whether a probe REACHED the guard — "detect-only" and "clean" never merge |
