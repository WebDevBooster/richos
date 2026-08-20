#!/usr/bin/env bash
#
# guard-definition-drift.sh — BLOCKING PreToolUse guard on the `Agent` tool.
# Closes the "a mid-session definition install never reaches the spawned
# agent's booted prompt" hole.
#
# THE FAILURE MODE (proven upstream 2026-08-06, 25 rejected deliverables):
#   `.claude/agents/*.md` teammate definitions are loaded ONCE, at SESSION
#   START — exactly like hooks. Install or update a definition mid-session and
#   the file on disk changes, the roster line changes, everyone's mental model
#   changes — but a teammate spawned later in that SAME session still boots on
#   the STALE definition the harness read at session start. Nothing in the
#   spawn payload, the tool result, or the agent's own transcript says so. In
#   the upstream production project this kit was extracted from, a teammate's
#   definition was upgraded (v2.0 -> v2.1) and the work dispatched in the very
#   same session: batch 1 happened to notice its booted prompt was v2.0-shaped
#   and self-corrected; batches 2-4 did not, drafted 25 outputs under the stale
#   v2.0 contract, and every one had to be thrown away. That project's incident
#   write-up does not ship with this kit — the lesson does.
#   The "How to Delegate" section of your CLAUDE.md states the rule; this guard
#   is the structure that makes forgetting it impossible.
#
# THE CONTRACT
#   Partner hook: scripts/hooks/snapshot-agent-definitions.sh (SessionStart)
#   records `sha256  <path>` for every definition at session start into
#   .claude/state/agent-definitions-<session8>.snapshot. At every Agent spawn
#   this guard compares that recorded hash against the CURRENT on-disk hash of
#   the definition being spawned:
#
#     MODIFIED (hashes differ)   -> BLOCK. The booted prompt is provably the
#                                   pre-edit definition. Message names both
#                                   hashes and the two sanctioned paths.
#     ACKED    (definition-drift-ack: <sha256> in the prompt, matching the
#               CURRENT on-disk hash)
#                                -> ALLOW + append to
#                                   .claude/state/definition-drift-acks.log
#                                   (mirrors the resume-acks.log pattern).
#     CREATED  (no snapshot entry — the definition did not exist at session
#               start; the creator-teammate-hires-then-orchestrator-spawns
#               flow, which has historically worked same-session)
#                                -> ALLOW + warn + log. See "OPEN QUESTION".
#     UNCHANGED                  -> ALLOW silently.
#     NO DEFINITION FILE (built-in types: Explore/Plan/general-purpose/claude/
#               claude-code-guide/statusline-setup, or any type with no
#               `.claude/agents/<type>.md`)
#                                -> ALLOW silently.
#     NO SNAPSHOT / UNPARSEABLE PAYLOAD / NO python3 / NO sha256 tool
#                                -> ALLOW + warn. Never block.
#
# FAIL-OPEN BY DESIGN — AND WHY THAT IS NOT A WEAKNESS HERE:
#   The sibling guards (guard-worktree-isolation.sh, guard-resume-isolation.sh)
#   fail CLOSED, because each of those can evaluate its contract from the
#   payload alone: an unparseable spawn is by definition not a proven-correct
#   spawn. This guard is different in kind — it can only ever
#   PROVE DRIFT (a hash mismatch against a recorded baseline); it can never
#   prove freshness. With no snapshot to compare against there is no evidence of
#   anything, and blocking every spawn on "no evidence" would halt the whole
#   team the first session after this hook lands (when no snapshot exists yet)
#   and on every machine where the state dir is unwritable. So: block ONLY on
#   positive proof of drift; warn on everything indeterminate. The blocking
#   sibling guard runs FIRST in the same PreToolUse[Agent] chain and already
#   fails closed on an unparseable payload, so nothing is lost.
#
# OPEN QUESTION — NEW definitions fail OPEN, deliberately:
#   We know MODIFIED definitions do not reach a newly spawned agent (proven).
#   We do NOT have equally hard evidence for a definition file CREATED
#   mid-session: the creator teammate (CREATOR_TEAMMATE in
#   orchestration.config) hires and the orchestrator spawns the new hire in
#   the same session routinely, which suggests the harness resolves an
#   unknown subagent_type from disk on demand. Rather than block a flow with a
#   working track record on an untested theory, a created-since-snapshot
#   definition is ALLOWED with a warning line (logged to
#   .claude/state/definition-drift.log). If a fresh-hire spawn is ever observed
#   booting empty/stale, flip CREATED to BLOCK — the branch is isolated below.
#
# PreToolUse[Agent] payload (same shape guard-worktree-isolation.sh parses):
#   { "tool_name": "Agent",
#     "tool_input": { "subagent_type": "dev", "name": "dev-sonnet-c1",
#                     "prompt": "...", "isolation": "worktree", ... },
#     "session_id": "<uuid>" }
#
# Exit codes (Claude Code PreToolUse convention):
#   0  allowed (silently, or with a warning on stderr)
#   2  BLOCKED — provable definition drift with no matching ack
#
# TEST OVERRIDE: DEFINITION_DRIFT_ROOT forces the root directory (test-only;
# never set in a real session). The partner snapshot hook honours the same
# variable.
#
# NOTE: hooks are snapshotted per session; this guard takes effect from the
# NEXT session. It assumes nothing about being live in the session that adds it.

