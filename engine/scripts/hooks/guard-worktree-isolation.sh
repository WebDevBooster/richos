#!/usr/bin/env bash
#
# guard-worktree-isolation.sh — PreToolUse guard (Agent), FIRST in the chain.
#
# HARD, PROMPT-INDEPENDENT enforcement of the teammate-spawn contract. Every
# teammate that can edit repo files MUST be spawned correctly, by STRUCTURE,
# not by the lead remembering to. This guard reads the spawn payload and BLOCKS
# the call unless the spawn is well-formed, so a correct spawn is the only spawn
# that survives.
#
# THE CONTRACT — enforced for every file-capable agent (i.e. every
# subagent_type NOT on the read-only allowlist, which is read from
# orchestration.config: READONLY_ALLOWLIST):
#   1. Native isolation:  isolation == "worktree" (or the isolated "remote")
#      -- OR -- an explicit "main-checkout-run:" marker line in the prompt (the
#      fallback escape hatch, see below).
#   2. A unique, well-formed, TRUTHFUL name:  "<role>-<model>-<identifier>"
#      (e.g. dev-sonnet-1, qa-opus-r3) — THREE dash-joined parts. Never bare
#      ("dev"), 2-part ("dev-1"), or run-together ("devsonnet1"). Required EVEN
#      WHEN the main-checkout-run marker is present — the marker does not relax
#      clause 2.
#        2a. The <model> token must be one of the harness's model aliases
#            (orchestration.config: ALLOWED_MODELS; default fable/opus/sonnet/haiku).
#        2b. TRUTHFULNESS: the <model> token must reflect the model the instance
#            ACTUALLY boots on. Expected model is resolved with this precedence:
#              (i)  an explicit tool_input.model override wins; else
#              (ii) the model: line in the YAML frontmatter of the LIVE agent
#                   definition .claude/agents/<subagent_type>.md.
#            LIVE agents only resolve — a non-live template under
#            .claude/agents/templates/ is never a spawnable type and is never
#            read here. If the expected model is determinable and the token
#            disagrees -> BLOCKED, naming BOTH values. If it is genuinely
#            undeterminable (no override AND no live-def default -- the
#            inherit-from-session case, or model:"inherit"), we cannot know the
#            boot model, so we require only that the token be a valid alias (2a)
#            and accept it -- a spawn is never failed on unknowable information.
#
# The "main-checkout-run:" marker is the FALLBACK escape hatch for a genuine
# one-off main-checkout run of ANY type. A prompt line beginning with
# "main-checkout-run:" followed by a short reason permits that one spawn to run
# without isolation. Every use is best-effort logged to
# .claude/state/main-checkout-runs.log so the opt-out stays auditable, never
# silent.
#
#   Without isolation, AND without the marker, AND not a read-only type
#   -> blocked, with the exact remediation spelled out inline.
#
# CLAUSE 3 — NAME REUSE IS STRUCTURALLY IMPOSSIBLE. A name that has EVER been
# used in this session's team — ACTIVE or COMPLETED — must never be reused.
# Latest-wins name shadowing and resumed-vs-respawned confusion both stem from
# names being reusable; this clause removes the ambiguity at the spawn boundary.
# There is NO escape hatch: identifiers are free (dev-1 -> dev-2 / dev-b /
# dev-0714), so a fresh name is always available.
#
#   Name-history sources (a UNION, so a past name can't slip through — see the
#   resolver for why it can't miss):
#     1. spawned-names.log — THIS guard appends every allowed spawn's name to a
#        session-scoped ledger, so from the first spawn of a session every used
#        name is recorded (the can't-miss primary source).
#     2. config.json members[] — every roster name, any status (the harness
#        keeps completed members with a terminal status rather than deleting).
#     3. idle-events.jsonl / task-events.jsonl teammate fields — durable
#        completion records that survive roster pruning.
#   Resolvable ONLY by EXACT session match (never a single-dir fallback). The
#   session teams dir is read from orchestration.config (SESSION_TEAMS_DIR, blank
#   -> platform default $HOME/.claude/teams); GUARD_ISOLATION_TEAMS_DIR overrides
#   it for tests. When no session team dir resolves (e.g. a bare unit-test
#   payload), the reuse clause is inert — a real session always has its team dir
#   (it auto-exists at startup), so production spawns are always covered.
#
#   HARNESS-VERSION NOTE: the members[]/status/cwd schema this clause reads is
#   harness-version-coupled (see orchestration.config). The clause fails OPEN on
#   any resolver error (never invents a collision from an IO glitch), so a schema
#   drift degrades to "no reuse check", never to a spurious block.
#
# ALLOWED (exit 0):
#   - any non-Agent tool (passthrough)
#   - spawns of READ-ONLY agent types (they never write repo files) — the
#     allowlist below — with no further requirement.
#   - a file-capable spawn that satisfies BOTH contract clauses.
# BLOCKED (exit 2): every other Agent spawn — with the exact clause(s) it
# failed AND the exact fix, inline.
#
# FAIL-CLOSED: default-deny. Anything not on the read-only allowlist is treated
# as a file-capable teammate and must satisfy the full contract; an unparseable
# Agent payload is blocked, not waved through.

