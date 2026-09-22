#!/usr/bin/env bash
# The phone protocol conformance corpus both native apps must pass (richos/mobile/conformance).
# Two checks, no simulator, no emulator, no device, no network:
#   1. the corpus regenerates BYTE-IDENTICALLY from the reference client modules (Node, ~1 s);
#   2. every signed request in it gets the recorded verdict from the Mac's production Rust
#      verifier, compiled in a detached test crate (cargo; seconds warm, about a minute cold).
# run-tests: no-host-screen: Node and a detached Rust test crate only
# run-tests: inputs richos/app/scripts/native-conformance.test.sh richos/mobile/conformance richos/web/web-app/lib richos/mobile/core richos/mobile/platform/native.js richos/app/src-tauri/src/phone
# run-tests: covers richos/mobile/conformance/generate.mjs richos/mobile/conformance/generator/p256.mjs richos/mobile/conformance/generator/harness.mjs richos/mobile/conformance/generator/pairing.mjs richos/mobile/conformance/generator/signing.mjs richos/mobile/conformance/generator/transport.mjs richos/mobile/conformance/generator/events.mjs richos/mobile/conformance/generator/voice.mjs richos/mobile/conformance/vectors/index.json richos/mobile/conformance/vectors/keys.json richos/mobile/conformance/vectors/pairing.json richos/mobile/conformance/vectors/fingerprint.json richos/mobile/conformance/vectors/signing.json richos/mobile/conformance/vectors/challenge.json richos/mobile/conformance/vectors/retry.json richos/mobile/conformance/vectors/errors.json richos/mobile/conformance/vectors/events.json richos/mobile/conformance/vectors/voice.json richos/mobile/conformance/vectors/attachments.json richos/mobile/conformance/vectors/push-registration-fcm.json richos/mobile/conformance/verifier/Cargo.toml richos/mobile/conformance/verifier/build.rs richos/mobile/conformance/verifier/src/lib.rs richos/mobile/conformance/verifier/tests/corpus.rs
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
CONFORMANCE="$ROOT/richos/mobile/conformance"

if ! command -v node >/dev/null 2>&1; then
  echo '  NOT RUN  native-conformance: Node is unavailable'
  exit 2
fi
node "$CONFORMANCE/generate.mjs" --check

cargo_bin="$(command -v cargo || true)"
if [[ -z "$cargo_bin" && -x "$HOME/.cargo/bin/cargo" ]]; then cargo_bin="$HOME/.cargo/bin/cargo"; fi
if [[ -z "$cargo_bin" ]]; then
  echo '  NOT RUN  native-conformance: the corpus is current, but the Rust toolchain is unavailable for the Mac verifier check'
  exit 2
fi
# THE CRATE'S OWN target/ (ignored by git), NOT an inherited CARGO_TARGET_DIR. Two checkouts of
# this crate hash identically, so in one shared target directory cargo reuses the other
# checkout's build and the test proves the wrong tree (measured 2026-09-22; the test now also
# refuses that case). NATIVE_CONFORMANCE_TARGET_DIR overrides, for a caller that owns the choice.
# --locked: the pinned `ring` is the Mac's `ring`.
CARGO_TARGET_DIR="${NATIVE_CONFORMANCE_TARGET_DIR:-$CONFORMANCE/verifier/target}" \
  "$cargo_bin" test --quiet --manifest-path "$CONFORMANCE/verifier/Cargo.toml" --locked -- --nocapture
echo '  PASS  native conformance corpus current and verified by the Mac production verifier'
