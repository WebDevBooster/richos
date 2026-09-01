#!/usr/bin/env bash
# E2: can the claude binary ship INSIDE the .app WITHOUT being re-signed
#     (i.e. without being "modified")? And does the assembled bundle RUN?
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
BUILT="/Users/alex/ab/richos/.worktrees/echo-opus-p1/app/src-tauri/target/release/bundle/macos/RichOS.app"
STAGE="$SCRATCH/stage"
apparent() { find "$1" -type f -exec stat -f '%z' {} \; | awk '{s+=$1} END {printf "%d", s}'; }

echo "############ E2 — pristine Anthropic binary, only the OUTER bundle re-signed ############"
rm -rf "$STAGE/RichOS-claude-pristine.app"
cp -R "$BUILT" "$STAGE/RichOS-claude-pristine.app"
cp "$SCRATCH/claude-dl/claude.raw" "$STAGE/RichOS-claude-pristine.app/Contents/Resources/claude"
chmod +x "$STAGE/RichOS-claude-pristine.app/Contents/Resources/claude"
codesign --force --sign - "$STAGE/RichOS-claude-pristine.app" 2>&1 | tail -1
echo "-- nested binary's signature after outer-only signing:"
codesign -dvvv "$STAGE/RichOS-claude-pristine.app/Contents/Resources/claude" 2>&1 | grep -E 'Authority=Developer ID Application|TeamIdentifier|Signature='
echo "-- codesign --verify --deep --strict on the bundle:"
codesign --verify --deep --strict --verbose=2 "$STAGE/RichOS-claude-pristine.app" 2>&1 | tail -4
echo "verify exit = $?"
echo "-- does the bundle's shasum of the nested binary still match Anthropic's manifest?"
shasum -a 256 "$STAGE/RichOS-claude-pristine.app/Contents/Resources/claude"
echo "   manifest: b661c6a094fcc32656bf7c0071c5b45bf900b34d4f0a1ab3d78fd59aeba2c2c7"
echo "on-disk apparent bytes: $(apparent "$STAGE/RichOS-claude-pristine.app")"
cd "$STAGE"
tar -cf "$STAGE/RichOS-claude-pristine.app.tar" RichOS-claude-pristine.app
gzip -9 -k -f "$STAGE/RichOS-claude-pristine.app.tar"
echo "tar=$(stat -f '%z' "$STAGE/RichOS-claude-pristine.app.tar")  tar.gz=$(stat -f '%z' "$STAGE/RichOS-claude-pristine.app.tar.gz")"
