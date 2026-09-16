#!/bin/sh
# RichOS native-messaging host installer (macOS / Linux).
#
#   ./install-host.sh <chrome-extension-id> [--uninstall]
#
# Registers com.richos.host so the RichOS extension can `chrome.runtime.connectNative` to the local
# service. Writes a launcher with absolute node + host-script paths, then drops the host manifest
# into every Chromium-family NativeMessagingHosts directory found on this machine. No network, no
# elevated privileges, no listening port — the host starts and dies with the browser.
#
# Windows registration (a registry key under HKCU\Software\Google\Chrome\NativeMessagingHosts) is a
# P3 packaging concern; the .bat launcher exists so the Windows path is not blocked on shared logic.
set -eu

EXT_ID="${1:-}"
UNINSTALL=""
[ "${2:-}" = "--uninstall" ] && UNINSTALL="1"
[ "${1:-}" = "--uninstall" ] && UNINSTALL="1"

HOST_NAME="com.richos.host"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST_JS="$HERE/native-host.js"
LAUNCHER="$HERE/richos-host-launcher.sh"
NODE_BIN="$(command -v node || true)"

if [ -z "$UNINSTALL" ]; then
  [ -n "$EXT_ID" ] || { echo "usage: ./install-host.sh <chrome-extension-id> [--uninstall]" >&2; exit 1; }
  [ -n "$NODE_BIN" ] || { echo "node not found on PATH" >&2; exit 1; }
  # Generate afresh: the previous launcher may already contain paths from another install.
  "$NODE_BIN" - "$NODE_BIN" "$HOST_JS" "$HERE/.richos-host-launcher.resolved.sh" <<'JS'
const fs = require('node:fs');
const [node, host, output] = process.argv.slice(2);
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
fs.writeFileSync(output, `#!/bin/sh\nNODE_BIN=${quote(node)}\nHOST_JS=${quote(host)}\nexec "$NODE_BIN" "$HOST_JS"\n`);
JS
  mv "$HERE/.richos-host-launcher.resolved.sh" "$LAUNCHER"
  chmod +x "$LAUNCHER" "$HOST_JS"
fi

# Every Chromium-family manifest directory this OS might use.
case "$(uname -s)" in
  Darwin)
    BASES="
$HOME/Library/Application Support/Google/Chrome
$HOME/Library/Application Support/Google/Chrome Canary
$HOME/Library/Application Support/Google/Chrome for Testing
$HOME/Library/Application Support/Chromium
$HOME/Library/Application Support/BraveSoftware/Brave-Browser
$HOME/Library/Application Support/Microsoft Edge
" ;;
  *)
    BASES="
$HOME/.config/google-chrome
$HOME/.config/google-chrome-for-testing
$HOME/.config/chromium
$HOME/.config/BraveSoftware/Brave-Browser
$HOME/.config/microsoft-edge
" ;;
esac

count=0
echo "$BASES" | while IFS= read -r base; do
  [ -n "$base" ] || continue
  [ -d "$base" ] || continue
  dir="$base/NativeMessagingHosts"
  target="$dir/$HOST_NAME.json"
  if [ -n "$UNINSTALL" ]; then
    [ -f "$target" ] && { rm -f "$target"; echo "removed $target"; }
    continue
  fi
  mkdir -p "$dir"
  "$NODE_BIN" - "$HERE/com.richos.host.json" "$LAUNCHER" "$EXT_ID" "$target" <<'JS'
const fs = require('node:fs');
const [template, launcher, extensionId, output] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(template, 'utf8'));
manifest.path = launcher;
manifest.allowed_origins = [`chrome-extension://${extensionId}/`];
fs.writeFileSync(output, JSON.stringify(manifest, null, 2) + '\n');
JS
  echo "installed $target"
  count=$((count + 1))
done

[ -n "$UNINSTALL" ] && { echo "uninstalled $HOST_NAME"; exit 0; }
echo "done. host=$HOST_NAME launcher=$LAUNCHER node=$NODE_BIN"
