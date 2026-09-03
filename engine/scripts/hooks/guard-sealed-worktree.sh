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
# "present only when the hook fires inside a subagent call". A payload that
# PARSES and carries no agent_id is the lead's own call: this guard is a no-op
# for it. Measured on this machine 2026-09-02: PreToolUse inside a teammate
# carries the same agent id the native worktree is named for.
#
# READ-ONLY AGENT TYPES (orchestration.config READONLY_ALLOWLIST and
# HARNESS_UTILITY_TYPES) are exempt from the worktree contract entirely — they
# own no worktree, so there is nothing to seal — and this guard stands down
# for them by agent_type. Their writes, if any, are still subject to every
# tool-specific guard that follows.
#
# A TERMINAL agent (its transaction claimed by SubagentStop or WorktreeRemove,
# or its terminal event recorded pending) is refused every potentially
# writing tool, sealed or not: it is forbidden to return, and a resumed turn
# that slipped past guard-resume-isolation.sh must find nothing it can write
# with. Terminal is read from the transaction itself when the index is
# absent (blocker 5), and from the sealed transaction after a seal.
#
# ===========================================================================
# FAIL CLOSED — ON AN UNSEALED MANIFEST AND ON ITS OWN ERROR ALIKE
# ===========================================================================
# Review 2026-09-03, blocker 3. Until this revision the guard ALLOWED the call
# when python3 was missing, when the transaction library was missing, when
# root resolution broke, when its resolver raised, and when the payload did
# not parse (no agent_id could be extracted, so it read as the lead). The
# reasoning was that a barrier that bricks every worker on its own bug gets
# unwired within the hour. The review's answer is better than either
# extreme, and it is what this file now does:
#
#   - a payload PROVEN to be the lead's (it parses; no agent_id)  -> pass
#   - a worker whose manifest is SEALED                             -> pass
#   - a worker tool PROVEN read-only (SEAL_READONLY_TOOLS)          -> pass,
#     under the read-only policy, unsealed or not, even when the guard
#     cannot evaluate — it exists so a stuck worker can still report
#   - EVERYTHING ELSE when the guard cannot evaluate — python3 missing,
#     the library missing, the root unresolvable, the payload unparseable,
#     the resolver raising, transaction state unreadable — is DENIED (exit 2)
#     with a banner that names the dependency to fix.
#
# The "bricked within the hour" worry is answered one level up: the spawn
# gate (guard-worktree-isolation.sh clause 7c) refuses to START a
# file-writing teammate while any lifecycle dependency is unavailable, and
# the integrity probe (Layer Q6) proves this barrier fails closed. A broken
# engine therefore stops new workers at the door instead of letting running
# ones write unowned bytes — and the lead is told which file to restore.
#
# WITHOUT python3 the payload cannot be parsed; the lead is then proven only
# by the ABSENCE of an unescaped "agent_id" key anywhere in the raw JSON
# (a key inside a nested string would be escaped as \"agent_id\"), and a
# read-only tool by a regex on "tool_name". Anything else is denied.
#
# NOTE: hooks are snapshotted at session start. This guard is inert until the
# next session and assumes nothing about being live in the session that adds it.

set -o pipefail

INPUT="$(cat)"
HOOK_TAG="(hook: scripts/hooks/guard-sealed-worktree.sh)"
: "${SEAL_READONLY_TOOLS_FALLBACK:=Read Glob Grep LS WebFetch WebSearch ListAgents TaskList TaskGet TodoRead ToolSearch}"

