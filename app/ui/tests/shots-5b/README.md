# The correction desk, in twelve states

The first visual record of RICH-TODOs row 5b being closed: fourteen Tauri commands that had
no caller in `app/ui/`, and what the CEO now sees instead.

Produced by `node corrections.js` (see `../README.md`), out of WebKit's own compositor — the
engine Tauri ships on macOS — at 1400x950. **Not** by `screencapture`, which on this machine
returns a valid, several-kilobyte, single-colour (0,0,0) PNG because the display is locked.
Every file below was decoded and pixel-counted in the browser that painted it before it was
allowed to count as evidence; a shot with fewer than 8 distinct colours throws.

**Each one is taken 300ms after the state settles.** `.overlay-panel` fades in over 160ms,
and the first shot taken while building this pass came out as a dimmed page with no panel on
it at all — a photograph of an animation, which would have been filed as evidence of a broken
surface. That is why `settledShot` exists rather than a bare `page.screenshot`.

Re-running the suite overwrites all twelve. They are committed — unlike `.shots/`, which is
the per-run scratch every suite writes and gitignores — because "the CEO can see what loro
believes is wrong and confirm or decline it with the mouse" is a claim that should be
checkable without running anything. **They are not byte-stable across runs and are not
claimed to be**; read the suite's exit code, not a diff over a PNG.

| File | The state | What it is evidence of |
|---|---|---|
| `5b-02-two-asks-waiting.png` | The desk as he first meets it | One loro proposal and one spoken candidate, each with §7's three answers. The loro card carries the writer's own `--dry-run` bytes — the suite asserts they are byte-identical to what `loro_pending_corrections` returned, so what he approves is what would land. |
| `5b-03-loro-confirmed.png` | After `Yes, that's right` | The desk moved `prop-1` from `awaiting-ceo` to `written` and the card left the list. Nothing was written before the click; the check asserts the before-state too. |
| `5b-05-loro-suppressed.png` | After `Never ask about this record` | §7's third outcome, and the half a list-only implementation would miss: the ref is **on screen** under `Never ask again` with `Ask about this again` beside it. The badge fell 2 → 1. |
| `5b-05-spoken-suppressed.png` | The same, for a word | `deep gram\|Deepgram` on the spoken suppression list, liftable. |
| `5b-06-both-desks-absent.png` | `loro_available` and `spoken_corrections_available` both false | **The state this pass exists to get right.** Each family states the BACKEND's own sentence about this install, verbatim, plus who can change it — and neither renders an empty list, because "no corpus is configured" and "nothing is waiting on you" are different facts and only one is good news. |
| `5b-06b-answered-and-empty.png` | Both desks present, everything answered | The positive probe for the shot above. Now the empty lines DO render and no reason is stated, because there is none. Without this pair, the absent check would pass on a page where nothing renders at all. |
| `5b-06c-read-failed.png` | The desk is there and did not answer | The third state, and deliberately not the second: transient, so the reason renders with a `Try again` beside it. This is also where an unresolved entity lands — `loro_pending_corrections` resolves the entity before it touches the desk. |
| `5b-06d-read-failed-recovered.png` | After `Try again` | The retry really re-reads: the proposal is back and the failure block is gone. |
| `5b-07-refusal-on-screen.png` | `spoken_confirm_correction` with no vocabulary backend | The refusal is on the screen, in the backend's own words, and the candidate is still answerable — nothing was consumed. The suite also asserts the page logged no console error, which is the same rule `affordances.js` enforces. |
| `5b-07b-write-refused.png` | He said yes and the writer refused (exit 5) | The one outcome that would make him stop correcting things: a confirm reported as success when nothing wrote. The desk records `failed`, the surface says nothing changed, and the writer's own sentence — *"that is a PROSE section — edit the page"* — is relayed in full, because it is an instruction to him and a paraphrase would lose the path he needs. |
| `5b-08-record-and-preview.png` | `Show me what's on record now` | What loro believes NOW, above what would replace it. Reading is not correcting, so it takes no proposal and answers nothing — the proposal is still `awaiting-ceo` after this. |
| `5b-11-twelve-asks-one-column.png` | Twelve asks | No pagination, ever. Twelve cards in the DOM at once, one scrolling column, zero page controls — asserted, not eyeballed. |
