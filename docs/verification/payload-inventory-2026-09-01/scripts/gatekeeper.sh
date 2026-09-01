#!/usr/bin/env bash
# The Apple constraint option D must respect: what can and cannot be verified
# about a fetched loose executable, offline.
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
RAW="$SCRATCH/claude-dl/claude.raw"
chmod +x "$RAW"

echo "=== 1. quarantine attribute after a curl download ==="
xattr -l "$RAW" || echo "(no extended attributes — curl does not set com.apple.quarantine)"

echo
echo "=== 2. codesign --verify (works offline: signature + certificate chain) ==="
codesign --verify --strict --verbose=2 "$RAW" 2>&1 | tail -3
echo "exit=$?"

echo
echo "=== 3. the designated requirement the fetched file satisfies ==="
codesign -d -r- "$RAW" 2>&1 | tail -2

echo
echo "=== 4. xcrun stapler — can a loose Mach-O carry an offline ticket? ==="
xcrun stapler validate "$RAW" 2>&1 | tail -2
echo "exit=$?"

echo
echo "=== 5. spctl assessment of the loose executable (needs the network) ==="
spctl -a -t exec -vv "$RAW" 2>&1 | tail -3
echo "exit=$?"

echo
echo "=== 6. positive/negative control: an .app CAN be stapled, its executable cannot ==="
if [ -d /Applications/Claude.app ]; then
  echo -n "  /Applications/Claude.app: "; xcrun stapler validate /Applications/Claude.app 2>&1 | tail -1
  echo -n "  its Contents/MacOS binary: "; xcrun stapler validate /Applications/Claude.app/Contents/MacOS/Claude 2>&1 | tail -1
else
  echo "  /Applications/Claude.app absent on this machine — control not run"
fi
