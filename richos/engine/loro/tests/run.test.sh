#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$HERE/run.js"
node "$HERE/relocation.js"
node "$HERE/write-boundary.js"
node "$HERE/read-boundary.js"
