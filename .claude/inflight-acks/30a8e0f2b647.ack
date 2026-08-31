sha: 30a8e0f2b64766f476e79fb1cd410abd5109674a
impact: grew-scope
detail: Scope grew and the order flipped. I sized this task as one Stop-hook notice; it is now that PLUS an extension to guard-unresolved-claims.py, and the extension lands FIRST because that hook is already registered so its content goes live on merge while a new registration is inert until next session. My assumption that all four of my deliverables were equally urgent is wrong: the claim-guard half is today's protection and the notice is tomorrow's. I am landing them as separate commits and reporting the measured precision before deciding block versus report.
paths: engine/scripts/hooks/guard-unresolved-claims.py engine/scripts/hooks/guard-unresolved-claims.sh engine/scripts/hooks/guard-unresolved-claims.test.sh
worktree: /Users/alex/ab/richos-wt/zach-idlerows-2026-08-31
written: 2026-08-31T15:58:58Z
