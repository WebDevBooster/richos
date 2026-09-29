#!/bin/bash
#
# suite-in-guest.sh — the guest's half of run-suite.sh. It runs INSIDE a test-VM guest, from
#                     the payload run-suite.sh pushed there, and never on this Mac.
#
#   bash "$HOME/run-suite/tree/richos/app/scripts/testvm/suite-in-guest.sh" <suite file name>
#
# THE PAYLOAD, as suite-walk.sh lays it out under the guest user's $HOME/run-suite:
#
#   prebuilt/                 richos-tauri and gui_boot_machine, built on the host
#   tree/richos/app/...       the scripts directory and the source files the suite reads
#   engine/                   the engine the suite provisions its machines from
#   runtime/                  the delivered runtime, when the engine carries none
#   results/                  the suite's results folder (RICHOS_TEST_RESULTS_DIR)
#   suite.rc                  written here: the suite's exit code, and nothing else
#
# WHY IT RE-ENTERS ITSELF IN THE GUI SESSION. An ssh login is its own bootstrap and security
# session, not the Aqua session the console user is logged into, and a GUI process started
# from it may find no window server. `launchctl asuser <uid>` puts the suite in the same
# context `open -a` launches the app into; keychain.sh does the same for the same reason.
# `sudo -n`: the guest image's passwordless sudo is required, and a guest without it refuses
# at once instead of waiting for a password nobody will type.
#
# THE ENVIRONMENT IS STATED, NOT INHERITED. sudo resets it, and the host's never reaches a
# guest, so everything the suite reads is set below and nothing else is: PATH is the system
# directories first, then the delivered runtime's bin (the only `node` a clean guest has),
# and RICHOS_GUI_PREBUILT puts the suite in PREBUILT MODE (lib/gui-launch.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# testvm -> scripts -> app -> richos -> tree -> the payload root
ROOT="$(cd "$HERE/../../../../.." && pwd -P)"

if [ "${1:-}" != "--in-session" ]; then
  SUITE="${1:-}"
  [ -n "$SUITE" ] || { echo "suite-in-guest.sh: usage: suite-in-guest.sh <suite file name>" >&2; exit 64; }
  rm -f "$ROOT/suite.rc"
  exec sudo -n launchctl asuser "$(id -u)" sudo -n -u "$(id -un)" /bin/bash "$0" --in-session "$SUITE"
fi

SUITE="${2:-}"
SUITE_FILE="$ROOT/tree/richos/app/scripts/$SUITE"
[ -f "$SUITE_FILE" ] || { echo "suite-in-guest.sh: no suite at $SUITE_FILE in the payload" >&2; exit 64; }

# The payload root is $HOME/run-suite (suite-walk.sh), so HOME is its parent.
HOME="$(dirname "$ROOT")"
USER="$(id -un)"
TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$ROOT/engine/runtime/bin:$ROOT/runtime/bin"
RICHOS_GUI_PREBUILT="$ROOT/prebuilt"
RICHOS_GUI_ENGINE_SOURCE="$ROOT/engine"
RICHOS_TEST_RESULTS_DIR="$ROOT/results"
export HOME USER TMPDIR PATH RICHOS_GUI_PREBUILT RICHOS_GUI_ENGINE_SOURCE RICHOS_TEST_RESULTS_DIR
if [ -d "$ROOT/runtime" ]; then
  RICHOS_RUNTIME_DIR="$ROOT/runtime"
  export RICHOS_RUNTIME_DIR
fi
mkdir -p "$RICHOS_TEST_RESULTS_DIR"

echo "  [guest $(hostname -s) as $USER, GUI session] $SUITE in prebuilt mode"
bash "$SUITE_FILE"
rc=$?
echo "$rc" > "$ROOT/suite.rc"
exit "$rc"
