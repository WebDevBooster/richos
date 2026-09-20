#!/usr/bin/env bash
# run-tests: inputs richos/app richos/web richos/engine/scripts richos/engine/orchestration.config .cargo rust-toolchain rust-toolchain.toml
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s "$DIR/lint" -p 'test_*.py'
bash "$DIR/lint.sh" --fast
echo '  PASS  unconditional Tauri fixtures and Rust/shell fast ratchets'
