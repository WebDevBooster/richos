#!/usr/bin/env bash
# run-tests: inputs richos/app richos/web richos/engine/scripts richos/engine/orchestration.config
# run-tests: covers richos/app/scripts/lint/driver.py richos/app/scripts/lint/common.py richos/app/scripts/lint/rust.py richos/app/scripts/lint/ratchet.py richos/app/scripts/lint/dialect.py richos/app/scripts/lint/process_rules.py richos/app/scripts/lint/shell_source.py richos/app/scripts/lint/timeout_rules.py richos/app/scripts/lint/suite_rules.py richos/app/scripts/lint/advisory_rules.py
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s "$DIR/lint" -p 'test_*.py'
bash "$DIR/lint.sh" --fast
echo '  PASS  unconditional Tauri fixtures and Rust/shell fast ratchets'
