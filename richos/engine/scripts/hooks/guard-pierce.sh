#!/usr/bin/env bash
# Only real Agent dispatches run the semantic inspection, not spawn.sh's dry runs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/../lib/pierce.py"