set -o pipefail

HOOK_TAG="(hook: scripts/hooks/guard-definition-drift.sh)"

# Subagent types the harness provides itself — they have no
# `.claude/agents/<type>.md`, so there is nothing to drift. Listed explicitly
# (rather than relying on the file-existence check alone) so the common case
# short-circuits before any filesystem or state work.
BUILTIN_TYPES="Explore Plan general-purpose claude claude-code-guide statusline-setup"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FALLBACK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

INPUT="$(cat 2>/dev/null || true)"

# --- warn: stderr + a durable, de-duplicated log line --------------------
# Warnings never block (exit stays 0). The log makes them survivable evidence
# rather than transcript-only noise, mirroring resume-acks.log / main-checkout-
# runs.log. Dedup keys on CONTENT ONLY (never the timestamp), because a
# double-registered hook fires twice and two sequential subprocess spawns can
# straddle a UTC-second boundary — the same race already fixed in
# guard-resume-isolation.sh's resume-acks.log append path.
append_log() { # <logfile> <content-key>
    local logfile="$1" key="$2" last new
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    new="$(printf '%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key")"
    last=""
    [ -f "$logfile" ] && last="$(tail -n 1 "$logfile" 2>/dev/null | cut -f2- || true)"
    if [ "$key" != "$last" ]; then
        printf '%s\n' "$new" >>"$logfile" 2>/dev/null || true
    fi
}

warn_allow() { # <one-line reason> [<log-key or empty>]
    {
        echo "=== Definition-drift guard: WARNING (allowed) ==="
        echo "  $1"
        echo "$HOOK_TAG"
    } >&2
    if [ -n "${2:-}" ] && [ -n "${STATE_DIR:-}" ]; then
        append_log "$STATE_DIR/definition-drift.log" "$2"
    fi
    exit 0
}

# --- payload parse -------------------------------------------------------
# No python3 -> cannot parse reliably -> allow (see FAIL-OPEN above). The
# sibling guard-worktree-isolation.sh in this same chain already refuses the
# spawn outright when python3 is missing.
if ! command -v python3 >/dev/null 2>&1; then
    warn_allow "python3 unavailable — cannot verify agent-definition freshness for this spawn. Definition drift is NOT being checked."
fi

PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError("payload not an object")
    if str(d.get("tool_name", "") or "") != "Agent":
        print("NOTAGENT\t\t\t\t")
        sys.exit(0)
    ti = d.get("tool_input", {})
    if not isinstance(ti, dict):
        raise ValueError("tool_input not an object")
    st = str(ti.get("subagent_type", "") or "")
    nm = str(ti.get("name", "") or "")
    sid = str(d.get("session_id", "") or "")
    pr = str(ti.get("prompt", "") or "")
    pr = pr.replace("\t", " ").replace("\n", "\x01")
    print("OK\t%s\t%s\t%s\t%s" % (st, nm, sid, pr))
except Exception:
    print("PARSEFAIL\t\t\t\t")
' 2>/dev/null || printf 'PARSEFAIL\t\t\t\t')"

STATUS="$(printf '%s' "$PARSED" | cut -f1)"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f2)"
NAME="$(printf '%s' "$PARSED" | cut -f3)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f4)"
PROMPT="$(printf '%s' "$PARSED" | cut -f5- | tr '\001' '\n')"

# A well-formed payload for a different tool passes through untouched.
[ "$STATUS" = "NOTAGENT" ] && exit 0

# --- root + state resolution --------------------------------------------
if [ -n "${DEFINITION_DRIFT_ROOT:-}" ]; then
    REPO_ROOT="$DEFINITION_DRIFT_ROOT"
