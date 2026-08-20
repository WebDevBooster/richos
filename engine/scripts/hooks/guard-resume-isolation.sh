#!/usr/bin/env bash
#
# guard-resume-isolation.sh — BLOCKING PreToolUse guard on the SendMessage
# tool. Closes the "resume bypasses worktree isolation" hole.
#
# THE FAILURE MODE:
#   A SendMessage to a *completed* teammate RESUMES it from its transcript.
#   The spawn-side guard (guard-worktree-isolation.sh) only fires on
#   PreToolUse[Agent] SPAWNS — it never sees a resume. So if the resumed
#   teammate's worktree was already landed and REMOVED (the single-writer land
#   sequence removes a teammate's worktree after shutdown), the agent wakes with
#   NO isolated workspace and improvises: today a hand-rolled worktree
#   (tolerable), tomorrow main-checkout writes or lost work. This guard makes
#   that IMPOSSIBLE by default: a resume that cannot be proven to land in a live
#   workspace is blocked, with the two sanctioned paths spelled out inline.
#
# THE CONTRACT (default-deny, fail closed, one auditable escape hatch):
#   1. Recipient is a currently-ACTIVE teammate — positive liveness: present in
#      the session team roster (config.json members[]) with a non-terminal
#      status, OR owning an existing (present) native worktree (its cwd under
#      .claude/worktrees/agent-* still on disk) -> ALLOW silently. An active
#      agent trips NEITHER block path because one of those two signals always
#      holds for it (see resolver below).
#   2. Recipient would RESUME a non-active/completed teammate (roster status
#      terminal AND/OR its worktree already removed) -> BLOCK, unless the
#      message carries an explicit  resume-ack: <where writes land + why safe>
#      live line (the deliberate escape hatch for pure-question follow-ups or
#      serialized external-repo writers). resume-ack: -> ALLOW + append the ack
#      line + recipient + timestamp to .claude/state/resume-acks.log.
#   3. Recipient resolution failure or ambiguity -> BLOCK (fail closed).
#   4. NEVER blocked: the lead / reply channel (to == main / team-lead / lead /
#      user / empty) and PROTOCOL messages (shutdown / plan-approval / permission
#      control traffic — detected by a non-string `message` structured body or an
#      explicit protocol type/token).
#
# SendMessage PreToolUse payload:
#   { "tool_name": "SendMessage",
#     "tool_input": { "to": "<name-or-agentId>",
#                     "message": "<text>" | {<structured protocol object>},
#                     "summary": "<preview>", "messageType"?: "<type>" },
#     "session_id": "<uuid>" }
# `to` is matched against the same roster the tool resolves against, and we
# handle BOTH the plain-name and raw-agentId addressing forms.
#
# HARNESS-VERSION NOTE: the roster/member schema and the "cwd under
# .claude/worktrees/" liveness signal are harness-version-coupled. This guard
# assumes the schema documented in orchestration.config (SESSION_TEAMS_DIR). If
# a future harness changes it, update the resolver below — the guard fails
# CLOSED, so a schema drift blocks (with resume-ack: as the override) rather
# than silently waving resumes through.
#
# FAIL-CLOSED: python3 unavailable, an unparseable payload, or an
# unreadable/absent team config for a specific-teammate recipient are all
# blocked (never waved through) — with resume-ack: available as the operator
# override where a deliberate resume is genuinely safe.
#
# NOTE: hooks are snapshotted per session; this guard takes effect from the
# NEXT session. It assumes nothing about being live in the session that adds it.

set -eo pipefail

# Fail-closed, not fail-open: every payload check below depends on python3 to
# parse the tool_input JSON. If python3 is missing, refuse outright rather than
# wave the resume through unchecked (which would contradict the default-deny
# contract). resume-ack: remains the operator override for a genuinely safe
# resume.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-resume-isolation.sh: python3 is required for payload parsing — refusing (fail-closed). If this is a deliberate, safe resume, add a 'resume-ack: <where writes land + why safe>' message line." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG="$REPO_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
# Default to the platform team-state location when unset/blank in config.
: "${SESSION_TEAMS_DIR:=$HOME/.claude/teams}"

INPUT="$(cat)"

HOOK_TAG="(hook: scripts/hooks/guard-resume-isolation.sh)"

