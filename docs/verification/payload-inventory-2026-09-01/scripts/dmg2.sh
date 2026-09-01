#!/usr/bin/env bash
# The number a customer actually downloads: a compressed (UDZO) disk image.
# tauri's own bundle_dmg.sh failed on this machine; hdiutil is the same primitive
# it drives, run directly so the failure of a cosmetic layout step cannot hide the size.
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
STAGE="$SCRATCH/stage"
OUT="$SCRATCH/dmg"
rm -rf "$OUT"; mkdir -p "$OUT"

make_dmg() {
  name="$1"; app="$2"
  src="$OUT/src-$name"; rm -rf "$src"; mkdir -p "$src"
  cp -R "$app" "$src/"
  hdiutil create -quiet -srcfolder "$src" -volname "RichOS" -format UDZO -imagekey zlib-level=9 -ov "$OUT/$name.dmg"
  rc=$?
  if [ $rc -ne 0 ]; then echo "$name: hdiutil FAILED rc=$rc"; return; fi
  echo "$name.dmg = $(stat -f '%z' "$OUT/$name.dmg") bytes"
  echo "  stapler on the dmg: $(xcrun stapler validate "$OUT/$name.dmg" 2>&1 | tail -1)"
}

make_dmg "richos-nothing-extra"    "$STAGE/RichOS-nothing-extra.app"
make_dmg "richos-with-claude"      "$STAGE/RichOS-claude-pristine.app"
