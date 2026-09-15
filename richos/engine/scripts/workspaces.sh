#!/usr/bin/env bash
# Compatibility entry point. Mega Lander owns the implementation.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../mega-lander/workspaces.sh" "$@"
