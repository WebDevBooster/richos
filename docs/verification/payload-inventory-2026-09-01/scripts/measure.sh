#!/usr/bin/env bash
set -euo pipefail
APP="/Users/alex/ab/richos/.worktrees/echo-opus-p1/app/src-tauri/target/release/bundle/macos/RichOS.app"
echo "=== tree ==="
find "$APP" -type f -o -type l | sed "s|$APP|RichOS.app|" | sort
echo "=== per-file apparent bytes ==="
find "$APP" -type f -exec stat -f '%z %N' {} \; | sed "s|$APP|RichOS.app|" | sort -rn
echo "=== apparent byte total ==="
find "$APP" -type f -exec stat -f '%z' {} \; | awk '{s+=$1} END {printf "%d\n", s}'