set -eo pipefail

# Fail-closed, not fail-open: every payload check below depends on python3 to
# parse the tool_input JSON. If python3 is missing, EVERY `python3 ... ||
# true`-guarded call below silently returns empty, and an empty parse used to
# read as "not an Agent spawn" / "not file-capable" — i.e. this guard would
# wave every spawn through unchecked. That contradicts the "FAIL-CLOSED:
# default-deny" contract documented above, so refuse outright instead.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: guard-worktree-isolation.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG="$REPO_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
# Default to Claude Code's built-in read-only agent types if unset.
: "${READONLY_ALLOWLIST:=Explore Plan claude-code-guide statusline-setup}"
# Default the session teams dir to the platform location when unset/blank.
: "${SESSION_TEAMS_DIR:=$HOME/.claude/teams}"
# Default the allowed <model> name-token set to Claude Code's aliases if unset.
: "${ALLOWED_MODELS:=fable opus sonnet haiku}"

INPUT="$(cat)"

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Agent" ] || exit 0

# A well-formed teammate name under the truthful-naming contract:
#   <role>-<model>-<identifier>   (THREE+ dash-joined parts)
# role: starts with a letter, alphanumeric, no dash. model/identifier:
# alphanumeric. Set-membership of the model token (clause 2a) and its
# truthfulness (clause 2b) are checked SEPARATELY so each failure gets a precise
# message; this regex only fixes the SHAPE (rejects bare "dev", 2-part "dev-1",
# run-together "devsonnet1").
NAME_SHAPE_RE='^[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9]+-[A-Za-z0-9]+(-[A-Za-z0-9]+)*$'

# model_in_allowed_set <token> — is the token one of ALLOWED_MODELS?
model_in_allowed_set() {
  local tok="$1" m
  for m in $ALLOWED_MODELS; do
    [ "$tok" = "$m" ] && return 0
  done
  return 1
}

# resolve_expected_model <override> <subagent_type> — echo the model this spawn
# is EXPECTED to boot on, or "" (empty) if undeterminable. Precedence: an
# explicit override (arg 1) wins; else the model: line in the YAML frontmatter
# of the LIVE agent definition .claude/agents/<subagent>.md (arg 2, FIRST
# frontmatter block only). LIVE agents ONLY — a non-live template under
# .claude/agents/templates/ is never a spawnable subagent_type, so the plain
# .claude/agents/<subagent>.md path can never reach templates/. A "inherit"
# override, a missing/non-live definition, or a def with no frontmatter model
# line all yield "" (undeterminable). Always returns 0.
resolve_expected_model() {
  local override="$1" subagent="$2" lo m def
  if [ -n "$override" ]; then
    lo="$(printf '%s' "$override" | tr '[:upper:]' '[:lower:]')"
    [ "$lo" = "inherit" ] && { printf ''; return 0; }
    # Normalize a verbose id (e.g. "claude-opus-4-8") down to its alias.
    for m in $ALLOWED_MODELS; do
      case "$lo" in *"$m"*) printf '%s' "$m"; return 0;; esac
    done
    printf '%s' "$lo"   # unknown override: emit as-is (will mismatch -> block)
    return 0
  fi
  def="$REPO_ROOT/.claude/agents/${subagent}.md"
  { [ -n "$subagent" ] && [ -f "$def" ]; } || { printf ''; return 0; }
  python3 - "$def" 2>/dev/null <<'PY' || true
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        lines = f.read().split("\n")
except Exception:
    sys.exit(0)
