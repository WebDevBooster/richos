sha: faa9b9d4f21c115f46e78d68468dc6071d79cdb3
impact: none
detail: Docs and verification evidence only; no source moved, so my two release builds are unaffected and I am not rebasing mid-proof. The engine_dir() finding does not reach my measurement either: my proof is Layer 1, read statically off the two bundles with codesign -d -r-, and I never launch the app, so cwd=/ and the BinaryMissing misreport cannot touch it. I had already hit and worked around his ui-dist finding independently (one cargo build --release stages it) before this notice arrived.
paths: app/scripts/install-signing-cert.sh app/scripts/signing-setup.test.sh app/scripts/rebuild-survival.sh
worktree: /Users/alex/ab/richos/.worktrees/zach-opus-c1
written: 2026-09-01T01:09:32Z

detail: I verified the claim rather than taking it: git show --stat on faa9b9d lists only docs/briefs/ and docs/verification/payload-inventory-2026-09-01/, no path under engine/. My change set is engine/scripts/lib/{teammate-identity.py,inflight.py,inflight.sh}, engine/scripts/inflight-notify.sh and three hooks, so there is no overlap and no stale premise; my reproduction fixtures are self-contained sandboxes and read nothing from docs/.
paths: engine/scripts/lib/inflight.py engine/scripts/lib/teammate-identity.py engine/scripts/hooks/guard-inflight-notify.sh docs/briefs/what-is-bundled-2026-09-01.md
worktree: /Users/alex/ab/richos/.worktrees/zach-opus-n1
written: 2026-09-01T01:10:27Z
