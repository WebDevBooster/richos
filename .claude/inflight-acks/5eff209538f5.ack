sha: 5eff209538f58aaff362efad84a94c0fc71f0554
impact: none
detail: Neither signing item touched my runs: I invoked app/scripts/package-app.sh on its DEFAULT ad-hoc path four times (no --sign developer-id, no --verify-only), so the Entitlements.plist double-hyphen and the ^# designated-requirement parser bug at 331/912/949 were both off my path, and my A/B rebuild reproduced cdhash a2feb8c7 byte-identically either side of the swap. My changes are app/src-tauri/src/{main.rs,engine.rs} and app/crates/richos-core/src/native.rs, which the merge left untouched, so no rebase and no conflict.
paths: app/src-tauri/src/main.rs app/src-tauri/src/engine.rs app/crates/richos-core/src/native.rs
worktree: /Users/alex/ab/richos/.worktrees/echo-opus-d1
written: 2026-09-01T01:28:12Z
