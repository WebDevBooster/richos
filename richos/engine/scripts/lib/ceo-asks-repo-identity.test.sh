#!/usr/bin/env bash
# P5-51: the same row ID in two repositories is two questions; asking one must not clear the other.
# LIB_DIR overrides which copy of ceo-asks.py is tested.
set -uo pipefail
D="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
J="$(mktemp)"; trap 'rm -f "$J"' EXIT
cat >"$J" <<'J2'
{"mode":"assess","ready_state":"READY-FOR-CEO",
 "items":[{"repo":"A","id":"1.1","state":"READY-FOR-CEO","title":"a"},{"repo":"B","id":"1.1","state":"READY-FOR-CEO","title":"b"}],
 "asks":[{"matched_item":"1.1","repo":"A","discharges":true}]}
J2
OUT="$(python3 "$D/ceo-asks.py" "$J")"
if printf '%s\n' "$OUT" | grep -q $'^UNASKED\t1$' && printf '%s\n' "$OUT" | grep -q $'^ASK\tB\t1.1'; then
  echo "ok   P5-51 repo B's 1.1 stays unasked"; exit 0
fi
echo "FAIL P5-51: $OUT"; exit 1
