#!/usr/bin/env bash
#
# terminalize-agent-worktrees.sh — THE TERMINAL INGRESS. Registered on
# SubagentStop, WorktreeRemove AND PostToolUse[TaskStop]; all race for one
# compare-and-set claim. Each supplies an EXACT join to the ownership id —
# the event's own agent_id, the exact native member path, the structured
# task_id a successful TaskStop returned — and none is promoted from a cwd,
# a name or a sentence (CEO specification 2026-09-03: femcboost docs/plans/
# worktree-terminal-authority-fix-recommendation-2026-09-03.md).
#
# NOT (yet) registered: TeammateIdle. Idle IS done by the CEO's rule, but
# the event's payload has never been observed live on this machine (every
# idle-events row is a test fixture), so no field of it is proven to join
# to the ownership id, and the specification (section 3) forbids granting
# an unmeasured event destructive authority. teammate-idle-handoff.sh
# records the first live payload's key names and identity fields as the
# fixture; when one proves an exact join, this hook accepts it through the
# same claim. Meanwhile the reconciler's native-disappearance backstop
# covers native workers.
#
# ===========================================================================
# THE RULING THIS IMPLEMENTS
# ===========================================================================
#   "The system should stop trying to discover whether the agent might
#    return. It is forbidden to return."                    — the CEO, 2026-09-02
#
# So the FIRST SubagentStop for (session_id, agent_id) is terminal. That the
# event fires at the end of every turn (measured: 337 for six agents in one
# session) is an advantage here, not a defect: the first one ends the
# assignment, and RichOS never sends that agent another turn
# (guard-resume-isolation.sh refuses, the write barrier refuses).
#
# For a native worker the harness may begin its own removal before OR after
# SubagentStop. This hook does not guess which: WorktreeRemove resolves the
# same sealed manifest by the exact native path the harness names, and both
# ingresses execute ONE compare-and-set claim on the transaction
# (worktree-transactions.py claim_terminal). Exactly one wins; the loser
# resumes the already-started transaction idempotently. No ordering between
# the two is assumed and none is needed.
#
# ===========================================================================
# WHAT THE WINNING INGRESS DOES, SYNCHRONOUSLY
# ===========================================================================
#   1. reads the already-bound exact member manifest;
#   2. writes the irrevocable `terminal` record BEFORE mutating any worktree;
#   3. writes the terminal indexes guard-resume-isolation.sh and
#      guard-sealed-worktree.sh read — every future SendMessage to this agent
#      id (or this session's name) is refused with no escape hatch;
#   4. in each owning repository, saves a backup ref for the member HEAD:
#        refs/richos/handoffs/<session_id>/<agent_id>/<branch>
#      — BEFORE the rename, because the harness deletes worktree AND branch
#      silently on some paths (PF11) and the backup ref is what survives;
#   5. quarantines each member by a same-filesystem atomic rename beside it:
#        <path>.richos-terminal-<session-id-prefix>-<agent_id>
#      the WorktreeRemove ingress quarantines the exact path it was handed
#      first; otherwise the native member first; then every external member;
#      and re-points git at the quarantine so a prune cannot orphan it;
#   6. returns and lets the worker stop.
# Capture, verification, unregistering and deletion are the reconciler's
# (scripts/reconcile-terminal-worktrees.py), driven by launchd and by
# SessionStart as crash recovery — never by this hook, whose budget is seconds.
#
# NEVER BLOCKS. Exit 0 always: a terminal event must never be prevented, and
# a worker must never be kept alive by this hook's own failure. Every failure
# is written into the transaction (a member state of `failed` or `missing`,
# COUNTED as dead-present by the metrics) and announced on stderr.
#
# NOTHING HERE IS NAME-BASED. An agent with no sealed transaction — a helper
# subagent, a read-only type, a spawn that never bound — produces no claim
# and no mutation. Absence of a transaction is silence, never a search.
#
# Specification: femcboost docs/plans/worktree-real-fix-2026-09-03.md
# ("Terminalization has two ingresses"). Env override for tests:
# RICHOS_WORKTREE_TX_DIR.

set -o pipefail

PAYLOAD="$(cat)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "NOTICE: terminalize-agent-worktrees.sh: python3 is unavailable — this terminal event was NOT recorded; the reconciler will not know this agent is over until a later ingress or a session-start reconcile." >&2
    exit 0
fi
if [ ! -f "$TX_PY" ]; then
    echo "NOTICE: terminalize-agent-worktrees.sh: scripts/lib/worktree-transactions.py is missing at $TX_PY — this terminal event was NOT recorded." >&2
    exit 0
fi

