#!/usr/bin/env bash
#
# agent-finished-reap-worktrees.sh — TeammateIdle / TaskCompleted hook. Runs
# scripts/reap-stale-worktrees.sh so worktrees are swept WHEN AN AGENT
# FINISHES, not only when the next session opens.
#
# ===========================================================================
# WHY THIS EXISTS — THE THIRD SCOPE HOLE
# ===========================================================================
# The reaper had exactly one trigger: SessionStart. A twelve-hour session
# therefore accumulated everything and cleared nothing until the next session
# opened. On 2026-09-01 that produced `reaped=1 skipped=0 errors=0 residue=0`
# at 01:20 and 25 unswept worktrees by evening, with no sweep in between and
# nothing reporting the gap.
#
# ===========================================================================
# THE TIMING IS NOT A CONVENIENCE — IT IS WHEN THE EVIDENCE EXISTS
# ===========================================================================
# Read this before deciding this hook is redundant with the session-start one.
#
# A HAND-ROLLED worktree takes no lock, so the reaper cannot judge it directly;
# it judges the OWNER, from the owner's NATIVE isolation worktree lock. That
# native worktree is REMOVED at land time. So:
#
#   at agent-finish   the native worktree is still registered and now
#                     UNLOCKED — an OBSERVED positive termination signal, and
#                     the owner's hand-rolled trees become decidable
#   an hour later     the native worktree is gone; absence is not a
#                     termination signal, and those same trees are
#                     permanently `owner-unresolved`
#
# A session-start-only reaper is therefore structurally incapable of ever
# deciding a hand-rolled worktree, however often it runs. That is not a
# throughput argument, it is a correctness one.
#
# ===========================================================================
# WHAT IT IS NOT
# ===========================================================================
# It is NOT a second reaper. It runs the same canonical, sidecar-hashed
# scripts/reap-stale-worktrees.sh with the same gates as the session-start
# wrapper. Two reapers would be the original defect one level up: two sweeps,
# each certain about its own half, and neither able to say what the other
# missed.
#
# LOG-ONLY / NEVER BLOCKS, exactly like teammate-idle-handoff.sh: any failure
# is swallowed and this hook always exits 0. The reaper itself is the safety
# boundary (repo eligibility, lock, owner-termination signal, merged, clean,
# no live process — plus removal without --force and branch deletion without
# -D). This hook only decides WHEN.
#
# AUDIT TRAIL: every sweep appends one line to
#   <team-dir>/reap-events.jsonl
# carrying the summary AND coverage AND blind lines. A sweep nobody can read
# afterwards is how "reaped=1 residue=0" survived being wrong for months, so
# the denominator is written down where it outlives the transcript.
#
# NOTE ON STDIN — this hook does NOT read the payload, for the reason spelled
# out in session-start-reap-worktrees.sh: it is also a plain CLI tool, and in
# the CLI case stdin is an inherited pipe nobody closes, so an unconditional
# `cat` hangs (measured at 92 seconds inside the integrity probe before it was
# reverted; `[ ! -t 0 ]` does not help, an inherited pipe is not a TTY). It
# costs nothing here: the reaper resolves every root it needs by itself.
#
# TEST OVERRIDE: REAP_WORKTREES_ROOT retargets the SWEEP at another repo root
# (test-only; never set in a real session) and, exactly as in the session-start
# wrapper, SUPPRESSES --discover so a sandbox sweep can never reach out to the
# operator's real repositories. Only the sweep TARGET changes: the reaper is
# still resolved from THIS script's own location, so a sandbox sweep exercises
# the canonical, sidecar-hashed reaper rather than a copy of it.
#
# NOTE: hooks are snapshotted per session, so this hook takes effect from the
# NEXT session.

set -o pipefail

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
        echo "  hook: scripts/hooks/agent-finished-reap-worktrees.sh"
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

# HERMETIC UNDER THE TEST OVERRIDE. A sweep WRITES witnessed terminations into
# the ownership ledger and READS every transcript under the projects directory
# and the harness's live-session registry. Under REAP_WORKTREES_ROOT all three
# are pinned inside the sandbox unless the caller pinned them already, for the
# same reason discovery is suppressed: a unit test must never touch, or even
# read, the operator's real record.
if [ -n "${REAP_WORKTREES_ROOT:-}" ]; then
    export REAP_WORKTREE_LEDGER="${REAP_WORKTREE_LEDGER:-$REAP_WORKTREES_ROOT/.claude/state/worktree-ledger.jsonl}"
    export REAP_PROJECTS_DIR="${REAP_PROJECTS_DIR:-$REAP_WORKTREES_ROOT/.claude/projects-sandbox}"
    export RICHOS_SESSIONS_DIR="${RICHOS_SESSIONS_DIR:-$REAP_WORKTREES_ROOT/.claude/sessions-sandbox}"
fi

# TWO ROOTS. The reaper SCRIPT is an ENGINE asset; the tree it SWEEPS is the
# ENTITY.
REAPER="$ENGINE_ROOT/scripts/reap-stale-worktrees.sh"

if resolve_entity_root ""; then
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-$RICHOS_ENTITY_ROOT_RESOLVED}"
else
    SWEEP_ROOT="${REAP_WORKTREES_ROOT:-}"
fi

# Discovery is suppressed under the test override, and ONLY under it. A
# sandbox sweep that reached the `engine`, `inflight-repos`, `event-logs`,
# `ledger` and `neighborhood` sources would run --execute against the
# operator's real checkouts from inside a unit test. That is not a hypothetical
# — the probe's own canary drives this wrapper.
DISCOVER_ARGS="--discover"
if [ -n "${REAP_WORKTREES_ROOT:-}" ]; then
    DISCOVER_ARGS=""
