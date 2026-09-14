#!/usr/bin/env bash
#
# demo.sh — WHO HEARS A PROTECTED-REF FINDING, BEFORE AND AFTER.
#
# It builds a scratch repository whose `main` has been rewound behind the tip an
# agent's window recorded — the `--mode destruction` shape of the oscillation
# reproduction, where a merge is dropped — writes the event row the engine's
# check writes today, and then asks the SAME question of two worlds:
#
#   THE WORLD AS IT WAS   every registered Stop hook EXCEPT the new one is
#                         driven against the finding, and what each one puts on
#                         the operator's channel is printed. This is the whole
#                         pre-change operator surface, swept rather than
#                         reasoned about.
#   THE WORLD AS IT IS    the new hook is driven against the identical finding,
#                         and what it puts on the operator's channel is printed
#                         verbatim.
#
# Nothing outside its own temporary directory is read or written: the workspace
# store is redirected with RICHOS_WORKSPACES_DIR, so the operator's real
# events.jsonl is neither read nor appended to.
#
# Usage: docs/verification/protected-ref-notice-owner-2026-09-14-logs/demo.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
ENGINE_ROOT="$REPO_ROOT/engine"
HOOKS="$ENGINE_ROOT/scripts/hooks"
NEW_HOOK="notice-protected-ref-moves.sh"

command -v python3 >/dev/null 2>&1 || { echo "needs python3" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "needs git" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t prmdemo.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
export RICHOS_WORKSPACES_DIR="$SANDBOX/workspaces"
mkdir -p "$RICHOS_WORKSPACES_DIR"

SEAT="$SANDBOX/seat"
TARGET="$SANDBOX/richos"
NOHOOKS="$SANDBOX/nohooks"
mkdir -p "$NOHOOKS"

mk_repo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "demo@example.invalid"
    git -C "$1" config user.name "demo"
    git -C "$1" config core.hooksPath "$NOHOOKS"
    git -C "$1" commit -q --allow-empty -m "root"
}

mk_repo "$SEAT"; : > "$SEAT/orchestration.config"
mk_repo "$TARGET"
git -C "$TARGET" commit -q --allow-empty -m "a land by the lead"
SNAP="$(git -C "$TARGET" rev-parse HEAD)"

echo "=== THE CONDITION ==="
echo "repository : $TARGET"
echo "main held  : $SNAP   <- the tip an agent's call started with"
git -C "$TARGET" reset -q --hard "$SNAP~1"
echo "main is now: $(git -C "$TARGET" rev-parse HEAD)   <- rewound; the lead's land is off the branch"
echo ""

python3 - "$RICHOS_WORKSPACES_DIR/events.jsonl" "$TARGET" "$SNAP" "$(git -C "$TARGET" rev-parse HEAD)" <<'PY'
import json, sys, time
path, repo, tip, found = sys.argv[1:5]
row = {"action": "reported: the engine does not move a ref back",
       "branch": "main", "event": "protected-ref-moved", "found": found,
       "key": "feedface-0000-4000-8000-000000000000--zach-opus-n4",
       "repo": repo, "tip": tip,
       "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "why": "moved to %s, which carries this agent's own unlanded work "
              "(it committed or merged onto it)" % found[:12]}
open(path, "a", encoding="utf-8").write(json.dumps(row, sort_keys=True) + "\n")
print("the row the check writes today, in the store's event log:")
print("  " + json.dumps(row, sort_keys=True))
PY
echo ""

payload() {
    python3 - "$1" "$SEAT" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": sys.argv[1],
                  "transcript_path": "/nonexistent/transcript.jsonl", "cwd": sys.argv[2],
                  "prompt_id": "deadbeef-0000-4000-8000-000000000000",
                  "permission_mode": "default", "stop_hook_active": False,
                  "last_assistant_message": "Landed the branch and deployed.",
                  "background_tasks": [], "session_crons": []}))
PY
}

operator_channel() {   # <hook path> <session id> -> whatever reaches the operator
    payload "$2" | env RICHOS_ENTITY_ROOT="$SEAT" CLAUDE_PROJECT_DIR="$SEAT" \
        bash "$1" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("")
    sys.exit(0)
try:
    print(json.loads(raw).get("systemMessage") or "")
except Exception:
    print("")
'
}

STOP_HOOKS="$(python3 - "$ENGINE_ROOT/hooks/hooks.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for g in (d.get("hooks", d)).get("Stop", []) or []:
    for h in g.get("hooks", []) or []:
        c = h.get("command", "")
        if c.endswith(".sh"):
            print(os.path.basename(c))
PY
)"

echo "=== THE WORLD AS IT WAS: every registered Stop hook EXCEPT the new one ==="
SPOKE=0
N=0
for h in $STOP_HOOKS; do
    [ "$h" = "$NEW_HOOK" ] && continue
    [ -f "$HOOKS/$h" ] || continue
    N=$((N + 1))
    MSG="$(operator_channel "$HOOKS/$h" "bbbb00$(printf '%02d' "$N")-0000-4000-8000-000000000000")"
    if printf '%s' "$MSG" | grep -qi "protected ref\|$TARGET"; then
        printf '  SPOKE   %-36s %s\n' "$h" "$MSG"
        SPOKE=$((SPOKE + 1))
    else
        printf '  silent  %-36s %s\n' "$h" "${MSG:0:60}"
    fi
done
echo ""
echo "  $N pre-existing Stop hooks driven against the finding; $SPOKE mentioned it."
echo ""

echo "=== AND NOTHING ELSE IN THE ENGINE READS THE ROW EITHER ==="
echo "  files under engine/scripts naming protected-ref-moved:"
grep -rln "protected-ref-moved" "$ENGINE_ROOT/scripts" 2>/dev/null \
    | sed "s|$REPO_ROOT/||" | sed 's/^/    /'
echo ""

echo "=== THE WORLD AS IT IS: the new Stop hook, same finding, same payload ==="
echo ""
operator_channel "$HOOKS/$NEW_HOOK" "cccc0001-0000-4000-8000-000000000000" | fold -s -w 100 | sed 's/^/  /'
echo ""
