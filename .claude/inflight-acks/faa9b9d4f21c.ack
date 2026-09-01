sha: faa9b9d4f21c115f46e78d68468dc6071d79cdb3
impact: none
detail: Docs and verification evidence only; no source moved, so my two release builds are unaffected and I am not rebasing mid-proof. The engine_dir() finding does not reach my measurement either: my proof is Layer 1, read statically off the two bundles with codesign -d -r-, and I never launch the app, so cwd=/ and the BinaryMissing misreport cannot touch it. I had already hit and worked around his ui-dist finding independently (one cargo build --release stages it) before this notice arrived.
paths: app/scripts/install-signing-cert.sh app/scripts/signing-setup.test.sh app/scripts/rebuild-survival.sh
worktree: /Users/alex/ab/richos/.worktrees/zach-opus-c1
written: 2026-09-01T01:09:32Z