deny_cannot_evaluate() { # <reason> [tool] [agent]
    {
        echo "=== Write barrier: REFUSED (the barrier cannot evaluate this call) ==="
        echo "  tool: ${2:-<unknown>}    agent: ${3:-<unknown>}"
        echo "  reason: $1"
        echo ""
        echo "  This call comes from a worker (or from a payload the barrier cannot prove"
        echo "  is the lead's), and the barrier could not read the worker's worktree state."
        echo "  A potentially writing or unknown tool is refused rather than allowed on a"
        echo "  guess: nothing written from an unproven worker is owned by anyone."
        echo "  Read-only tools (${SEAL_READONLY_TOOLS:-$SEAL_READONLY_TOOLS_FALLBACK}) still pass."
        echo "  FIX THE ENGINE: restore the named dependency (scripts/hooks/install.sh), then"
        echo "  spawn again. The spawn gate refuses new file-writing teammates meanwhile."
        echo "  (review 2026-09-03 blocker 3; specification: docs/plans/worktree-real-fix-2026-09-03.md, phase 4)"
        echo "$HOOK_TAG"
    } >&2
    exit 2
}

raw_has_agent_id() { # true when the raw payload carries an unescaped "agent_id" key
    printf '%s' "$INPUT" | grep -Eq '(^|[^\\])"agent_id"'
}
raw_tool_name() {
    printf '%s' "$INPUT" | sed -n -E 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1
}
is_readonly_tool() { # <tool> <list>
    local t; for t in $2; do [ "$t" = "$1" ] && return 0; done; return 1
}

if ! command -v python3 >/dev/null 2>&1; then
    if ! raw_has_agent_id; then
        echo "NOTICE: guard-sealed-worktree.sh: python3 is unavailable; this payload carries no agent_id and is treated as the lead's own call (allowed). Every WORKER write is refused until python3 is restored." >&2
        exit 0
    fi
    RAW_TOOL="$(raw_tool_name)"
    if [ -n "$RAW_TOOL" ] && is_readonly_tool "$RAW_TOOL" "$SEAL_READONLY_TOOLS_FALLBACK"; then
        echo "NOTICE: guard-sealed-worktree.sh: python3 is unavailable; $RAW_TOOL is on the read-only allowlist and is allowed under the read-only policy. Every potentially writing tool is refused until python3 is restored." >&2
        exit 0
    fi
    deny_cannot_evaluate "python3 is unavailable, so the worker's worktree state cannot be read" "${RAW_TOOL:-<unknown>}" "<unparsed>"
fi

# PARSED: LEAD / WORKER:<agent_id> / UNPARSEABLE. Only a parsed payload with
# no agent_id is the lead; an unparseable one is NOT (that was the old hole).
PARSED="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("UNPARSEABLE\t%s" % str(e).replace("\t"," ")); raise SystemExit(0)
if not isinstance(d, dict):
    print("UNPARSEABLE\tpayload is not a JSON object"); raise SystemExit(0)
aid = str(d.get("agent_id") or "")
print(("WORKER\t%s\t%s" % (aid, str(d.get("tool_name") or ""))) if aid else "LEAD\t\t%s" % str(d.get("tool_name") or ""))' 2>/dev/null || true)"
PKIND="$(printf '%s' "$PARSED" | head -1 | cut -f1)"
AGENT_ID="$(printf '%s' "$PARSED" | head -1 | cut -f2)"
TOOL_NAME="$(printf '%s' "$PARSED" | head -1 | cut -f3)"
case "$PKIND" in
  LEAD) exit 0 ;;
  WORKER) : ;;
  *)
    RAW_TOOL="$(raw_tool_name)"
    if [ -n "$RAW_TOOL" ] && is_readonly_tool "$RAW_TOOL" "$SEAL_READONLY_TOOLS_FALLBACK"; then
        exit 0
    fi
    deny_cannot_evaluate "the hook payload is unparseable (${PARSED#*	}); a payload that cannot be proven the lead's is treated as a worker's" "${RAW_TOOL:-<unknown>}" "<unparsed>" ;;
esac

