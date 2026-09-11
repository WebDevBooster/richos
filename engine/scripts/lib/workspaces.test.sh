#!/usr/bin/env bash
# One test per numbered point of docs/plans/worktree-spec-2026-09-11.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/workspaces.test.py" "$@"
