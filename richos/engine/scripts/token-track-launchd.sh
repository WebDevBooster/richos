#!/usr/bin/env bash
# Runs `token-track.py sample` once a minute for both signed-in accounts, as a per-user launchd agent
# (no session needed; starts again at login/reboot).
#   token-track-launchd.sh install   |   token-track-launchd.sh remove
# The agent runs the token-track.py next to this script; reinstall after the script moves.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label=com.richos.token-track
plist="$HOME/Library/LaunchAgents/$label.plist"
work="${TESTVM_WORK_HOST_FOLDER:-$HOME/Library/Application Support/com.richos.app/claude-accounts/2}"
case "${1:-}" in
install)
  mkdir -p "$HOME/.claude/state/token-track"
  python3 - "$plist" "$label" "$here/token-track.py" "$HOME/.claude" "$work" "$HOME/.claude/state/token-track/launchd.log" <<'PY'
import getpass, plistlib, sys
plist, label, script, first, work, log = sys.argv[1:]
d = {"Label": label,
     "ProgramArguments": ["/usr/bin/python3", script, "sample", "--account", "default=" + first, "--account", "work=" + work],
     "EnvironmentVariables": {"PATH": "/Users/%s/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" % getpass.getuser()},
     "StartInterval": 60, "RunAtLoad": True, "StandardOutPath": log, "StandardErrorPath": log}
plistlib.dump(d, open(plist, "wb"))
PY
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  echo "installed $label (every 60 s, log ~/.claude/state/token-track/launchd.log)" ;;
remove)
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  echo "removed $label" ;;
*) echo "usage: $0 install|remove" >&2; exit 2 ;;
esac
