#!/usr/bin/env bash
# Assemble each live placement as a REAL bundle, sign it, RUN it, and measure it.
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
BUILT="/Users/alex/ab/richos/.worktrees/echo-opus-p1/app/src-tauri/target/release/bundle/macos/RichOS.app"
STAGE="$SCRATCH/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"

apparent() { find "$1" -type f -exec stat -f '%z' {} \; | awk '{s+=$1} END {printf "%d", s}'; }

echo "############ OPTION 1/D — ship nothing extra ############"
cp -R "$BUILT" "$STAGE/RichOS-nothing-extra.app"
codesign --force --sign - --timestamp=none "$STAGE/RichOS-nothing-extra.app" 2>&1 | tail -1
echo "on-disk apparent bytes: $(apparent "$STAGE/RichOS-nothing-extra.app")"

echo "############ OPTION E — ship the claude binary inside the .app ############"
cp -R "$BUILT" "$STAGE/RichOS-with-claude.app"
mkdir -p "$STAGE/RichOS-with-claude.app/Contents/Resources"
cp "$SCRATCH/claude-dl/claude.raw" "$STAGE/RichOS-with-claude.app/Contents/Resources/claude"
chmod +x "$STAGE/RichOS-with-claude.app/Contents/Resources/claude"
echo "-- Anthropic's signature on the copy, BEFORE we touch it:"
codesign -dvvv "$STAGE/RichOS-with-claude.app/Contents/Resources/claude" 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier|flags='
echo "-- signing inside-out (nested first, then the bundle):"
codesign --force --sign - --options runtime "$STAGE/RichOS-with-claude.app/Contents/Resources/claude" 2>&1 | tail -1
codesign --force --sign - "$STAGE/RichOS-with-claude.app" 2>&1 | tail -1
echo "-- Anthropic's signature AFTER we re-signed it:"
codesign -dvvv "$STAGE/RichOS-with-claude.app/Contents/Resources/claude" 2>&1 | grep -E 'Authority|TeamIdentifier|Signature='
codesign --verify --deep --strict "$STAGE/RichOS-with-claude.app" && echo "bundle verifies OK" || echo "bundle FAILED verification"
echo "on-disk apparent bytes: $(apparent "$STAGE/RichOS-with-claude.app")"

echo "############ compressed (gzip -9 over a deterministic tar) ############"
cd "$STAGE"
for a in RichOS-nothing-extra.app RichOS-with-claude.app; do
  tar --no-mac-metadata -cf "$STAGE/$a.tar" "$a" 2>/dev/null || tar -cf "$STAGE/$a.tar" "$a"
  gzip -9 -k -f "$STAGE/$a.tar"
  echo "$a  tar=$(stat -f '%z' "$STAGE/$a.tar")  tar.gz=$(stat -f '%z' "$STAGE/$a.tar.gz")"
done
