#!/usr/bin/env bash
# Rust and shell lint; baseline checks are read-only unless --lower is explicit.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
exec python3 "$DIR/lint/driver.py" "$@"
