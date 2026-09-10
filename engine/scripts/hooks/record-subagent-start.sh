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

# Keep event JSON out of argv/environment: Linux imposes per-string exec limits.
# Descriptor 3 carries the data while stdin carries the inline Python source.
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

TX_PY="$TX_PY" python3 - 3<<< "$PAYLOAD" <<'PY' 2>&1 >/dev/null | sed 's/^/NOTICE: record-subagent-start.sh: /' >&2
import importlib.util, json, os, sys

try:
    d = json.load(os.fdopen(3))
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

# ===========================================================================
# A TERMINAL AGENT IS STARTING. RECORD IT AND SAY SO.
# ===========================================================================
# Round 11 authorized deleting a workspace in the terminal event because the
# platform's first SubagentStop "says the agent cannot be given another turn".
# Measured 2026-09-10 by restart-after-terminal-measure.py: ten of the 66
# workspace-owning terminal transactions on this machine were started again
# afterwards, the earliest on 2026-09-08. Two mechanisms, neither of which any
# guard can see -- a message queued before the stop and delivered after it,
# and a background task belonging to the agent exiting, whose notification
# resumes the agent.
#
# THE FALSIFYING EVENT WAS BEING RECORDED AS AN ORDINARY START AND REPORTED TO
# NOBODY (types A and O together). It is neither any more. This hook cannot
# block -- SubagentStart is absent from the exit-code-2 table -- so it does
# the two things it can: it writes the fact where the reclaim lane reads it,
# and it announces it. The enforceable barrier is elsewhere and unchanged
# (guard-sealed-worktree.sh refuses this worker's writing tool calls).
try:
    if tx.is_terminal_agent(aid, sid):
        note = tx.note_after_terminal(sid, aid, "start", str(d.get("cwd") or ""))
        sys.stderr.write(
            "RESTART AFTER TERMINAL: agent %s has a terminal record and the platform has "
            "started it AGAIN, in %s. This is the fact round 11's section 7 named as its own "
            "falsifier, and it is now on the transaction where the reclaim lane reads it: no "
            "workspace of this agent is reclaimed while this run is open. This worker's writing "
            "tool calls are refused by guard-sealed-worktree.sh, so it can read and report but "
            "not write.\n" % (aid, str(d.get("cwd") or "?")))
        if note is None:
            sys.stderr.write(
                "  ...and the note could NOT be attached: this agent has no sealed transaction "
                "with a terminal record, so nothing here holds it. The restart still happened.\n")
except Exception as e:
    # Never fails the start. The standing measurement re-derives the same fact
    # from the event log, so a lost note is a lost convenience, not a lost fact.
    sys.stderr.write("could not record the post-terminal start of agent %s: %s — "
                     "restart-after-terminal-measure.py still sees it in the event log\n" % (aid, e))
PY

exit 0
