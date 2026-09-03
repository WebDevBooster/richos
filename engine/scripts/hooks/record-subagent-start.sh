#!/usr/bin/env bash
#
# record-subagent-start.sh — SubagentStart hook. A NONBLOCKING FACT WRITER.
#
# ===========================================================================
# WHAT IT RECORDS, AND WHY IT CANNOT DO MORE
# ===========================================================================
# SubagentStart fires from inside the worker's own execution and carries the
# platform's `agent_id`, the worker's `cwd` and its `agent_type`. It is the
# only hook that observes where the worker actually starts — for a native
# isolation spawn, the exact `<entity>/.claude/worktrees/agent-<id>` path the
# harness created; for a `cwd:` spawn, the prepared cross-repository path.
#
# Claude Code does NOT permit this event to block (it is absent from the
# exit-code-2 table in the hooks reference). So this hook writes the start
# fact durably, attempts to seal the worktree manifest, and exits 0 whatever
# happened. It never claims a nonzero exit refuses the start. The enforceable
# barrier is PreToolUse (guard-sealed-worktree.sh): a worker whose manifest is
# not sealed cannot perform a potentially writing tool call, so a start this
# hook could not record is a worker that cannot write.
#
# The seal needs TWO facts — this one, and the parent's PostToolUse[Agent]
# binding (detect-nonnative-worktree.sh). They arrive in either order; each
# writer calls try_seal after its own write, and whichever is second seals.
# Neither waits for the other.
#
# WHAT IS NEVER DONE HERE: no member is invented from the teammate name; no
# native path is derived from anything but the event cwd, verified against
# git inside try_seal. A worker that starts somewhere the intent did not
# describe records that fact and stays unsealed.
#
# Specification: femcboost docs/plans/worktree-real-fix-2026-09-03.md, phase 4.
# State: scripts/lib/worktree-transactions.py. Env override for tests:
# RICHOS_WORKTREE_TX_DIR.

set -o pipefail

PAYLOAD="$(cat)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "NOTICE: record-subagent-start.sh: python3 is unavailable — the start fact was NOT recorded; this worker's manifest cannot seal and its writes will be refused by guard-sealed-worktree.sh." >&2
    exit 0
fi
if [ ! -f "$TX_PY" ]; then
    echo "NOTICE: record-subagent-start.sh: scripts/lib/worktree-transactions.py is missing at $TX_PY — the start fact was NOT recorded; this worker's manifest cannot seal and its writes will be refused." >&2
    exit 0
fi

PAYLOAD="$PAYLOAD" TX_PY="$TX_PY" python3 - <<'PY' 2>&1 >/dev/null | sed 's/^/NOTICE: record-subagent-start.sh: /' >&2
import importlib.util, json, os, sys

try:
    d = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    d = {}
if not isinstance(d, dict) or d.get("hook_event_name") not in ("", None, "SubagentStart"):
    raise SystemExit(0)
aid = str(d.get("agent_id") or "")
sid = str(d.get("session_id") or "")
if not aid or not sid:
    # Unattributable start: nothing to record, nothing to seal. Silence beats
    # a fact about nobody.
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("tx", os.environ["TX_PY"])
tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
try:
    tx.record_start(sid, aid, str(d.get("cwd") or ""), str(d.get("agent_type") or ""),
                    str(d.get("agent_transcript_path") or ""))
except Exception as e:
    sys.stderr.write("the start fact could not be written for agent %s: %s\n" % (aid, e))
    raise SystemExit(0)
try:
    tx.try_seal(sid, aid)
except Exception as e:
    sys.stderr.write("try_seal raised for agent %s: %s\n" % (aid, e))
PY

exit 0
