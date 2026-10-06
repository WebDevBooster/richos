#!/usr/bin/env bash
# PreToolUse[Agent] input transformer. Never blocks, never approves.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/strip-ack-lines.py" ]; then
    exec python3 "$SCRIPT_DIR/strip-ack-lines.py"
fi
exit 0
