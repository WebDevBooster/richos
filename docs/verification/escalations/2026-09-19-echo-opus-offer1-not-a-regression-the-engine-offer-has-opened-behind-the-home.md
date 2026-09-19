# Escalation: Not a regression: the engine offer has opened behind the home screen since that screen shipped -- .11 showed it by luck, and the bisect the brief prescribes has no target

- id: `esc-20260919T160449Z-296b5a12`
- raised: 2026-09-19T16:04:49Z
- from: echo-opus-offer1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-offer1` (branch `cc/echo-opus-offer1`)
- head: `5bd7d4e590103673a64c7e174604f204e41c0348`
- state: **work-complete**
- for: lead

## The question

Candidate .11's audit line "The offer appears on entry" should be read as luck rather than as a working feature -- do you want that correction carried into the .15 audit and the open-items record, or left as it stands?

## What was already tried

Re-derived the brief's premise before building to it. A diff of 4f952322 against dcebed09 over richos-core/src/setup.rs, src-tauri/src/setup_view.rs, src-tauri/src/engine.rs and ui/home.js is EMPTY -- all four byte-identical -- and main.js's diff has no hunk inside init(). None of the four commits the brief names (f4067f43, a9637e03, d00fbb19, 2d11ecc1) touches the offer path, so a bisect between the two sources would have had no target. Ray's own app.log confirms the back end was right throughout ("first-run setup: the RichOS engine is NOT installed", "this build installs engine 1.2.0") and that the longest spine wait in the whole log is 30 ms, so nothing hung either. MEASURED CAUSE: the offer opens INSIDE #app at z-index 60, under the home screen's 150 and under the opening curtain's 200, with #app inert and focus pulled to the door -- present in the DOM, and nowhere a person can see, press or focus it. home.js's give-way derived "a desk sheet" as a direct child of body carrying .overlay, which covers 4 of the document's 11 overlays and NONE of the three questions init() asks a customer. main.js's isOnScreen() tests hidden, display and visibility and never occlusion, so one Escape at either surface silently pressed "Not now" on a question never shown. All of that is equally true of .11; .11 differs only in that Ray pressed the door and the sheet was revealed, which I reproduced headless. .15 is the first build with a curtain a person can get STUCK behind (section 62's space-bar hold), so Escape is newly the obvious key to press -- I cannot prove which key he pressed and am not claiming it.

## Proceeding meanwhile

Fixed at both surfaces and landed on cc/echo-opus-offer1, 5 commits: the home screen now gives way to every desk overlay and hands it focus; Escape at the curtain takes the curtain and nothing else; and send_message's first-run arm -- dead code behind "&& !has_lease_factory()" on every build ever shipped, because the factory is always configured -- now answers a stale engine with the offer instead of "I lost my connection to the part of me that thinks". setup.js 20/20 (128 assertions, was 117), richos-core 1370 passed, --bin richos-tauri 322 passed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260919T160449Z-296b5a12`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260919T160449Z-296b5a12 --disposition "<what you decided or did>"
