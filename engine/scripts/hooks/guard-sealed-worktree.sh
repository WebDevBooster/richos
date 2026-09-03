#!/usr/bin/env bash
#
# guard-sealed-worktree.sh — THE WRITE BARRIER. Matcherless PreToolUse guard,
# registered FIRST, before every tool-specific hook.
#
# ===========================================================================
# WHAT IT DECIDES
# ===========================================================================
# A worker may not perform a potentially writing tool call until its worktree
# manifest is SEALED: the parent's PostToolUse[Agent] has bound the spawn's
# exact member set to this agent id, and the worker's own SubagentStart has
# recorded where it actually started, and the two agree
# (scripts/lib/worktree-transactions.py try_seal). Until then this guard
# permits ONLY an explicit allowlist of proven read-only tools and REFUSES
# everything else — Bash, Agent, every file editor, notebooks, unknown tools,
# MCP tools — by exit code 2. Specification: femcboost
# docs/plans/worktree-real-fix-2026-09-03.md, phase 4.
#
# Why here and not at SubagentStart: Claude Code does not let SubagentStart
# block. The first attempted WRITE is the enforceable moment, and it waits for
# both durable facts and is refused if either is absent. That closes the
# ordering race between the parent binder and the worker's start hook without
# a deadlock: neither waits for the other, only the first write waits for
# both, briefly (SEAL_WAIT_SECONDS, default 5).
#
# ===========================================================================
# HOW IT TELLS THE LEAD FROM A WORKER
# ===========================================================================
# The hooks reference documents that tool events fired inside a subagent carry
# `agent_id` and `agent_type` as common input fields, and that `agent_id` is
# "present only when the hook fires inside a subagent call". No agent_id means
# the lead's own call: this guard is a no-op for it. Measured on this machine
# 2026-09-02: PreToolUse inside a teammate carries the same agent id the
# native worktree is named for.
#
# READ-ONLY AGENT TYPES (orchestration.config READONLY_ALLOWLIST and
# HARNESS_UTILITY_TYPES) are exempt from the worktree contract entirely — they
# own no worktree, so there is nothing to seal — and this guard stands down
# for them by agent_type. Their writes, if any, are still subject to every
# tool-specific guard that follows.
#
# A TERMINAL agent (its transaction claimed by SubagentStop or WorktreeRemove)
# is refused every potentially writing tool, sealed or not: it is forbidden to
# return, and a resumed turn that slipped past guard-resume-isolation.sh must
# find nothing it can write with.
#
# ===========================================================================
# FAIL OPEN ON ITS OWN ERROR, FAIL CLOSED ON AN UNSEALED MANIFEST
# ===========================================================================
# These are different things and the difference is the design's. A guard that
# crashes (python3 gone, the library unreadable, an exception in the seal
# attempt) ALLOWS the call and says so on stderr: a barrier that bricks every
# worker on its own bug is unwired within the hour, and then protects nothing.
# A guard that ran correctly and found NO sealed manifest REFUSES: that is the
# barrier doing its one job.
#
# NOTE: hooks are snapshotted at session start. This guard is inert until the
# next session and assumes nothing about being live in the session that adds it.

set -o pipefail

INPUT="$(cat)"

fail_open() { # <reason>
    echo "NOTICE: guard-sealed-worktree.sh could not run ($1) — this call is ALLOWED (fail-open on the guard's own error), but the write barrier protected nothing here. Fix the engine." >&2
    exit 0
}

command -v python3 >/dev/null 2>&1 || fail_open "python3 is unavailable"

# The lead's own call carries no agent_id: nothing to seal, nothing to refuse.
AGENT_ID="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(str(d.get("agent_id") or ""))
except Exception:
    print("")' 2>/dev/null || true)"
[ -n "$AGENT_ID" ] || exit 0

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-sealed-worktree.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # No engine here, no worktree contract, nothing to seal. Stand down.
    exit 0
else
    root_failure_banner "scripts/hooks/guard-sealed-worktree.sh" >&2
    fail_open "the governed root could not be resolved"
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${READONLY_ALLOWLIST:=Explore Plan claude-code-guide statusline-setup}"
: "${HARNESS_UTILITY_TYPES:=claude-code-guide statusline-setup output-style-setup}"
: "${SEAL_READONLY_TOOLS:=Read Glob Grep LS WebFetch WebSearch ListAgents TaskList TaskGet TodoRead ToolSearch}"
: "${SEAL_WAIT_SECONDS:=5}"

TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"
[ -f "$TX_PY" ] || fail_open "scripts/lib/worktree-transactions.py is missing at $TX_PY"

VERDICT="$(INPUT="$INPUT" TX_PY="$TX_PY" READONLY_ALLOWLIST="$READONLY_ALLOWLIST" \
    HARNESS_UTILITY_TYPES="$HARNESS_UTILITY_TYPES" SEAL_READONLY_TOOLS="$SEAL_READONLY_TOOLS" \
    SEAL_WAIT_SECONDS="$SEAL_WAIT_SECONDS" python3 - <<'PY' 2>&1
