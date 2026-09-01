sha: 8a9ebcc028bff226afdc3de6efd8d5b12255baa2
impact: conflict
detail: It edits loro.rs, reprime.rs and app/README.md, which are three files I have open changes in — my lane-map work rewrote the LaneMap doc block and added CorpusLanes right where the ceo-layer prose sweep landed, so I will hit a real conflict in loro.rs and I am merging main before writing another line. It also invalidates the premise I had already measured around: I was preparing to do this rename myself in app/ui/mock.js and belief_trigger_tests.rs, and that work is now duplicate and must be dropped rather than re-applied. The 1.4.0 wire change matters to me directly: my new CorpusLanes deserializes the corpus summary, not the slice, so it reads companies/retiredCompanies and touches no lane field and no schemaVersion, and I am not bumping SUPPORTED_SLICE_SCHEMA.
paths: app/crates/richos-core/src/loro.rs app/crates/richos-core/src/reprime.rs app/README.md app/crates/richos-core/tests/belief_trigger_tests.rs
worktree: /Users/alex/ab/richos-wt/echo-opus-lr1
written: 2026-09-01T13:03:37Z
