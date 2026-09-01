sha: 7a71b0b7c0369d96208193d014513fe649612c70
impact: grew-scope
detail: Merged main into my branch as a23b284 and re-ran everything against the merged tree: 102 passed / 0 failed, demo.sh 7/7, inflight-notify 58/58. The new teammate-identity.py did NOT get caught by my check, and that is a real limit rather than a pass. My check is behavioral, not derived: it starts every registered hook and reports the ones that announce a missing file. inflight.sh and inflight.py do not refuse without teammate-identity.py, they degrade silently to no teams directory and no names, so every hook starts and the sandbox still models a different engine. I carried the file into both lists by hand and wrote the boundary into sandbox-completeness.sh, because a green check that a reader mistakes for completeness is the same silent gap wearing a new badge.
paths: engine/scripts/hooks/contract-integrity.test.sh engine/scripts/demo.sh engine/scripts/lib/sandbox-completeness.sh engine/scripts/lib/teammate-identity.py
worktree: /Users/alex/ab/richos/.worktrees/zach-opus-m1
written: 2026-09-01T01:59:54Z

impact: none
detail: It unblocks me rather than changing my work: publication-completeness.sh refused my first commit on the nine pre-existing ACP-citation findings, and 3ee44f5 is exactly that repair, so I merge 7a71b0b in and commit. No app/crates, app/src-tauri or app/ui source moved, so my 569 core / 28 src-tauri baselines and my config.rs edit stand untouched; I re-run both counts against the merged tree anyway rather than assume it.
paths: app/crates/richos-core/src/config.rs app/src-tauri/src/main.rs app/ui/main.js
worktree: /Users/alex/ab/richos/.worktrees/echo-opus-e1
written: 2026-09-01T01:45:30Z