else
    _RMC_LIB="$SCRIPT_DIR/../lib/resolve-main-checkout.sh"
    if [ -f "$_RMC_LIB" ]; then
        # shellcheck source=../lib/resolve-main-checkout.sh
        . "$_RMC_LIB" 2>/dev/null || true
    fi
    if command -v resolve_main_checkout >/dev/null 2>&1; then
        REPO_ROOT="$(resolve_main_checkout "$SCRIPT_DIR" "$_FALLBACK_ROOT" 2>/dev/null || echo "$_FALLBACK_ROOT")"
    else
        REPO_ROOT="$_FALLBACK_ROOT"
    fi
fi
STATE_DIR="$REPO_ROOT/.claude/state"

# An Agent payload we cannot parse: the sibling preventer blocks it; we warn.
if [ "$STATUS" = "PARSEFAIL" ]; then
    warn_allow "could not parse the Agent spawn payload — agent-definition freshness NOT verified for this spawn." \
        "$(printf 'parsefail\tunparseable Agent payload — definition freshness not verified')"
fi

# --- built-in / definition-less types pass silently ----------------------
[ -n "$SUBAGENT_TYPE" ] || exit 0
for b in $BUILTIN_TYPES; do
    [ "$SUBAGENT_TYPE" = "$b" ] && exit 0
done

DEF_REL=".claude/agents/${SUBAGENT_TYPE}.md"
DEF_PATH="$REPO_ROOT/$DEF_REL"

# --- snapshot resolution -------------------------------------------------
# Session-scoped ONLY when a session id is present: falling back to `latest`
# there could compare this session's spawn against a DIFFERENT session's
# baseline (two concurrent sessions), inventing drift that never happened.
# The `latest` symlink is used only when the payload carries no session id at
# all — the best available handle, and still only ever able to prove drift.
SNAP_PATH=""
SESSION_SHORT="$(printf '%s' "$SESSION_ID" | tr -cd '[:alnum:]-' | cut -c1-8)"
if [ -n "$SESSION_SHORT" ]; then
    CAND="$STATE_DIR/agent-definitions-${SESSION_SHORT}.snapshot"
    [ -f "$CAND" ] && SNAP_PATH="$CAND"
else
    CAND="$STATE_DIR/agent-definitions-latest.snapshot"
    [ -f "$CAND" ] && SNAP_PATH="$CAND"
fi

if [ -z "$SNAP_PATH" ]; then
    warn_allow "no session-start definition snapshot found for session '${SESSION_ID:-<unset>}' (expected .claude/state/agent-definitions-${SESSION_SHORT:-latest}.snapshot). snapshot-agent-definitions.sh was probably not live at the last session start — hooks snapshot per session, so it activates from the NEXT one. Definition drift is NOT being checked for this spawn." \
        "$(printf 'nosnapshot\tsession=%s\tagent=%s' "${SESSION_ID:-<unset>}" "$SUBAGENT_TYPE")"
fi

# --- hashes --------------------------------------------------------------
sha256_of() {
    local p="$1"
    [ -f "$p" ] || { echo ""; return; }
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$p" 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$p" 2>/dev/null | awk '{print $1}'
    else
        python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$p" 2>/dev/null
    fi
}

# Snapshot lookup: first field of the line whose second field is DEF_REL.
# `#`-prefixed header lines are skipped by the field match itself.
SNAP_HASH="$(awk -v want="$DEF_REL" '
    $1 ~ /^#/ { next }
    $2 == want { print $1; exit }
' "$SNAP_PATH" 2>/dev/null || true)"

CUR_HASH="$(sha256_of "$DEF_PATH")"

# Definition file gone. If it was in the snapshot, that is worth surfacing;
# either way there is no current content to compare, so never block.
if [ -z "$CUR_HASH" ]; then
    if [ -n "$SNAP_HASH" ]; then
        warn_allow "definition $DEF_REL was present at session start but is MISSING on disk now — the spawn will boot on the session-start copy. Verify this is intended." \
            "$(printf 'missing\tagent=%s\t%s deleted since session start' "$SUBAGENT_TYPE" "$DEF_REL")"
    fi
    exit 0
fi

# --- CREATED since session start: allow + warn (see OPEN QUESTION) -------
if [ -z "$SNAP_HASH" ]; then
    {
        echo "=== Definition-drift guard: NEW DEFINITION (allowed) ==="
        echo "  '$SUBAGENT_TYPE' has no entry in this session's start-of-session"
        echo "  snapshot — $DEF_REL was CREATED mid-session"
        echo "  (current sha256 ${CUR_HASH})."
        echo ""
        echo "  Allowed deliberately: the hire-then-spawn-in-the-same-session"
        echo "  flow has a working track record, which suggests an UNKNOWN"
        echo "  subagent_type is resolved from disk on demand. That is not proven"
        echo "  the way the MODIFIED case is, so if this fresh hire boots empty or"
        echo "  stale, say so — the created-vs-modified load semantics is an open"
        echo "  question we chose to fail OPEN on."
        echo "$HOOK_TAG"
    } >&2
    append_log "$STATE_DIR/definition-drift.log" \
        "$(printf 'created\tagent=%s\tname=%s\tsha256=%s' \
            "$SUBAGENT_TYPE" "${NAME:-<unset>}" "$CUR_HASH")"
    exit 0