PAYLOAD="$PAYLOAD" TX_PY="$TX_PY" python3 - <<'PY' 2>&1 | sed 's/^/terminalize-agent-worktrees.sh: /' >&2
import importlib.util, json, os, sys

try:
    d = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    raise SystemExit(0)
if not isinstance(d, dict):
    raise SystemExit(0)
event = str(d.get("hook_event_name") or "")
sid = str(d.get("session_id") or "")
if not sid:
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("tx", os.environ["TX_PY"])
tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)

aid = ""
first_path = None
if event in ("SubagentStop", ""):
    aid = str(d.get("agent_id") or "")
    ingress = "SubagentStop"
elif event == "WorktreeRemove":
    path = str(d.get("worktree_path") or d.get("path") or d.get("cwd") or "")
    if not path:
        raise SystemExit(0)
    try:
        aid = tx.find_by_native_path(sid, path)
        if not aid:
            # No SEALED transaction holds this path. If it is the platform's
            # native worktree of an agent this session has a bound or start
            # record for (exact id from the platform's own `agent-<id>`
            # naming, never a teammate name), the removal is that agent's
            # terminal event and is recorded as PENDING (blocker 4).
            aid = tx.find_unsealed_by_native_path(sid, path)
    except Exception as e:
        sys.stderr.write("could not resolve %s to a transaction: %s\n" % (path, e))
        raise SystemExit(0)
    first_path = path
    ingress = "WorktreeRemove"
elif event == "PostToolUse":
    # THE EXPLICIT-KILL INGRESS (CEO specification 2026-09-03, section 1).
    # A successful TaskStop RESULT carries the immutable ownership id of the
    # task that actually stopped; the REQUEST carried only the reusable
    # teammate name and is never read as authority. The structured task_id
    # is parsed (dict / JSON string / content blocks — the measured shape is
    # a JSON string), never scraped from the success sentence. Measured
    # 2026-09-03: this was the one exact join available for a killed worker,
    # and nothing consumed it, so its cross-repository worktree leaked.
    if str(d.get("tool_name") or "") != "TaskStop":
        raise SystemExit(0)
    aid = tx.taskstop_result_id(d.get("tool_response"))
    if not aid:
        # No structured task id, an error result, or a malformed id: a
        # failed stop stops nothing, and nothing is guessed from prose.
        raise SystemExit(0)
    ti = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
    detail = "requested=%s" % (str(ti.get("task_id") or "") or "?")
    ingress = "TaskStop"
else:
    raise SystemExit(0)
if not aid:
    # No transaction and no record owns this: a path RichOS never prepared,
    # bound or started. Silence, never a search.
    raise SystemExit(0)

try:
    won, t = tx.claim_terminal(sid, aid, ingress, detail=(first_path or (detail if ingress == "TaskStop" else "")))
except Exception as e:
    sys.stderr.write("claim for agent %s FAILED: %s — nothing was mutated; the next ingress or the reconciler retries.\n" % (aid, e))
    raise SystemExit(0)
if t is None:
    # Unsealed. The event was NOT discarded (review 2026-09-03, blocker 4): if
    # this agent has a bound or start record the claim persisted it as a
    # pending terminal fact keyed by (session_id, agent_id); the manifest
    # that seals later is terminalized at once by try_seal, and one that
    # never seals is routed through the reconciler's creation-time cleanup
    # after PENDING_TERMINAL_GRACE_SECONDS. An agent nobody recorded (a
    # helper subagent) is silence.
    p = tx.read_pending_terminal(sid, aid)
    if p:
        sys.stderr.write("%s ingress for agent %s: manifest NOT sealed; the terminal event is recorded as PENDING (%s) — it terminalizes automatically once the manifest seals, else the reconciler routes the prepared members through creation-time cleanup after the grace period.\n"
                         % (ingress, aid, tx.pending_terminal_path(sid, aid)))
    raise SystemExit(0)
try:
    t = tx.terminalize(sid, aid, first_path)
except Exception as e:
    sys.stderr.write("terminalize for agent %s raised: %s — the transaction is claimed; the reconciler resumes it from its persisted member states.\n" % (aid, e))
    raise SystemExit(0)

members = t.get("members") or []
summary = ", ".join("%s:%s" % (os.path.basename(m.get("path") or "?"), m.get("state")) for m in members)
bad = [m for m in members if m.get("state") in ("failed", "missing")]
sys.stderr.write("%s ingress %s the claim for agent %s (%s); members: %s\n"
                 % (ingress, "WON" if won else "resumed", aid, t.get("teammate") or "?", summary or "none"))
for m in bad:
    sys.stderr.write("  member %s is %s: %s — counted as dead-present until an operator resolves it\n"
                     % (m.get("path"), m.get("state"), m.get("error") or "?"))
PY

exit 0