import importlib.util, json, os, sys, time

def out(kind, detail=""):
    sys.stdout.write("%s\t%s\n" % (kind, detail.replace("\t", " ").replace("\n", " ")))
    raise SystemExit(0)

try:
    d = json.loads(os.environ["INPUT"])
except Exception as e:
    out("ERROR", "payload unparseable: %s" % e)
sid = str(d.get("session_id") or "")
aid = str(d.get("agent_id") or "")
atype = str(d.get("agent_type") or "")
tool = str(d.get("tool_name") or "")
if not sid:
    out("ERROR", "payload carries an agent_id but no session_id")

# A plugin-namespaced type ("richos-engine:clark") is the same type.
bare = atype.split(":", 1)[1] if ":" in atype else atype
exempt = set((os.environ.get("READONLY_ALLOWLIST") or "").split()) | set((os.environ.get("HARNESS_UTILITY_TYPES") or "").split())
if bare and bare in exempt:
    out("EXEMPT", "agent_type %s owns no worktree" % atype)

spec = importlib.util.spec_from_file_location("tx", os.environ["TX_PY"])
tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)

# Terminal by the index OR by the transaction itself: a crash between the
# terminal write of the transaction and the index write (blocker 5) must
# still read as terminal here, and the exact (session, agent) lookup repairs
# the index on the way. (No apostrophes in these comments: they sit inside
# a command substitution, and bash pairs quotes across a heredoc there.)
if tx.is_terminal_agent(aid, sid):
    out("TERMINAL", "agent %s is terminal: its worktrees are quarantined or removed and it is forbidden to return" % aid)

readonly_tools = set((os.environ.get("SEAL_READONLY_TOOLS") or "").split())
deadline = time.time() + float(os.environ.get("SEAL_WAIT_SECONDS") or "0")
reason = ""
while True:
    try:
        sealed, res = tx.try_seal(sid, aid)
    except Exception as e:
        out("ERROR", "try_seal raised: %s" % e)
    if sealed:
        # The sealed transaction is re-read for a terminal record: sealing
        # may itself have terminalized it (a pending terminal event), or the
        # claim may have landed between the check above and this seal.
        if isinstance(res, dict) and res.get("terminal"):
            out("TERMINAL", "agent %s is terminal (from the transaction record): forbidden to return" % aid)
        out("SEALED", "")
    reason = res
    if time.time() >= deadline:
        break
    time.sleep(0.25)
if tool in readonly_tools:
    out("READONLY", "unsealed (%s) but %s is on the read-only allowlist" % (reason, tool))
out("UNSEALED", reason)
PY
)" || VERDICT="ERROR	the barrier's resolver could not run"

KIND="$(printf '%s' "$VERDICT" | head -1 | cut -f1)"
DETAIL="$(printf '%s' "$VERDICT" | head -1 | cut -f2-)"
TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || true)"

case "$KIND" in
  SEALED|EXEMPT|READONLY)
    exit 0 ;;
  ERROR)
    fail_open "$DETAIL" ;;
  TERMINAL)
    {
      echo "=== Write barrier: REFUSED (terminal agent) ==="
      echo "  $DETAIL."
      echo "  The first terminal event for this agent claimed its worktree transaction;"
      echo "  its members were quarantined for capture and removal. There is nothing here"
      echo "  to write into and no path back. Nothing to do: the work is over."
      echo "(hook: scripts/hooks/guard-sealed-worktree.sh)"
    } >&2
    exit 2 ;;
  UNSEALED)
    {
      echo "=== Write barrier: REFUSED (worktree manifest not sealed) ==="
      echo "  tool: ${TOOL_NAME:-<unknown>}    agent: $AGENT_ID"
      echo "  reason: $DETAIL"
      echo ""
      echo "  A worker may write only after its worktree set is BOUND to its agent id"
      echo "  (the lead's PostToolUse[Agent], detect-nonnative-worktree.sh) AND its start"
      echo "  is recorded (SubagentStart, record-subagent-start.sh). This call waited"
      echo "  ${SEAL_WAIT_SECONDS}s for both and found the manifest unsealed. Read-only tools"
      echo "  (${SEAL_READONLY_TOOLS}) are allowed meanwhile; this one is not."
      echo ""
      echo "  If this persists, the spawn was not bindable — the lead's context received"
      echo "  a WORKTREE BINDING FAILED banner saying why. Report it and stop —"
      echo "  do not work around it. Nothing written from an unsealed worker is owned."
      echo "  (specification: docs/plans/worktree-real-fix-2026-09-03.md, phase 4)"
      echo "(hook: scripts/hooks/guard-sealed-worktree.sh)"
    } >&2
    exit 2 ;;
  *)
    fail_open "unexpected verdict '$KIND'" ;;
esac
