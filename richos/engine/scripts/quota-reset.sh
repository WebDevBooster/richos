#!/usr/bin/env bash
# User: status | approve <offer-id> | revoke. Watcher: tick (never approves).
# Uses the desktop's service and data directory even when the UI is not running.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PRODUCT="$(cd "$HERE/../.." && pwd)"
if [ -f "$PRODUCT/app/Cargo.toml" ]; then
  CARGO="$(command -v cargo || true)"
  [ -n "$CARGO" ] || CARGO="$HOME/.cargo/bin/cargo"
  exec "$CARGO" run --quiet --manifest-path "$PRODUCT/app/Cargo.toml" -p richos-core --bin richos-quota -- "$@"
fi
for binary in "$HERE/../bin/richos-quota" "$HOME/Applications/RichOS.app/Contents/MacOS/richos-tauri" /Applications/RichOS.app/Contents/MacOS/richos-tauri; do
  if [ -x "$binary" ]; then
    case "$binary" in
      */richos-tauri)
        # Inspect before executing: an older app may open its GUI for an unknown flag.
        /usr/bin/grep -aFq -- '--richos-quota-v1' "$binary" || continue
        exec "$binary" --richos-quota-v1 "$@";;
      *) exec "$binary" "$@";;
    esac
  fi
done
echo 'The quota helper is unavailable. Install a RichOS version with terminal quota support, or run this from the source checkout with Cargo installed.' >&2
exit 2