# frontmatter = the block between the FIRST '---' and the next '---' only.
if not lines or lines[0].strip() != "---":
    sys.exit(0)
for ln in lines[1:]:
    if ln.strip() == "---":
        break
    s = ln.strip()
    if s.lower().startswith("model:"):
        print(s.split(":", 1)[1].strip().strip('"').strip("'").lower())
        break
PY
}

# Parse subagent_type / isolation / name / prompt (with embedded newlines
# preserved via a \001 placeholder so the "main-checkout-run:" marker can be
# matched with a line-start anchor).
PARSED="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {})
    if not isinstance(ti, dict):
        raise ValueError("tool_input not an object")
    st = str(ti.get("subagent_type", "") or "")
    iso = str(ti.get("isolation", "") or "")
    nm = str(ti.get("name", "") or "")
    md = str(ti.get("model", "") or "")
    sid = str(d.get("session_id", "") or "")
    pr = str(ti.get("prompt", "") or "")
    pr = pr.replace("\t", " ").replace("\n", "\x01")
    print("OK\t%s\t%s\t%s\t%s\t%s\t%s" % (st, iso, nm, sid, md, pr))
except Exception:
    print("PARSEFAIL\t\t\t\t\t\t")
' 2>/dev/null || printf 'PARSEFAIL\t\t\t\t\t\t')"

STATUS="$(printf '%s' "$PARSED" | cut -f1)"
SUBAGENT_TYPE="$(printf '%s' "$PARSED" | cut -f2)"
ISOLATION="$(printf '%s' "$PARSED" | cut -f3)"
NAME="$(printf '%s' "$PARSED" | cut -f4)"
SESSION_ID="$(printf '%s' "$PARSED" | cut -f5)"
MODEL_OVERRIDE="$(printf '%s' "$PARSED" | cut -f6)"
PROMPT="$(printf '%s' "$PARSED" | cut -f7- | tr '\001' '\n')"

# Fail-closed: an Agent spawn we cannot parse is blocked, never waved through.
if [ "$STATUS" = "PARSEFAIL" ]; then
  {
    echo "=== Teammate-spawn guard: BLOCKED ==="
    echo "  - Could not parse the Agent spawn payload to verify the spawn contract."
    echo "    Failing closed. Re-issue with isolation:\"worktree\" and a '<role>-<id>' name"
    echo "    (or, if this is a deliberate main-checkout run, add a"
    echo "    'main-checkout-run: <reason>' prompt line)."
    echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
  } >&2
  exit 2
fi

# Read-only agent types are exempt from the teammate contract (frictionless).
for a in $READONLY_ALLOWLIST; do
  if [ "$SUBAGENT_TYPE" = "$a" ]; then
    exit 0
  fi
done

# File-capable teammate: enforce the FULL correct-spawn contract.
PROBLEMS=()

# main-checkout-run: <reason> — a live prompt line (kept simple/best-effort by
# design; this is an auditable FALLBACK opt-out, not a security boundary — the
# boundary is guard-main-checkout-writes.sh blocking actual writes).
MAIN_CHECKOUT_MARKER=""
if printf '%s' "$PROMPT" | grep -qE '^[[:space:]]*main-checkout-run:[[:space:]]*.+'; then
  MAIN_CHECKOUT_MARKER="$(printf '%s' "$PROMPT" | grep -oE '^[[:space:]]*main-checkout-run:[[:space:]]*.+' | head -1 | sed -E 's/^[[:space:]]*//')"
fi