# Single combined parse: tool-name gate + full field extraction in ONE python
# pass, so an unparseable payload can NEVER slip past a swallowed error on a
# separate earlier extraction (the old two-step form failed OPEN here: a garbage
# top-level payload defaulted tool_name to "" and exited 0 before this
# fail-closed block was ever reached). Now every outcome is explicit:
#   - top-level JSON unparseable / not an object / tool_input not an object
#       -> PARSEFAIL  (fail CLOSED, block — matches the header's fail-closed claim)
#   - valid payload for a DIFFERENT tool (tool_name != SendMessage)
#       -> NOTSENDMSG (pass through — the matcher semantics are preserved)
#   - valid SendMessage payload
#       -> OK + fields
# Message text has newlines preserved via a \001 placeholder so the resume-ack:
# marker can be matched with a line-start anchor (same discipline
# guard-worktree-isolation.sh uses for main-checkout-run:). MSG_KIND is "string"
# when message is plain text and "object" when it is a structured protocol body
# ("none" when absent).
PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("PARSEFAIL\t\t\t\t\t")
    sys.exit(0)
if not isinstance(d, dict):
    print("PARSEFAIL\t\t\t\t\t")
    sys.exit(0)
tool_name = str(d.get("tool_name", "") or "")
if tool_name != "SendMessage":
    # A well-formed payload for a different tool is not our concern.
    print("NOTSENDMSG\t\t\t\t\t")
    sys.exit(0)
ti = d.get("tool_input", {})
if not isinstance(ti, dict):
    print("PARSEFAIL\t\t\t\t\t")
    sys.exit(0)
to = str(ti.get("to", "") or "")
msg = ti.get("message", None)
if isinstance(msg, str):
    kind = "string"
    text = msg
elif msg is None:
    kind = "none"
    text = ""
else:
    # structured / non-string message body = protocol/control traffic.
    kind = "object"
    try:
        text = json.dumps(msg)
    except Exception:
        text = ""
mt = ti.get("messageType") or ti.get("message_type") or ti.get("type") or ""
mt = str(mt or "")
sid = str(d.get("session_id", "") or "")
text = text.replace("\t", " ").replace("\n", "\x01")
print("OK\t%s\t%s\t%s\t%s\t%s" % (to, kind, mt, sid, text))
' 2>/dev/null || printf 'PARSEFAIL\t\t\t\t\t')"

STATUS="$(printf '%s' "$PARSED" | cut -f1)"
TO="$(printf '%s' "$PARSED" | cut -f2)"
MSG_KIND="$(printf '%s' "$PARSED" | cut -f3)"
MSG_TYPE="$(printf '%s' "$PARSED" | cut -f4)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f5)"
MESSAGE="$(printf '%s' "$PARSED" | cut -f6- | tr '\001' '\n')"

# Not a SendMessage payload — a well-formed event for a different tool passes
# through untouched (preserving the PreToolUse[SendMessage] matcher semantics).
if [ "$STATUS" = "NOTSENDMSG" ]; then
  exit 0
fi

# Fail-closed on an unparseable SendMessage payload.
if [ "$STATUS" = "PARSEFAIL" ]; then
  {
    echo "=== Resume-isolation guard: BLOCKED ==="
    echo "  - Could not parse the SendMessage payload to verify the recipient's"
    echo "    liveness. Failing closed. Re-issue a well-formed SendMessage; if this"
    echo "    is a deliberate, safe resume, add a 'resume-ack: <where writes land +"
    echo "    why safe>' line to the message body."
    echo "$HOOK_TAG"
  } >&2
  exit 2
fi

# --- (4a) lead / reply channel — NEVER blocked ---------------------------
# A message to the lead/reply channel cannot resume a specific completed
# teammate, so it is never the failure mode. Also covers the background-agent
# -> lead reply channel.
TO_LC="$(printf '%s' "$TO" | tr '[:upper:]' '[:lower:]')"
case "$TO_LC" in
  main|team-lead|lead|leader|user|"") exit 0 ;;
esac

# --- (4b) protocol / control messages — NEVER blocked --------------------
# Three independent tells, any of which marks control traffic:
#   - a structured (non-string) message body,
#   - an explicit messageType/type on one of the protocol control types,
#   - a JSON body carrying a quoted protocol type token (quoted so ordinary
#     prose that merely mentions "shutdown" never false-matches).
PROTO_TYPES_RE='shutdown_request|shutdown_response|shutdown_approved|plan_approval_request|plan_approval_response|permission_request|permission_response|sandbox_permission_request|sandbox_permission_response|team_permission_update|mode_set_request'
if [ "$MSG_KIND" = "object" ]; then
  exit 0
fi
if printf '%s' "$MSG_TYPE" | grep -qiE "^(${PROTO_TYPES_RE})$"; then
  exit 0
fi
if printf '%s' "$MESSAGE" | grep -qE "\"(${PROTO_TYPES_RE})\""; then
  exit 0
