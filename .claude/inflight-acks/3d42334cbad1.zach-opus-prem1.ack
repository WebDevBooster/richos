sha: 3d42334cbad15811a08c530dc4ebdf11b49e01ef
impact: conflict
detail: CHANGELOG conflicts again and the new sweep imports row-currency.py parse_record and identity from my refactor; parse_record gained a THIRD optional argument premise_sections=() and warrant_of gained an optional regex argument, both defaulted, identity is untouched, so every existing call site keeps working - verified by running the importer's own suite after merging.
paths: engine/CHANGELOG.md
teammate: zach-opus-prem1
worktree: /Users/alex/ab/richos-wt/zach-opus-prem1
written: 2026-09-02T14:00:35Z
