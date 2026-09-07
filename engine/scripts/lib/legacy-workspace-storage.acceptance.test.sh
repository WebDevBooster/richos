#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
exec python3 -I -S -B legacy-workspace-storage.acceptance.test.py
