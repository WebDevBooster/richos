sha: bd8702dcad2d91b35794de3132d17d4fe9c852c6
impact: none
detail: Splash tracking is RULED but still not mine, and it lands in config.rs which I am editing - so my job is to make config.rs landable fast and leave its schema clean, not to anticipate it. I am adding NO counters, no launch ledger, no crash detection; guessing at a written schema would be worse than leaving the gap. Two clauses do touch me and I am acting on both: I will state explicitly in my report whether my work touches crash-restore behaviour (app/ui/tests/restart-scope.js), and UTC is now checked rather than assumed - I add no new timestamp, but I verify the existing splash stamps are UTC-based epoch millis so the next pass inherits a true statement, not my guess.
paths: app/crates/richos-core/src/config.rs app/ui/tests/restart-scope.js
worktree: /Users/alex/ab/richos-wt/echo-implement-2026-08-31
written: 2026-08-31T07:21:17Z
