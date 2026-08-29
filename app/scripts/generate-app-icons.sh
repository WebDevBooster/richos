#!/usr/bin/env bash
# Generate the whole RichOS app-icon set from ONE piece of source artwork.
#
#   app/scripts/generate-app-icons.sh ~/Desktop/richos-icon.png
#
# Everything it produces is derived from `app/src-tauri/tauri.conf.json`'s
# `bundle.icon` array — Tauri's own list of what gets bundled — so adding a size
# there is picked up here automatically, with no list to keep in sync by hand.
#
# Tool: Pillow (SPDX MIT-CMU) for decode/resample/PNG/ICO, plus Apple's own
# /usr/bin/iconutil for the macOS .icns. Neither is linked into or shipped inside
# the signed .app; both run at authoring time only. See app/scripts/lib/app_icons.py
# for the full licence and layer-coverage reasoning.
#
# Exit codes: 0 success, 1 output failed verification, 2 the source artwork was
# rejected (with the precise reason), 3 a prerequisite is missing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found on PATH. Install Python 3.9+ and re-run." >&2
  exit 3
fi

if ! python3 -c "import PIL" >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: Pillow is not installed for this python3.

  python3 -m pip install --upgrade Pillow

Pillow is SPDX MIT-CMU (permissive, no copyleft). It is an authoring-time tool
only — nothing from it is linked into or shipped inside the signed .app.
MSG
  exit 3
fi

exec python3 "$here/lib/app_icons.py" generate "$@"
