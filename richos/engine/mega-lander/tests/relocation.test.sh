#!/usr/bin/env bash
# Exercise the feature in an engine copy, including legacy imports and commands.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$HERE/relocation.test.py"
