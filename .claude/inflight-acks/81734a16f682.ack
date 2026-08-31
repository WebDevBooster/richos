sha: 81734a16f6824ba5d3bdd091159cc8970b75c12f
impact: grew-scope
detail: Splash guard-rail + placeholder + 3s duration. Two of my assumptions move. (1) I assumed the gear popover's contents were mine to leave alone; they are not - #splash-enabled must survive my menu rebuild and stay reachable, so I now verify it explicitly rather than assuming splash.js check 11 covers reachability. (2) I had treated splash timing as untouched shipped behaviour; the 3s default must now be an explicit named constant rather than a literal in the removal path, shaped so a per-type 3-5s range is cheap to add later but NOT built now. Splash visuals stay a placeholder - I am wiring none of the 18-entry library into the theme work. Counters/ledger/milestones remain out of scope and I am adding none.
paths: app/ui/splash.js app/ui/index.html app/crates/richos-core/src/config.rs
worktree: /Users/alex/ab/richos-wt/echo-implement-2026-08-31
written: 2026-08-31T07:21:09Z
