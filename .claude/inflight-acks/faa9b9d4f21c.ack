sha: faa9b9d4f21c115f46e78d68468dc6071d79cdb3
impact: none
detail: I verified the claim rather than taking it: git show --stat on faa9b9d lists only docs/briefs/ and docs/verification/payload-inventory-2026-09-01/, no path under engine/. My change set is engine/scripts/lib/{teammate-identity.py,inflight.py,inflight.sh}, engine/scripts/inflight-notify.sh and three hooks, so there is no overlap and no stale premise; my reproduction fixtures are self-contained sandboxes and read nothing from docs/.
paths: engine/scripts/lib/inflight.py engine/scripts/lib/teammate-identity.py engine/scripts/hooks/guard-inflight-notify.sh docs/briefs/what-is-bundled-2026-09-01.md
worktree: /Users/alex/ab/richos/.worktrees/zach-opus-n1
written: 2026-09-01T01:10:27Z