fi

if [ "$RICHOS_ROOT_STATUS" = "broken" ] && [ -z "${REAP_WORKTREES_ROOT:-}" ]; then
    printf '%s\n' "$(root_failure_banner "scripts/hooks/agent-finished-reap-worktrees.sh")" >&2
    SUMMARY="ROOT RESOLUTION FAILURE — the agent-finished worktree reaper could not resolve the repository it governs, so NO worktrees were swept. ${RICHOS_ROOT_REASON}"
elif [ -z "$SWEEP_ROOT" ]; then
    SUMMARY="agent-finished worktree reap: not run — this repository has not adopted the engine (no orchestration.config at its root). Nothing was swept."
elif [ ! -x "$REAPER" ]; then
    printf '%s\n' "$(require_asset "$REAPER" "scripts/hooks/agent-finished-reap-worktrees.sh" "the worktree reaper (an ENGINE asset)")" >&2
    SUMMARY="ENGINE INSTALL FAILURE — scripts/reap-stale-worktrees.sh is missing or not executable at $REAPER. No worktrees were swept. This is a broken engine install, NOT a routine skip."
else
    # shellcheck disable=SC2086
    RAW_OUTPUT="$("$REAPER" "$SWEEP_ROOT" --execute --unlock-stale $DISCOVER_ARGS 2>&1)" || true
    SUMMARY_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== summary' || true)"
    COVERAGE_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== coverage' || true)"
    # THE VERDICT LEADS. `reaped=5 skipped=49 errors=0` is success-shaped and
    # was printed on 2026-09-02 for a run in which zero of the 47 real offenders
    # could ever be touched; `undecidable=47` sat beside it as information. The
    # reaper now closes every run with a verdict line, and this wrapper puts it
    # FIRST — a FAIL is announced as one, before any count.
    VERDICT_LINE="$(printf '%s\n' "$RAW_OUTPUT" | grep -m1 '^=== verdict' || true)"
    VERDICT_WORD="$(printf '%s' "$VERDICT_LINE" | sed -n 's/^=== verdict: \([A-Z]*\).*/\1/p')"
    if [ -n "$SUMMARY_LINE" ] && [ "$VERDICT_WORD" = "FAIL" ]; then
        SUMMARY="WORKTREE REAP FAIL [$SWEEP_ROOT]: ${VERDICT_LINE#=== } | ${SUMMARY_LINE#=== } ${COVERAGE_LINE#=== }"
    elif [ -n "$SUMMARY_LINE" ]; then
        SUMMARY="agent-finished worktree reap [$SWEEP_ROOT]: ${VERDICT_LINE#=== } | ${SUMMARY_LINE#=== } ${COVERAGE_LINE#=== }"
    else
        SUMMARY="agent-finished worktree reap [$SWEEP_ROOT]: ran but produced no summary line — check reaper output manually if worktrees seem stuck"
    fi
fi

# --- Durable audit line ------------------------------------------------------
# The transcript is not a record. This is.
if command -v python3 >/dev/null 2>&1; then
    SUMMARY="$SUMMARY" \
    RAW_OUTPUT="${RAW_OUTPUT:-}" \
    REAP_TEAM_DIR_OVERRIDE="${REAP_TEAM_DIR:-}" \
    python3 - <<'PY' 2>/dev/null || true
import json
import os
from datetime import datetime, timezone

home = os.path.expanduser("~")
base = os.environ.get("REAP_TEAM_DIR_OVERRIDE") or os.path.join(home, ".claude", "teams")
team_dir = None
try:
    candidates = [
        os.path.join(base, n)
        for n in sorted(os.listdir(base))
        if n.startswith("session-") and os.path.isdir(os.path.join(base, n))
    ]
    if candidates:
        team_dir = max(candidates, key=os.path.getmtime)
except Exception:
    team_dir = None

log_path = (os.path.join(team_dir, "reap-events.jsonl") if team_dir
            else os.path.join(home, ".claude", "reap-events.jsonl"))

raw = os.environ.get("RAW_OUTPUT", "")
record = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "event": "AgentFinishedReap",
    "summary": os.environ.get("SUMMARY", ""),
    # Every declared blind spot, carried forward. A sweep's denominator is
    # part of its result, not commentary on it.
    "blind": [ln[len("=== blind: "):-len(" ===")]
              for ln in raw.splitlines()
              if ln.startswith("=== blind: ") and ln.endswith(" ===")],
    "reaped": [ln.split(" ", 1)[1] for ln in raw.splitlines() if ln.startswith("REAP ")],
    "swept_branches": [ln.split(" ", 1)[1] for ln in raw.splitlines() if ln.startswith("SWEEP-BRANCH ")],
    "orphan_processes": [ln for ln in raw.splitlines() if ln.startswith("ORPHAN-PROCESS ")],
    # The verdict, as its own field, so a reader of this log never has to
    # parse the summary sentence to learn whether the sweep FAILED.
    "verdict": next((ln[len("=== verdict: "):].split(" ", 1)[0].rstrip(" —")
                     for ln in raw.splitlines() if ln.startswith("=== verdict: ")), ""),
    "unresolved": next((int(m) for ln in raw.splitlines() if ln.startswith("=== coverage")
                        for m in [ln.split("unresolved=", 1)[1].split(" ", 1)[0]]
                        if m.isdigit()), None),
}

try:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
except Exception:
    pass
PY
fi

# The harness does not consume additionalContext on these events, so the
# summary goes to stderr where an operator tailing the session can see it,
# and to the log above where it outlives the session.
printf '%s\n' "$SUMMARY" >&2
exit 0
