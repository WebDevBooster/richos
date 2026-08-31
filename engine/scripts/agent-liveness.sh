#!/usr/bin/env bash
#
# agent-liveness.sh — ONE AUTHORITATIVE ANSWER TO "IS THIS AGENT ALIVE?",
#                     and the call the lead owes himself before he says
#                     anything about an agent's state.
#
# ===========================================================================
# THE INCIDENT THIS ANSWERS
# ===========================================================================
# 2026-08-31, ~22:45. The lead told the CEO that `zach-opus-g1` was COMPLETED.
# It was not — the CEO's own screen showed it working, and its isolation
# worktree was locked the whole time. `git worktree list` said `locked`.
# `remove-agent-worktree.sh` REFUSED to remove it, for exactly the right
# reason. The lead called the lock "residue" and quoted the `ListAgents` roster
# instead, which said `completed`. The roster was stale; the lock was right; the
# CEO had to correct his own assistant from a screenshot.
#
# Doctrine already said "never infer an agent is dead from filesystem
# inactivity". What it had not anticipated is the inverse: A POSITIVE-LOOKING
# SIGNAL THAT IS WRONG. Absence prompts a check. A false `completed` does not.
#
# So: run this, do not read the roster.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   scripts/agent-liveness.sh                       every agent worktree
#   scripts/agent-liveness.sh <agent-id>            one, by id
#   scripts/agent-liveness.sh agent-<id>            same
#   scripts/agent-liveness.sh <worktree-path>       same, by path
#   scripts/agent-liveness.sh --json [target]       the full record
#
#   --entity <path>     the repository whose worktree locks are authoritative.
#                       Defaults to the resolved entity root (RICHOS_ENTITY_ROOT,
#                       else CLAUDE_PROJECT_DIR, else $PWD) — NEVER this
#                       script's own location, which is the ENGINE.
#   --transcript <path> a session transcript; attaches teammate NAMES to ids so
#                       the report reads in the vocabulary the lead thinks in.
#
# EXIT CODES — the verdict is IN the exit code as well as the text, so a script
# can branch on it without parsing prose:
#     0   NOT-ALIVE          (single target)
#    10   ALIVE              (single target)
#    11   INDETERMINATE      (single target)
#     2   usage / could not resolve an entity
#   With no target it sweeps and always exits 0 if the sweep ran: a sweep is a
#   report, and there is no single verdict to encode.
#
# INDETERMINATE IS A REAL ANSWER. It is not folded into either other verdict,
# here or in the library, because "I could not tell" and "it is dead" are the
# two things the 2026-08-31 defect confused.

set -eo pipefail

TAG="(<engine>/scripts/agent-liveness.sh)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { printf '%s\n' "$*" >&2; }

usage() {
    sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

ENTITY=""
TARGET=""
TRANSCRIPT=""
JSON=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --entity)     ENTITY="${2:-}"; shift 2 ;;
        --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
        --json)       JSON=1; shift ;;
        -h|--help)    usage; exit 2 ;;
        --)           shift; break ;;
        -*)           err "ERROR: unknown option: $1 $TAG"; exit 2 ;;
        *)
            if [ -z "$TARGET" ]; then TARGET="$1"; shift
            else err "ERROR: unexpected extra argument: $1 $TAG"; exit 2; fi ;;
    esac
done
[ -z "$TARGET" ] && [ "$#" -gt 0 ] && { TARGET="$1"; shift; }

command -v python3 >/dev/null 2>&1 || {
    err "ERROR: python3 is required. $TAG"; exit 2; }

# --- Resolve the ENTITY -----------------------------------------------------
# Same contract as remove-agent-worktree.sh, and for the same reason: under a
# by-reference engine this script's own location is the ENGINE, which is usually
# not the repository whose agents are being asked about.
if [ -z "$ENTITY" ]; then
    ENTITY="${RICHOS_LIVENESS_ENTITY:-}"
fi
if [ -z "$ENTITY" ]; then
    _RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
    if [ -f "$_RR_LIB" ]; then
        # shellcheck source=lib/resolve-roots.sh
        . "$_RR_LIB"
        if resolve_entity_root ""; then
            ENTITY="$RICHOS_ENTITY_ROOT_RESOLVED"
        fi
    fi
fi
if [ -z "$ENTITY" ]; then
    err "=== agent-liveness: NO ANSWER — no governed entity ==="
    err "  Could not resolve which repository's worktree locks are authoritative"
    err "  (status: ${RICHOS_ROOT_STATUS:-unknown}). The lock is the ONLY"
    err "  authoritative liveness signal, so there is nothing to read."
    err "  Pass --entity <path>, or run from a session seated in the entity."
    err "  $TAG"
    exit 2
fi