fi

# --- UNCHANGED: the common case, silent ----------------------------------
[ "$SNAP_HASH" = "$CUR_HASH" ] && exit 0

# --- MODIFIED: ack or block ----------------------------------------------
# definition-drift-ack: <sha256> — a live prompt line whose hash token matches
# the CURRENT on-disk definition. Matching a >=16-char prefix counts (the full
# 64 obviously does), so an operator can paste the short hash a report quotes;
# anything shorter is too weak to prove the ack refers to THIS content.
ACK_LINE=""
ACK_TOKEN=""
if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*definition-drift-ack:[[:space:]]*[0-9a-fA-F]+'; then
    ACK_LINE="$(printf '%s' "$PROMPT" \
        | grep -oE '^[[:space:]]*definition-drift-ack:[[:space:]]*.+' | head -1 \
        | sed -E 's/^[[:space:]]*//')"
    ACK_TOKEN="$(printf '%s' "$ACK_LINE" \
        | sed -E 's/^definition-drift-ack:[[:space:]]*//' \
        | grep -oE '^[0-9a-fA-F]+' | head -1 | tr '[:upper:]' '[:lower:]' || true)"
fi

if [ -n "$ACK_TOKEN" ] && [ "${#ACK_TOKEN}" -ge 16 ] && [ "${CUR_HASH#"$ACK_TOKEN"}" != "$CUR_HASH" ]; then
    append_log "$STATE_DIR/definition-drift-acks.log" \
        "$(printf 'agent=%s\tname=%s\tsnapshot=%s\tcurrent=%s\t%s' \
            "$SUBAGENT_TYPE" "${NAME:-<unset>}" "$SNAP_HASH" "$CUR_HASH" "$ACK_LINE")"
    {
        echo "=== Definition-drift guard: ACK accepted (allowed) ==="
        echo "  '$SUBAGENT_TYPE' definition changed since session start; the spawn"
        echo "  carries a matching definition-drift-ack. The booted system prompt is"
        echo "  STILL the session-start copy — the spawn prompt must order this agent"
        echo "  to read $DEF_REL on disk and follow it as authoritative."
        echo "  Logged to .claude/state/definition-drift-acks.log"
        echo "$HOOK_TAG"
    } >&2
    exit 0
fi

{
    echo "=== Definition-drift guard: BLOCKED ==="
    echo "  The '$SUBAGENT_TYPE' definition has been MODIFIED since this session"
    echo "  started, so this spawn would boot on the STALE session-start copy —"
    echo "  not the definition now on disk."
    echo ""
    echo "    file:            $DEF_REL"
    echo "    session-start:   $SNAP_HASH   <- what the agent would ACTUALLY boot on"
    echo "    current on disk: $CUR_HASH   <- what you think you are spawning"
    if [ -n "$ACK_TOKEN" ]; then
        echo ""
        echo "  A definition-drift-ack was present but does NOT match the current"
        echo "  hash (acked: ${ACK_TOKEN}). Acks must quote the CURRENT sha256 —"
        echo "  a stale ack proves nothing."
    fi
    echo ""
    echo "  Subagent definitions load ONCE, at SESSION START, exactly like hooks."
    echo "  This is the 2026-08-06 upstream incident that cost 25 rejected"
    echo "  deliverables: a definition upgraded mid-session, the work dispatched"
    echo "  in that same session, three of four batches drafted under the stale"
    echo "  contract."
    echo ""
    echo "  Two sanctioned paths:"
    echo "    (a) PREFERRED — restart into a FRESH session, then spawn. The new"
    echo "        session snapshots the current definitions and this agent boots"
    echo "        on the real thing, with no workaround in the prompt."
    echo "    (b) SAME-SESSION, eyes open — add a live spawn-prompt line:"
    echo "          definition-drift-ack: $CUR_HASH"
    echo "        AND an explicit order in the prompt to read $DEF_REL"
    echo "        on disk IN FULL and follow it as the governing definition"
    echo "        (its booted prompt is the stale copy). Acceptance must then"
    echo "        verify a fingerprint unique to the NEW definition — style"
    echo "        checks alone do not prove contract compliance."
    echo "$HOOK_TAG"
} >&2
exit 2