case "$ISOLATION" in
  worktree|remote) ;;
  *)
    if [ -n "$MAIN_CHECKOUT_MARKER" ]; then
      # Auditable fallback opt-out taken. Best-effort log — never fail the
      # spawn because logging failed; the marker itself is the audit trail.
      LOG_DIR="$REPO_ROOT/.claude/state"
      mkdir -p "$LOG_DIR" 2>/dev/null || true
      {
        printf '%s\tagent=%s\tname=%s\t%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "${SUBAGENT_TYPE:-<unset>}" \
          "${NAME:-<unset>}" \
          "$MAIN_CHECKOUT_MARKER"
      } >>"$LOG_DIR/main-checkout-runs.log" 2>/dev/null || true
    else
      PROBLEMS+=("missing native isolation — add  isolation: \"worktree\"  to run in an isolated worktree (got isolation='${ISOLATION:-unset}'); OR, if this is a deliberate main-checkout run, add a live prompt line starting with 'main-checkout-run: <reason>'.")
    fi
    ;;
esac

if ! printf '%s' "$NAME" | grep -qE "$NAME_SHAPE_RE"; then
  PROBLEMS+=("missing/malformed name — give a unique '<role>-<model>-<identifier>' name, e.g. dev-sonnet-1 / qa-opus-r3 (got name='${NAME:-unset}'). Needs THREE dash-joined parts (role, model, identifier). Never bare ('dev'), 2-part ('dev-1'), or run-together ('devsonnet1'). NOT relaxed by main-checkout-run:.")
else
  # Shape valid: split into role / <model> token / identifier.
  NAME_ROLE="${NAME%%-*}"
  NAME_REST="${NAME#*-}"
  NAME_MODEL_TOKEN="${NAME_REST%%-*}"
  NAME_ID="${NAME_REST#*-}"

  # Clause 2a — the <model> token must be a real alias.
  if ! model_in_allowed_set "$NAME_MODEL_TOKEN"; then
    PROBLEMS+=("model token '${NAME_MODEL_TOKEN}' in name '${NAME}' is not an allowed model — the <model> part of <role>-<model>-<identifier> must be one of: ${ALLOWED_MODELS// /, } (e.g. ${NAME_ROLE}-sonnet-${NAME_ID}). Extend ALLOWED_MODELS in orchestration.config if your harness accepts more.")
  else
    # Clause 2b — TRUTHFULNESS. Resolve the model this spawn boots on and
    # require the name token to match it.
    EXPECTED_MODEL="$(resolve_expected_model "$MODEL_OVERRIDE" "$SUBAGENT_TYPE")"
    if [ -n "$EXPECTED_MODEL" ] && [ "$NAME_MODEL_TOKEN" != "$EXPECTED_MODEL" ]; then
      if [ -n "$MODEL_OVERRIDE" ]; then
        MODEL_SRC="explicit model override '${MODEL_OVERRIDE}'"
      else
        MODEL_SRC="the '${SUBAGENT_TYPE}' agent definition's model: frontmatter"
      fi
      PROBLEMS+=("untruthful model token — the name claims '${NAME_MODEL_TOKEN}' but this spawn boots on '${EXPECTED_MODEL}' (from ${MODEL_SRC}). The <model> token MUST match the model the instance actually runs on. Fix: rename to '${NAME_ROLE}-${EXPECTED_MODEL}-${NAME_ID}', or change the model so it matches.")
    fi
    # else: expected model is undeterminable (no override AND no live-def
    # default, or model:"inherit" — the inherit-from-session case). We cannot
    # know the boot model, so we accept the (already-valid) alias token rather
    # than fail the spawn on unknowable information.
  fi
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  {
    echo "=== Teammate-spawn guard: BLOCKED ==="
    echo "  Agent '${SUBAGENT_TYPE:-<unset/general-purpose>}' can edit repo files, so it must satisfy the"
    echo "  teammate-spawn contract. It failed:"
    for p in "${PROBLEMS[@]}"; do
      echo "    - $p"
    done
    echo "  Re-issue the Agent call fixing the above."
    echo "  (If this agent is genuinely READ-ONLY, add its type to READONLY_ALLOWLIST"
    echo "   in orchestration.config.)"
    echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
  } >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# CLAUSE 3 — name reuse is structurally impossible.
