#!/usr/bin/env bash
#
# run-live-proof.sh — drive the SHIPPED finish hook from a REAL SubagentStop.
#
# ===========================================================================
# WHY THIS EXISTS AND WHY IT IS NOT A UNIT TEST
# ===========================================================================
# The finish-row completion was written, reviewed, shipped, GREEN, and produced
# nothing at all for two days. Every unit case passed because every unit case
# handed the resolver a payload whose `agent_id` was the owner's — and the
# platform has never emitted one of those. The proof that made it look wired
# was a hand call with the owning id.
#
# So the acceptance for the repair is not a function call. A real claude
# session starts, launches a real subagent, that subagent ends, and the harness
# fires SubagentStop at the hook registered for that session. Nothing in this
# file calls python against the ledger; it only reads what the hook wrote.
#
# It is NOT wired into CI and must not be: it spends API quota and needs a
# live, authenticated CLI. Run it by hand when the resolution changes.
#
#   docs/verification/finish-row-owner-resolution-2026-09-10/run-live-proof.sh \
#       <engine-root> [tag]
#
# WHAT IS REAL HERE, stated so nobody has to guess:
#   * the payload, including the per-run `agent_id` — assigned by the harness,
#     never chosen by this script
#   * the hook, loaded from <engine-root> by path, unmodified
#   * the assignment: this script copies a sealed transaction out of the real
#     store byte-for-byte and changes ONE field, `session_id`, because a nested
#     session cannot be given a live session's id without colliding with it
#   * the ledger: a copy of the real one, this assignment's rows remapped to
#     the test session. The real ledger is never written by this script.
set -uo pipefail

ENGINE="${1:?usage: run-live-proof.sh <engine-root> [tag] [agent-id]}"
TAG="${2:-fixed}"
WANT="${3:-}"

RUN="$(cd "$(mktemp -d -t live-proof.XXXXXX)" && pwd -P)"
mkdir -p "$RUN/tx" "$RUN/teams"
SID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

# The assignment under test is CHOSEN FROM THE REAL STORE, not described in an
# argument: the newest sealed transaction whose native worktree still exists on
# disk, because that folder is where the session has to run. Pass an agent id
# as $3 to pin a particular one.
python3 - "$HOME/.claude/state/worktree-transactions" "$RUN/pick.txt" "$WANT" <<'PY'
import json, os, sys
root, out, want = sys.argv[1:4]
best = None
for sid in os.listdir(root):
    d = os.path.join(root, sid)
    if not os.path.isdir(d):
        continue
    for f in os.listdir(d):
        if not f.endswith(".json") or (want and f[:-5] != want):
            continue
        p = os.path.join(d, f)
        try:
            tx = json.load(open(p))
        except Exception:
            continue
        if not tx.get("sealed"):
            continue
        native = next((m.get("path") for m in tx.get("members") or []
                       if m.get("class") == "native" and os.path.isdir(m.get("path") or "")), "")
        if not native or len(tx.get("members") or []) < 2:
            continue
        ts = os.path.getmtime(p)
        if best is None or ts > best[0]:
            best = (ts, p, sid, f[:-5], native, tx.get("teammate") or "")
if not best:
    sys.stderr.write("FATAL: no sealed multi-folder transaction with a live native worktree\n")
    sys.exit(1)
_, path, sid, aid, native, teammate = best
open(out, "w").write("\n".join([path, sid, aid, native, teammate]) + "\n")
print("assignment under test: %s (%s), native worktree %s" % (teammate or "(unnamed)", aid, native))
PY
[ -s "$RUN/pick.txt" ] || exit 1
REAL_TX="$(sed -n 1p "$RUN/pick.txt")"
OWNER="$(sed -n 3p "$RUN/pick.txt")"
AGENT_CWD="$(sed -n 4p "$RUN/pick.txt")"

mkdir -p "$RUN/tx/$SID"
python3 - "$REAL_TX" "$RUN/tx/$SID/$OWNER.json" "$SID" <<'PY'
import json, sys
src, dst, sid = sys.argv[1:4]
tx = json.load(open(src))
tx["session_id"] = sid                      # the ONLY field changed
json.dump(tx, open(dst, "w"), indent=1, sort_keys=True)
PY

python3 - "$HOME/.claude/state/worktree-ledger.jsonl" "$RUN/ledger.jsonl" "$SID" "$OWNER" <<'PY'
import json, sys
src, dst, sid, owner = sys.argv[1:5]
n = 0
with open(dst, "w") as out:
    for line in open(src, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            out.write(line + "\n"); continue
        if isinstance(d, dict) and (d.get("agent_id") or "") == owner:
            d["session_id"] = sid
            n += 1
        out.write(json.dumps(d, sort_keys=True) + "\n")
print("ledger rows remapped for this assignment:", n)
PY

cat > "$RUN/settings.json" <<JSON
{
  "env": {
    "RICHOS_WORKTREE_LEDGER": "$RUN/ledger.jsonl",
    "RICHOS_WORKTREE_TX_DIR": "$RUN/tx",
    "WORKER_EVENTS_TEAMS_DIR": "$RUN/teams"
  },
  "hooks": {
    "SubagentStop": [
      {
        "hooks": [
          {"type": "command", "command": "$ENGINE/scripts/hooks/worker-ended-handoff.sh"},
          {"type": "command", "command": "tee -a $RUN/payloads.jsonl >/dev/null"}
        ]
      }
    ]
  }
}
JSON

echo "run dir:    $RUN"
echo "session-id: $SID"
echo "engine:     $ENGINE"
cd "$AGENT_CWD"
# --setting-sources "" so the installed engine plugin does NOT load: the only
# hook that fires is the one under test, and no real state is touched.
claude --setting-sources "" \
       --settings "$RUN/settings.json" \
       --session-id "$SID" \
       --model haiku \
       --permission-mode acceptEdits \
       --agents '{"pinger":{"description":"Replies with one word.","prompt":"Reply with the single word ping and stop."}}' \
       -p "Use the Task tool once to launch a subagent with subagent_type pinger and the prompt 'ping'. Then reply with the single word done." 2>&1 | tail -3
echo "--- the payload the harness sent ---"
cat "$RUN/payloads.jsonl" 2>/dev/null || echo "(none — SubagentStop never fired)"
echo "--- the row the hook wrote ---"
grep '"event": "finished"' "$RUN/ledger.jsonl" | tail -1
