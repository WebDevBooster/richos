# §26's nine screenshots

The first visual record this UI has ever had.

Produced by `node memory-strategy.js` (see `../README.md`), out of WebKit's own compositor —
the engine Tauri ships on macOS — at 1440x960, full page. **Not** by `screencapture`, which
on this machine has returned a valid, several-kilobyte, single-colour (0,0,0) PNG for three
slices running because the display is locked. Every file below was decoded and pixel-counted
before it was allowed to count as evidence; a shot with fewer than 8 distinct colours throws.

Re-running the suite overwrites all nine. They are committed — unlike `.shots/`, which is the
per-run scratch every suite writes and gitignores — because §26 names them as deliverables.

**These PNGs are not byte-stable across runs and are not claimed to be.** The fixture's
determinism is asserted where it means something — the projected snapshot is byte-identical
JSON across three constructions from one anchor, and the measured duration is exactly
`8_270_000 ms` every time — but a full-page capture also carries the scroll offset the shell
happened to settle at, so a re-run can differ by a few bytes without anything having changed.
Do not treat a diff here as a regression signal; read the suite's exit code.

| # | File | Distinct colours | §26 asked for | What it is |
|---|---|---|---|---|
| 1 | `ms-01-just-after-send.png` | 253 | just after send | As asked. The prompt in its quiet right-aligned bubble, clamped at §5.1's 18 lines with `Show more`, and §6.1's bare `Working` — no number invented under one second. |
| 2 | `ms-02-working-for-18s.png` | 335 | active at `Working for 18s` | As asked, and exact. Also `Read 7 files` (seven rows rolled into one summary) and `Searched`. |
| 3 | `ms-03-three-workers-active.png` | 372 | three workers active | As asked: `Sage, Frank and Clark started working`, one group, three chips. Reached through a snapshot read, because no live worker event exists — see the suite. |
| 4 | `ms-04-run-ended-with-recovery-commentary.png` | 336 | **Sage FAILED** with Rich recovery commentary | **NOT AS ASKED, DELIBERATELY.** Nothing in the worker path carries an outcome (`worker_events.rs:137-138`), so there is no failure to draw. What is drawn is what was witnessed: `Ended · outcome not recorded`, Rich's commentary saying exactly that and claiming nothing more, and a second Sage run opening below it. The clock does not reset. |
| 5 | `ms-05-worker-detail-beside-thread.png` | 407 | Sage worker detail open beside the main thread **with its file-change card visible** | **PARTLY AS ASKED.** The pane is open beside the thread, both readable, read-only. The file-change card is absent: §7.2 item 6 has no source and Phase 5 owns artifacts, so the pane says so in Rich's voice instead of showing an invented diff. |
| 6 | `ms-06-final-collapsed.png` | 375 | final response with collapsed `Worked for 2h 17m 50s` | As asked. Note all three prose runs remain outside the collapse, not just the final one — the runtime cannot tell commentary from the answer (`live.rs:120`), so no run is labelled and none is hidden. |
| 7 | `ms-07-expanded-completed-activity.png` | 396 | expanded completed activity | As asked. The chronology is restored in place, in its original order. |
| 8 | `ms-08-resized-panes.png` | 374 | resized left navigation and resized worker pane | As asked. Rail 300 → 420px, worker pane 336 → 432px, both by keyboard, both persisted (`nav_state` agrees). |
| 9 | `ms-09-restored-after-reload.png` | 327 | same thread restored after app reload | As asked, with one honest note: `mock.js` has no ledger on disk, so the durable record is re-derived from the same anchor — which the suite verifies is byte-identical. The renderer then rebuilds from `get_timeline` alone; zero live events reach that page. |
