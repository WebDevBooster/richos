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
#   5. leaves newly bound Claude-owned native paths and registrations intact,
#      recording platform-pending until Claude removes both; delegates managed
#      images to their daemon; quarantines historical linked-worktree members;
#   6. returns and lets the worker stop.
# The reconciler observes platform cleanup and captures historical quarantines.
# Existing quarantines remain protected by the explicit erasure refusal.
#
# NEVER BLOCKS. Exit 0 always: a terminal event must never be prevented, and
# a worker must never be kept alive by this hook's own failure. Every failure
# is written into the transaction (an attempt and its reason on the member,
# retried by the reconciler with backoff; a vanished member is closed absent
# with its backup ref re-created) and announced on stderr. No member state
# waits for a person (landed review 2026-09-03, blocker 3).
#
# NOTHING HERE IS NAME-BASED. An agent with no sealed transaction — a helper
# subagent, a read-only type, a spawn that never bound — produces no claim
# and no mutation. Absence of a transaction is silence, never a search.
#
# Specification: femcboost docs/plans/worktree-real-fix-2026-09-03.md
# ("Terminalization has two ingresses"). Env override for tests:
# RICHOS_WORKTREE_TX_DIR.

set -o pipefail

# Keep event JSON out of argv/environment: Linux imposes per-string exec limits.
# Descriptor 3 carries the data while stdin carries the inline Python source.
PAYLOAD="$(cat)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "NOTICE: terminalize-agent-worktrees.sh: python3 is unavailable — this terminal event was NOT recorded; the reconciler will not know this agent is over until a later ingress (a session start recovers nothing; it only reports)." >&2
    exit 0
fi
if [ ! -f "$TX_PY" ]; then
    echo "NOTICE: terminalize-agent-worktrees.sh: scripts/lib/worktree-transactions.py is missing at $TX_PY — this terminal event was NOT recorded." >&2
    exit 0
fi

TX_PY="$TX_PY" python3 - 3<<< "$PAYLOAD" <<'PY' 2>&1 | sed 's/^/terminalize-agent-worktrees.sh: /' >&2
import atexit, importlib.util, json, os, sys, time

try:
    d = json.load(os.fdopen(3))
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

# THE HOOK'S OWN BUDGET. hooks.json gives this hook `timeout: 20`, and when
# the harness kills it the failure is INVISIBLE — the hook exits 0 by design,
# so nothing says the terminal record was never written. So the deadline is
# taken here, at the top, and every discretionary phase is measured against
# it. The catch-up sweep now runs at the BOTTOM (round 12, 2026-09-10): it
# used to run right here, ahead of this event's own claim_terminal, which put
# a catch-up for an EARLIER agent in front of the one irrevocable thing only
# this event can do.
_T0 = time.time()
try:
    _BUDGET = float(os.environ.get("RICHOS_TERMINALIZE_BUDGET_SECONDS") or "15")
except ValueError:
    _BUDGET = 15.0
_DEADLINE = _T0 + _BUDGET


def _catch_up_sweep():
    """Finish what an EARLIER terminal event could not. Registered with atexit
    so it runs after EVERY path through the event work below — including the
    many early returns for an agent that owns no worktree at all, which is
    what drives the sweep at all (over a thousand helper stops a session on
    this machine). Registered with atexit rather than hoisted to the top so
    that it can keep that reach WITHOUT sitting in front of this event's own
    irrevocable terminal record, which is where it was until 2026-09-10 and
    which is how a slow sweep could silently consume the hook's whole 20s and
    leave the record unwritten.

    Every failure is announced. It never stops the event: by the time this
    runs, the event is already finished.
    """
    try:
        _daily_spec = importlib.util.spec_from_file_location(
            "daily_workspace_cleanup",
            os.path.join(os.path.dirname(os.environ["TX_PY"]), "daily-workspace-cleanup.py"))
        _daily = importlib.util.module_from_spec(_daily_spec)
        _daily_spec.loader.exec_module(_daily)
        _left = _DEADLINE - time.time()
        if _left <= 0:
            sys.stderr.write("catch-up: SKIPPED — this event used its whole %.0fs budget; the "
                             "nightly pass takes these members with the same refusals\n" % _BUDGET)
            return
        for _path, _outcome, _reason in _daily.sweep_session(tx, sid, deadline=_DEADLINE):
            sys.stderr.write("catch-up: %s %s (%s)\n" % (_outcome, _path or "(sweep)", str(_reason)[:200]))
    except Exception as _e:
        sys.stderr.write("catch-up sweep did not run: %s — this event's own work already "
                         "completed and the nightly reconciler still covers it\n" % _e)


atexit.register(_catch_up_sweep)

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
if t is not None and not won and t.get("terminal") and tx.running_after_terminal(t):
    # THE STOP THAT CLOSES A POST-TERMINAL RUN. Until 2026-09-10 every stop
    # after the first was discarded as a duplicate ingress ("the loser resumes
    # idempotently"), so the record could not answer whether an agent the
    # platform had RESTARTED was still mid-run. This is the closing half of
    # the pair the start hook opens; with it, `running_after_terminal` is a
    # fact derived from two platform events rather than an inference from
    # quiet.
    #
    # ONLY when a post-terminal run is actually open. A repeat ingress with no
    # start between it and the terminal record is not a restart ending, it is
    # the same event arriving twice, and recording it would churn the
    # transaction on every duplicate — the idempotence R12 pins. The `terminal`
    # record itself is untouched either way and stays irrevocable.
    try:
        tx.note_after_terminal(sid, aid, "stop", ingress)
    except Exception as e:
        sys.stderr.write("could not record the post-terminal stop of agent %s: %s\n" % (aid, e))
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
    sys.stderr.write("  member %s is %s (recorded by an earlier revision): %s — the reconciler re-derives it from disk and closes it by policy; nothing waits for a person\n"
                     % (m.get("path"), m.get("state"), m.get("error") or "?"))
PY

exit 0