# ---------------------------------------------------------------------------
# Only reached once isolation + name-format already pass (so we never record a
# name for a spawn that is being blocked for a different reason). Inert unless a
# session team dir resolves by EXACT match (so bare unit-test payloads with a
# nonexistent session are unaffected — existing suites stay green). The teams
# dir is read from orchestration.config (SESSION_TEAMS_DIR); tests override via
# GUARD_ISOLATION_TEAMS_DIR.
GI_TEAMS_DIR="${GUARD_ISOLATION_TEAMS_DIR:-$SESSION_TEAMS_DIR}"
GI_TEAM_DIR=""
if [ -n "$SESSION_ID" ]; then
  CANDIDATE="$GI_TEAMS_DIR/session-$(printf '%s' "$SESSION_ID" | cut -c1-8)"
  [ -d "$CANDIDATE" ] && GI_TEAM_DIR="$CANDIDATE"
fi

if [ -n "$GI_TEAM_DIR" ]; then
  # Union the three durable name-history sources and test NAME against it. Fail
  # OPEN on a resolver error (never invent a collision from an IO glitch); the
  # primary source (spawned-names.log) is written by this same hook so, absent
  # IO failure, it cannot miss a name spawned this session.
  REUSE_VERDICT="$(NAME_ARG="$NAME" python3 - "$GI_TEAM_DIR" 2>/dev/null <<'PY'
import json, os, sys

name = os.environ.get("NAME_ARG", "")
team_dir = sys.argv[1]
history = set()

# 1. self-maintained ledger (one name per line)
ledger = os.path.join(team_dir, "spawned-names.log")
try:
    with open(ledger, "r", encoding="utf-8") as f:
        for line in f:
            v = line.strip()
            if v:
                history.add(v)
except Exception:
    pass

# 2. roster config.json member names (any status)
try:
    with open(os.path.join(team_dir, "config.json"), "r", encoding="utf-8") as f:
        cfg = json.load(f)
    for m in cfg.get("members", []) or []:
        nm = m.get("name")
        if isinstance(nm, str) and nm:
            history.add(nm)
except Exception:
    pass

# 3. durable event logs — completed teammates that may be roster-pruned
for logname in ("idle-events.jsonl", "task-events.jsonl"):
    try:
        with open(os.path.join(team_dir, logname), "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t = rec.get("teammate")
                if isinstance(t, str) and t:
                    history.add(t)
    except Exception:
        pass

# The lead is not a spawnable teammate name; never treat it as a collision.
history.discard("team-lead")

print("REUSE" if name in history else "FRESH")
PY
)"
  # Fail-OPEN on a resolver error / empty output (never invent a collision).
  [ -n "$REUSE_VERDICT" ] || REUSE_VERDICT="FRESH"

  if [ "$REUSE_VERDICT" = "REUSE" ]; then
    {
      echo "=== Teammate-spawn guard: BLOCKED (name reuse) ==="
      echo "  The name '${NAME}' has ALREADY been used in this session's team"
      echo "  (active OR completed). Reusing a name causes latest-wins shadowing and"
      echo "  resumed-vs-respawned ambiguity, so it is forbidden — there is NO escape"
      echo "  hatch for this one."
      echo "  Fix: pick a FRESH '<role>-<identifier>' name. Identifiers are free —"
      echo "  bump the suffix (${NAME}-2 / ${NAME%%-*}-b / ${NAME%%-*}-0714) or use any"
      echo "  unused identifier. Never resume-vs-respawn by reusing a name."
      echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"
    } >&2
    exit 2
  fi

  # Record this allowed spawn's name (best-effort; never fail the spawn if the
  # append fails — the roster/event-log backstops still cover it).
  mkdir -p "$GI_TEAM_DIR" 2>/dev/null || true
  printf '%s\n' "$NAME" >>"$GI_TEAM_DIR/spawned-names.log" 2>/dev/null || true
fi

exit 0
