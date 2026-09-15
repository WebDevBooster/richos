#!/usr/bin/env bash
# PreToolUse input transformer. Preserves host permissions; never auto-approves.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/shell-evidence.py" ]; then
    exec python3 "$SCRIPT_DIR/shell-evidence.py"
fi
printf '%s\n' '{"systemMessage":"Shell evidence hook is unavailable; command failure propagation is unverified."}'
