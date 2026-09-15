#!/usr/bin/env bash
# Actual isolated Git, native-attribution and hook exit/receipt controls.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$SCRIPT_DIR/../lib/completion-proof.test.py"
