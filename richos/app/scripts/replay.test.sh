#!/usr/bin/env bash
# replay.test.sh — the replay toolkit as programs (T3 idea 2; richos-hq plan 2026-10-09 §4 row 6):
# the replay child's command line over the committed captures, the scrubber that takes the account
# out of a capture, and the long-session recorder against a fake `claude`. No live account.
# run-tests: no-host-screen: command-line programs over pipes and temporary folders; nothing is launched on any screen
# run-tests: inputs richos/app/scripts/replay.test.sh richos/app/scripts/replay.test.py richos/app/scripts/replay richos/app/Cargo.toml richos/app/Cargo.lock richos/app/crates/richos-core
# run-tests: covers richos/app/crates/richos-core/src/bin/richos-replay.rs richos/app/scripts/replay/scrub-capture.py richos/app/scripts/replay/record-long-session.py
set -euo pipefail
cd "$(dirname "$0")/.."
# No clock of this suite's own around the build: it waits on Cargo's lock behind whatever else
# builds (terminal-quota.test.sh, audit R13).
RICHOS_REPLAY_BIN="$(cargo build --quiet -p richos-core --bin richos-replay --message-format=json \
  | python3 -c 'import json,sys
for line in sys.stdin:
    r=json.loads(line)
    if r.get("reason")=="compiler-artifact" and r["target"]["name"]=="richos-replay" and r.get("executable"):
        print(r["executable"])')"
[ -x "$RICHOS_REPLAY_BIN" ] || { echo "richos-replay was not built" >&2; exit 1; }
RICHOS_REPLAY_BIN="$RICHOS_REPLAY_BIN" PYTHONDONTWRITEBYTECODE=1 python3 scripts/replay.test.py