fi

# --- (2b) resume-ack: deliberate-safe-resume escape hatch ----------------
# A live line beginning with resume-ack: sanctions the resume. Best-effort by
# design (this is an auditable opt-out, not a security boundary). Logged to
# .claude/state/resume-acks.log, mirroring main-checkout-runs.log.
RESUME_ACK=""
if printf '%s' "$MESSAGE" | grep -qE '^[[:space:]]*resume-ack:[[:space:]]*.+'; then
  RESUME_ACK="$(printf '%s' "$MESSAGE" | grep -oE '^[[:space:]]*resume-ack:[[:space:]]*.+' | head -1 | sed -E 's/^[[:space:]]*//')"
fi
if [ -n "$RESUME_ACK" ]; then
  LOG_DIR="$REPO_ROOT/.claude/state"
  LOG_FILE="$LOG_DIR/resume-acks.log"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  # De-dup guard: Claude Code merges hooks from BOTH .claude/settings.json
  # (generated by scripts/hooks/install.sh) AND .claude/settings.local.json (the
  # committed source) — both register this PreToolUse[SendMessage] hook, so it
  # fires TWICE per delivery and would append two byte-identical lines (the
  # sibling guard-worktree-isolation.sh doubles its own append logs the same
  # way). Collapse the second write by comparing the RECIPIENT + ACK-CONTENT
  # ONLY against the immediately-preceding logged line — the timestamp is NEVER
  # part of the equality key, it is written for display only.
  #
  # WHY THE TIMESTAMP IS EXCLUDED (the fix): the earlier form embedded a
  # SECOND-granularity UTC timestamp in the equality key and relied on both
  # double-fire invocations landing in the same wall-clock second. On a colder /
  # loaded runner the two sequential subprocess spawns can straddle a UTC-second
  # boundary, the timestamps differ, the string-equality misses, and BOTH lines
  # get appended — a real, reproducible timing race (the automation QA's live-fire CI autopsy).
  # Keying on recipient+ack alone removes the clock-boundary race entirely: a
  # same-delivery double-fire always has identical recipient+ack and collapses;
  # two GENUINELY separate resumes differ in recipient and/or ack text and are
  # both kept. Hooks for one tool call run sequentially, so no lock is needed.
  DEDUP_KEY="$(printf 'to=%s\t%s' "${TO:-<unset>}" "$RESUME_ACK")"
  NEW_LINE="$(printf '%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEDUP_KEY")"
  LAST_KEY=""
  if [ -f "$LOG_FILE" ]; then
    # Strip the leading timestamp field (field 1) from the last logged line to
    # recover its dedup key (fields 2+: "to=<recipient>\t<ack>").
    LAST_KEY="$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -f2- || true)"
  fi
  if [ "$DEDUP_KEY" != "$LAST_KEY" ]; then
    printf '%s\n' "$NEW_LINE" >>"$LOG_FILE" 2>/dev/null || true
  fi
  exit 0
fi

# --- (1/2/3) liveness resolution against the session team roster ---------
# Resolve the team config the SAME way the SendMessage tool resolves `to`: the
# session team dir under SESSION_TEAMS_DIR/session-<first8>. Tests override the
# teams dir via RESUME_GUARD_TEAMS_DIR. EXACT session match only (never a
# single-dir fallback) so a mismatched/absent session never resolves to an
# unrelated team.
TEAMS_DIR="${RESUME_GUARD_TEAMS_DIR:-$SESSION_TEAMS_DIR}"
TEAM_CONFIG=""
if [ -n "$SESSION_ID" ]; then
  TEAM_CONFIG="$TEAMS_DIR/session-$(printf '%s' "$SESSION_ID" | cut -c1-8)/config.json"
fi

emit_block_completed() { # <detail>
  local detail="$1"
  {
    echo "=== Resume-isolation guard: BLOCKED ==="
    echo "  SendMessage to '${TO}' would RESUME a completed / non-active teammate"
    echo "  (${detail})."
    echo ""
    echo "  A resumed teammate wakes from its transcript, and the spawn-side guard"
    echo "  (guard-worktree-isolation.sh) NEVER fires on a resume — so if this"
    echo "  agent's worktree was already landed and removed, it will improvise in"
    echo "  the wrong place (main-checkout writes / lost work). Default-deny."
    echo ""
    echo "  Two sanctioned paths:"
    echo "    (a) FILE-BEARING follow-up -> do NOT resume. Spawn a FRESH teammate"
    echo "        with the Agent tool and isolation:\"worktree\" (a new, unique"
    echo "        <role>-<identifier> name)."
    echo "    (b) DELIBERATE safe resume (a pure-question follow-up, or a"
    echo "        serialized external-repo writer) -> add a live message line:"
    echo "          resume-ack: <where any writes will land + why this resume is safe>"
    echo "        (allowed + logged to .claude/state/resume-acks.log)."
    echo "$HOOK_TAG"
  } >&2
}