PY="$SCRIPT_DIR/lib/agent-liveness.py"
if [ ! -f "$PY" ]; then
    err "ERROR: the liveness resolver is missing at $PY — this script decides"
    err "       nothing itself and will not guess. $TAG"
    exit 2
fi

ARGS=(--entity "$ENTITY" --format json)
[ -n "$TARGET" ] && ARGS+=(--owner "$TARGET")
[ -n "$TRANSCRIPT" ] && ARGS+=(--transcript "$TRANSCRIPT")

OUT="$(python3 "$PY" "${ARGS[@]}")" || {
    err "ERROR: the liveness resolver failed. $TAG"; exit 2; }

if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$OUT"
    [ -n "$TARGET" ] || exit 0
    V="$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["verdict"] if isinstance(d,dict) else "")')"
    case "$V" in
        ALIVE) exit 10 ;;
        NOT-ALIVE) exit 0 ;;
        *) exit 11 ;;
    esac
fi

# --- Human rendering --------------------------------------------------------
# NAMES THE EVIDENCE, AND NAMES WHICH SOURCES DISAGREE. The second half is the
# point: on 2026-08-31 the answer was available and a contradicting source was
# believed over it, so a report that prints only the verdict rebuilds the
# defect one layer up.
#
# The JSON goes to the renderer through a FILE and not through a pipe. `python3
# - <<PY` already uses stdin for the script itself, so a piped payload arrives
# nowhere; that mistake fails loudly here (a JSONDecodeError at line 1) rather
# than quietly, but it fails, and this comment is why the file exists.
_AL_TMP="$(mktemp -t agent-liveness.XXXXXX)"
trap 'rm -f "$_AL_TMP"' EXIT
printf '%s' "$OUT" > "$_AL_TMP"

ENTITY="$ENTITY" python3 - "$_AL_TMP" <<'PY'
import json, os, sys

with open(sys.argv[1], encoding="utf-8") as _f:
    data = json.load(_f)
recs = data if isinstance(data, list) else [data]
entity = os.environ.get("ENTITY", "")

print("=== agent liveness — authoritative source: the isolation-worktree lock ===")
print("    entity: %s" % entity)
if not recs:
    print("    no agent worktrees registered.")
    sys.exit(0)

worst = "NOT-ALIVE"
for r in recs:
    v = r.get("verdict", "INDETERMINATE")
    if v == "ALIVE":
        worst = "ALIVE"
    elif v == "INDETERMINATE" and worst != "ALIVE":
        worst = "INDETERMINATE"
    names = r.get("names") or []
    label = r.get("agent_id") or r.get("target") or "?"
    if names:
        label = "%s  (%s)" % (label, ", ".join(names))
    print("")
    print("  %-13s %s" % (v, label))
    print("      why: %s" % r.get("reason", ""))
    ev = r.get("evidence") or {}
    bits = []
    if "worktree_path" in ev and ev.get("worktree_path"):
        bits.append("worktree=%s" % ev["worktree_path"])
    bits.append("registered=%s" % ev.get("registered"))
    bits.append("on-disk=%s" % ev.get("present_on_disk"))
    bits.append("locked=%s" % ev.get("locked"))
    if ev.get("pid") is not None:
        bits.append("pid=%s(alive=%s)" % (ev.get("pid"), ev.get("pid_alive")))
    if ev.get("pid_shared_with"):
        bits.append("pid shared with %d other lock(s) — it is the SESSION pid, "
                    "not a per-agent pid" % ev["pid_shared_with"])
    print("      evidence: %s" % ", ".join(str(b) for b in bits))

    src = r.get("sources") or {}
    ro = (src.get("roster") or {}).get("entries") or []
    if ro:
        for e in ro:
            print("      roster: session=%s name=%s status=%s  (advisory)"
                  % (e.get("session"), e.get("name"), e.get("status")))
    else:
        print("      roster: no session roster mentions this agent  (advisory)")
    we = (src.get("worker-events") or {}).get("entry")
    if we:
        print("      worker-events: last=%s at %s over %d record(s)  (advisory — "
              "WorkerRunEnded fires every turn, not at termination)"
              % (we.get("last_event"), we.get("last_timestamp"),
                 we.get("events_seen", 0)))
    else:
        print("      worker-events: no lifecycle record  (advisory)")

    dis = r.get("disagreements") or []
    if dis:
        print("      >>> SOURCES DISAGREE:")
        for d in dis:
            print("          - %s" % d)

print("")
print("  The lock decides. The roster and the event log are advisory and are")
print("  both known to go stale in the direction that reads as 'finished'.")
sys.exit({"ALIVE": 10, "NOT-ALIVE": 0}.get(worst, 11) if len(recs) == 1 else 0)
PY
