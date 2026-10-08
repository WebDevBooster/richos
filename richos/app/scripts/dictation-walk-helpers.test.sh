#!/usr/bin/env bash
# Prove the dictation walk's two guest helpers (src-tauri/examples/post_key.rs and key_probe.rs):
# the brightness-down post_key sends is exactly the event the tool's key match reads as F1
# (richos_voice::dictation::judge_key), and key_probe reports F1 and F13 and no other key.
# testvm/dictation-walk.py runs both in the guest; this test posts nothing and creates no tap.
# run-tests: no-host-screen: the helpers' own tests; nothing is posted, no tap is created and nothing opens
# run-tests: inputs richos/app/scripts/dictation-walk-helpers.test.sh richos/app/src-tauri/examples/post_key.rs richos/app/src-tauri/examples/key_probe.rs richos/app/crates/richos-voice/src/dictation.rs richos/app/src-tauri/Cargo.toml richos/app/src-tauri/Cargo.lock
# run-tests: covers richos/app/src-tauri/examples/post_key.rs richos/app/src-tauri/examples/key_probe.rs
set -euo pipefail
cd "$(dirname "$0")/../src-tauri"
cargo test --example post_key --example key_probe
