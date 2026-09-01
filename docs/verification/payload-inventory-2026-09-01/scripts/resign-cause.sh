#!/usr/bin/env bash
set -uo pipefail
SCRATCH=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
RESIGNED="$SCRATCH/stage/RichOS-with-claude.app/Contents/Resources/claude"
PRISTINE="$SCRATCH/stage/RichOS-claude-pristine.app/Contents/Resources/claude"
mkdir -p "$SCRATCH/fake-engine"
cd "$SCRATCH/fake-engine"

echo "=== entitlements: PRISTINE ==="
codesign -d --entitlements - "$PRISTINE" 2>&1 | grep -E 'Key\]|Bool\]' | head -20
echo "=== entitlements: RE-SIGNED ==="
codesign -d --entitlements - "$RESIGNED" 2>&1 | head -6

echo "=== a REAL turn through the PRISTINE bundled binary ==="
echo "Reply with exactly: PRISTINE-OK" | "$PRISTINE" -p --output-format text 2>&1 | tail -3
echo "exit=$?"

echo "=== a REAL turn through the RE-SIGNED bundled binary ==="
echo "Reply with exactly: RESIGNED-OK" | "$RESIGNED" -p --output-format text 2>&1 | tail -5
echo "exit=$?"
