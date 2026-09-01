#!/usr/bin/env bash
# Measure EXACTLY what Anthropic's own installer would fetch on this Mac.
# Downloads into a scratch dir. Installs nothing. Touches ~/.local/share/claude never.
set -uo pipefail
OUT=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad/claude-dl
mkdir -p "$OUT"
BASE="https://downloads.claude.ai/claude-code-releases"
platform="darwin-arm64"

version=$(curl -fsSL "$BASE/latest")
echo "latest version = $version"
curl -fsSL "$BASE/$version/manifest.json"     -o "$OUT/manifest.json"
curl -fsSL "$BASE/$version/manifest.zst.json" -o "$OUT/manifest.zst.json"
echo "--- manifest.json ($platform) ---"
python3 -c "import json,sys; d=json.load(open('$OUT/manifest.json')); print(json.dumps(d['platforms']['$platform'], indent=2))"
echo "--- manifest.zst.json ($platform) ---"
python3 -c "import json,sys; d=json.load(open('$OUT/manifest.zst.json')); print(json.dumps(d['platforms']['$platform'], indent=2))"

echo "--- HEAD: raw binary ---"
curl -fsSLI "$BASE/$version/$platform/claude" | grep -iE '^(content-length|content-type)'
echo "--- HEAD: zstd binary ---"
curl -fsSLI "$BASE/$version/$platform/claude.zst" | grep -iE '^(content-length|content-type)'

echo "--- downloading claude.zst (what the installer actually fetches when zstd is present) ---"
curl -fsSL "$BASE/$version/$platform/claude.zst" -o "$OUT/claude.zst"
stat -f '%z %N' "$OUT/claude.zst"
shasum -a 256 "$OUT/claude.zst"

echo "--- downloading claude (the fallback path, no zstd) ---"
curl -fsSL "$BASE/$version/$platform/claude" -o "$OUT/claude.raw"
stat -f '%z %N' "$OUT/claude.raw"
shasum -a 256 "$OUT/claude.raw"

echo "--- is zstd on a stock macOS? ---"
PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v zstd || echo "zstd: NOT on a stock macOS PATH"
PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v jq   || echo "jq: NOT on a stock macOS PATH"
PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v curl || echo "curl: NOT on a stock macOS PATH"