# FAIL CLOSED BEFORE THE SHARED BOOTSTRAP: the block below is byte-identical
# in every rooted hook (probe Layer R compares them), and its own answer to a
# missing resolver is a banner and exit 0 — right for a notice hook, wrong for
# a write barrier. So the barrier decides first: with the resolver missing, a
# worker's read-only tool passes and everything else is refused. The block's
# missing-resolver branch is then unreachable here and stays identical.
_PRE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$_PRE_SCRIPT_DIR/../lib/resolve-roots.sh" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-sealed-worktree.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_PRE_SCRIPT_DIR/../lib/resolve-roots.sh"
    } >&2
    is_readonly_tool "$TOOL_NAME" "$SEAL_READONLY_TOOLS_FALLBACK" && exit 0
    deny_cannot_evaluate "scripts/lib/resolve-roots.sh is missing at $_PRE_SCRIPT_DIR/../lib/resolve-roots.sh" "$TOOL_NAME" "$AGENT_ID"
fi

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
    exit 2
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    # No engine here, no worktree contract, nothing to seal. A RESOLVED state,
    # not a failure: stand down.
    exit 0
else
    root_failure_banner "scripts/hooks/guard-sealed-worktree.sh" >&2
    is_readonly_tool "$TOOL_NAME" "$SEAL_READONLY_TOOLS_FALLBACK" && exit 0
    deny_cannot_evaluate "the governed root could not be resolved (${RICHOS_ROOT_REASON:-no reason given})" "$TOOL_NAME" "$AGENT_ID"
fi

CONFIG="$ENTITY_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${READONLY_ALLOWLIST:=Explore Plan claude-code-guide statusline-setup}"
: "${HARNESS_UTILITY_TYPES:=claude-code-guide statusline-setup output-style-setup}"
: "${SEAL_READONLY_TOOLS:=$SEAL_READONLY_TOOLS_FALLBACK}"
: "${SEAL_WAIT_SECONDS:=5}"

TX_PY="$SCRIPT_DIR/../lib/worktree-transactions.py"
if [ ! -f "$TX_PY" ]; then
    is_readonly_tool "$TOOL_NAME" "$SEAL_READONLY_TOOLS" && exit 0
    deny_cannot_evaluate "scripts/lib/worktree-transactions.py is missing at $TX_PY" "$TOOL_NAME" "$AGENT_ID"
fi

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

try:
    spec = importlib.util.spec_from_file_location("tx", os.environ["TX_PY"])
    tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
except Exception as e:
    out("ERROR", "the transaction library could not be loaded: %s" % e)

# Terminal by the index OR by the transaction itself: a crash between the
# terminal write of the transaction and the index write (blocker 5) must
# still read as terminal here, and the exact (session, agent) lookup repairs
# the index on the way. (No apostrophes in these comments: they sit inside
# a command substitution, and bash pairs quotes across a heredoc there.)
try:
    if tx.is_terminal_agent(aid, sid):
        out("TERMINAL", "agent %s is terminal: its worktrees are quarantined or removed and it is forbidden to return" % aid)
except Exception as e:
    out("ERROR", "terminal state unreadable: %s" % e)

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

case "$KIND" in
  SEALED|EXEMPT|READONLY)
    exit 0 ;;
  TERMINAL)
    {
      echo "=== Write barrier: REFUSED (terminal agent) ==="
      echo "  $DETAIL."
      echo "  The first terminal event for this agent claimed its worktree transaction;"
      echo "  its members were quarantined for capture and removal. There is nothing here"
      echo "  to write into and no path back. Nothing to do: the work is over."
      echo "$HOOK_TAG"
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
      echo "$HOOK_TAG"
    } >&2
    exit 2 ;;
  ERROR|*)
    # The guard could not evaluate: the resolver raised, the library would
    # not load, terminal state was unreadable, or the verdict is unknown.
    # DENY every potentially writing or unknown tool; read-only tools pass.
    is_readonly_tool "$TOOL_NAME" "$SEAL_READONLY_TOOLS" && {
        echo "NOTICE: guard-sealed-worktree.sh could not evaluate ($DETAIL); $TOOL_NAME is allowed under the read-only policy. Fix the engine." >&2
        exit 0
    }
    deny_cannot_evaluate "${DETAIL:-unexpected verdict '$KIND'}" "$TOOL_NAME" "$AGENT_ID" ;;
esac