emit_block_unresolvable() { # <detail>
  local detail="$1"
  {
    echo "=== Resume-isolation guard: BLOCKED ==="
    echo "  SendMessage recipient '${TO}' could not be confirmed as an ACTIVE"
    echo "  teammate (${detail}). Failing closed: a resume that can't be proven to"
    echo "  land in a live isolated workspace is denied."
    echo ""
    echo "  Fix one of:"
    echo "    - If you meant a live teammate, re-send with its EXACT current name"
    echo "      or agentId (disambiguate — do not rely on a partial/prefix name)."
    echo "    - For a FILE-BEARING follow-up, spawn a FRESH teammate with the Agent"
    echo "      tool and isolation:\"worktree\" (a new <role>-<identifier> name)."
    echo "    - For a DELIBERATE safe resume (pure question, or a serialized"
    echo "      external-repo writer), add a live message line:"
    echo "        resume-ack: <where any writes will land + why this resume is safe>"
    echo "      (allowed + logged to .claude/state/resume-acks.log)."
    echo "$HOOK_TAG"
  } >&2
}

if [ -z "$TEAM_CONFIG" ] || [ ! -f "$TEAM_CONFIG" ]; then
  emit_block_unresolvable "no readable session team config for session '${SESSION_ID:-<unset>}'"
  exit 2
fi

VERDICT="$(TO_ARG="$TO" python3 - "$TEAM_CONFIG" <<'PY'
import json, os, sys

recipient = os.environ.get("TO_ARG", "")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("NOCONFIG|unreadable")
    raise SystemExit

members = data.get("members", []) or []
TERMINAL = {
    "shutdown", "shutdown_request", "shutdown_approved", "completed",
    "complete", "done", "terminated", "dead", "exited", "killed", "removed",
    "gone",
}

def wt_present(m):
    """True/False if the member owns a native worktree cwd (present/gone);
    None for an in-process / non-worktree member (cwd not under
    .claude/worktrees/)."""
    cwd = str(m.get("cwd") or "")
    if "/.claude/worktrees/" in cwd:
        return os.path.isdir(cwd)
    return None

# Exact match on name OR agentId (both addressing forms).
matches = [m for m in members
           if m.get("name") == recipient or m.get("agentId") == recipient]
if not matches:
    # Unambiguous name-prefix match only; >1 is ambiguous (fail closed).
    pfx = [m for m in members
           if isinstance(m.get("name"), str) and m.get("name").startswith(recipient)]
    if len(pfx) == 1:
        matches = pfx
    elif len(pfx) > 1:
        print("AMBIGUOUS|%d roster names start with '%s'" % (len(pfx), recipient))
        raise SystemExit

if not matches:
    print("NOTFOUND|not in session roster")
    raise SystemExit

m = matches[0]
status = str(m.get("status") or "").lower()
wt = wt_present(m)

# A present worktree is positive liveness regardless of a stale status.
if wt is True:
    print("ACTIVE|worktree present")
    raise SystemExit
# The worktree once existed (cwd under .claude/worktrees/) and is now gone —
# THE failure state (landed + removed).
if wt is False:
    print("TERMINAL|its worktree %s was landed + removed" % (m.get("cwd") or ""))
    raise SystemExit
# In-process / non-worktree member: liveness is the roster status.
if status in TERMINAL:
    print("TERMINAL|roster status is '%s'" % status)
    raise SystemExit
print("ACTIVE|roster status '%s'" % (status or "present"))
PY
)"

VKIND="${VERDICT%%|*}"
VDETAIL="${VERDICT#*|}"

case "$VKIND" in
  ACTIVE)
    exit 0 ;;
  TERMINAL)
    emit_block_completed "$VDETAIL"
    exit 2 ;;
  AMBIGUOUS)
    emit_block_unresolvable "ambiguous: $VDETAIL"
    exit 2 ;;
  NOTFOUND)
    emit_block_unresolvable "$VDETAIL"
    exit 2 ;;
  NOCONFIG)
    emit_block_unresolvable "team config unreadable: $VDETAIL"
    exit 2 ;;
  *)
    # Any unexpected resolver output -> fail closed.
    emit_block_unresolvable "recipient liveness indeterminate"
    exit 2 ;;
esac
