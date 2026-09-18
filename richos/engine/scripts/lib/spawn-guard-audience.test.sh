#!/usr/bin/env bash
# Wrapper so run-all-tests.sh, which discovers *.test.sh from disk, finds it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$HERE/spawn-guard-audience.test.py" "$@"
