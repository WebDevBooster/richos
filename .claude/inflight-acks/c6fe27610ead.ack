sha: c6fe27610ead581d495b8c7877daeb257d051d3b
impact: conflict
detail: zach-opus-p1 wired a guard, so main now carries 39 registered scripts where my base carried 38. Three of the four inventories need no action from me and I have verified why: R_ROOTED_COUNT is derived from a LIST I appended to, BR_EXPECTED is a typed LIST whose count is derived, and Layer M's CANON is a list too - all three merge additively and re-derive. Exactly ONE hand-typed number collides: engine-status.test.sh case 1b. It is a deliberate tripwire that exists to conflict, and per the lander's instruction I am setting it to 40 (main's 39 plus my guard) rather than to 39, which makes that suite RED IN ISOLATION on my branch and green only at main-plus-this-branch. If zach-opus-l1 also wires a guard the true number is 41 and the line must be bumped again at the merge.
paths: engine/scripts/hooks/engine-status.test.sh engine/scripts/hooks/contract-integrity-probe.sh engine/hooks/hooks.json
worktree: /Users/alex/ab/richos-wt/zach-s1
written: 2026-08-31T22:37:11Z
