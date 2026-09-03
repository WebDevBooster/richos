#!/usr/bin/env bash
#
# reap-stale-worktrees.test.sh — behavioral tests for the reaper's SCOPE and
# its SAFETY RULE.
#
# ===========================================================================
# WHAT THIS SUITE IS FOR, AND WHY IT IS NOT THE WRAPPER'S SUITE
# ===========================================================================
# scripts/hooks/session-start-reap-worktrees.test.sh already covers the
# SessionStart wrapper: does it run, does it fail open, does it refuse a dirty
# tree. Every one of those cases was green on 2026-09-01, the morning the
# reaper printed `reaped=1 skipped=0 errors=0 residue=0` while 25 worktrees sat
# unswept all day in two repositories it had never been pointed at, under a
# path convention it did not recognize, with no trigger between session starts.
#
# The old suite could not have caught that, because every one of its fixtures
# was ONE repository containing ONLY native `.claude/worktrees/agent-*` trees —
# the shape the reaper already handled. A suite built entirely out of the case
# that works cannot fail on the case that does not.
#
# So this suite is built out of the shape that actually accumulates: a SECOND
# repository, discovered rather than named, holding HAND-ROLLED worktrees that
# take no lock.
#
# Cases 15-21 (2026-09-02) are the ones the first fourteen could not express:
# an owner judged from the OWNERSHIP LEDGER after its native worktree is gone
# (a prior session's worktree, the case every earlier fix failed), a witnessed
# termination surviving the land, the orphan-branch pass, and the verdict line
# that turns an unjudgeable backlog into a FAILURE instead of a routine count.
#
# ===========================================================================
# THE RULE UNDER TEST — and it is the dangerous one
# ===========================================================================
# A native worktree carries its own liveness signal: it is locked while its
# agent runs. A hand-rolled worktree carries NOTHING. Quiet is not death there,
# and reaping a live agent's worktree destroys uncommitted work.
#
# So the reaper judges a hand-rolled tree's OWNER, from the owner's native
# isolation-worktree lock, and it distinguishes two things that look identical
# in a verdict string:
#
#   the owner's native worktree is REGISTERED and unlocked  -> OBSERVED
#                                                              termination
#   the owner's native worktree is ABSENT                   -> an ABSENCE
#
# Both make the resolver say NOT-ALIVE. Only the first is a termination signal.
# Case 7 below is the one that pins the difference, and it is the case that
# stops this tool from inferring death from filesystem inactivity — which is
# the exact inference project doctrine forbids.
#
# Every fixture is a throwaway repository under mktemp with every discovery
# source redirected into the sandbox, so no real checkout is ever reachable.
#
# Run directly: scripts/reap-stale-worktrees.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/reap-stale-worktrees.sh"

PASS=0
FAIL=0
# `pwd -P` matters: on macOS mktemp hands back a /var/... symlink while
# `git worktree list` reports the resolved /private/var/... path, so an
# unresolved sandbox root would defeat every path comparison below and the
# cases would pass for the wrong reason.
SANDBOX="$(cd "$(mktemp -d -t reap-scope-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$REAPER" ]; then
    echo "FATAL: reaper missing/non-executable: $REAPER" >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

# --- fixture helpers ---------------------------------------------------------
# NO local git identity override anywhere below: these throwaway repos inherit
# the operator's real global identity, which is what a machine-wide pre-commit
# identity guard requires. With a fake identity the seed commit is REFUSED, the
# repo has no `main`, every `worktree add` fails, and every case silently
# exercises an empty repository — the failure shape this engine has already
# been bitten by once.

seed_repo() { # <path> [adopted]
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    printf 'seed\n' >"$repo/seed.txt"
    [ "${2:-}" = "adopted" ] && printf 'PROTECTED_PATHS="src"\n' >"$repo/orchestration.config"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m seed
    printf '%s\n' "$repo"
}

add_native() { # <entity> <agent-id> [lock-pid]
    local repo="$1" aid="$2" pid="${3:-}"
    mkdir -p "$repo/.claude/worktrees"
    git -C "$repo" worktree add -q -b "worktree-agent-$aid" "$repo/.claude/worktrees/agent-$aid"
    if [ -n "$pid" ]; then
        git -C "$repo" worktree lock \
            --reason "claude agent agent-$aid (pid $pid start test)" \
            "$repo/.claude/worktrees/agent-$aid"
    fi
}

# add_handrolled <repo> <container> <name> [owner-agent-id] [session-pid]
# SINCE 2026-09-03 ownership is EXACT PATH ONLY (docs/plans/worktree-real-fix-
# 2026-09-03.md): a hand-rolled tree is judged from a ledger record naming its
# exact path, never from its branch or directory name and never from a
# transcript's name join. So a tree that is meant to have a KNOWN owner is
# registered here by path, the way scripts/create-teammate-worktree.sh
# writes it; a tree created without an owner is exactly the unrecorded shape
# the reaper must report as owner-unresolved.
add_handrolled() {
    local repo="$1" container="$2" name="$3" aid="${4:-}" pid="${5:-}"
    mkdir -p "$container"
    git -C "$repo" worktree add -q -b "$name" "$container/$name"
    if [ -n "$aid" ]; then
        local dir; dir="$(cd "$container/.." && pwd -P)"
        local args=(registered --teammate "$name" --agent-id "$aid" --session-id sess-now \
                    --repo "$repo" --worktree "$container/$name" --branch "$name" --class hand-rolled)
        [ -n "$pid" ] && args+=(--session-pid "$pid" --pid-start "$MY_START")
        python3 "$LEDGER_PY" --ledger "$dir/wt-ledger.jsonl" record "${args[@]}" >/dev/null
    fi
}

# write_transcript <file> <name>=<agentid> ...
# The name -> agentId join, in exactly the shape scripts/lib/agent-liveness.py
# reads it from a real session transcript: an assistant `tool_use` named Agent
# carrying the teammate name, joined by tool_use_id to a `tool_result` whose
# toolUseResult carries the agentId.
write_transcript() {
    local out="$1"; shift
    python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
with open(out, "w", encoding="utf-8") as f:
    for i, spec in enumerate(sys.argv[2:]):
        name, aid = spec.split("=", 1)
        tu = "tu%d" % i
        f.write(json.dumps({"message": {"content": [
            {"type": "tool_use", "name": "Agent", "id": tu,
             "input": {"name": name}}]}}) + "\n")
        f.write(json.dumps({"message": {"content": [
            {"type": "tool_result", "tool_use_id": tu}]},
            "toolUseResult": {"agentId": aid}}) + "\n")
PY
}

spawned_names() { # <case-dir> <name> ...
    local dir="$1/teams/session-test"; shift
    mkdir -p "$dir"
    printf '%s\n' "$@" >"$dir/spawned-names.log"
}

# run_reaper <case-dir> <entity> [extra args...]
# Discovery restricted to primary+neighborhood and every stateful path pinned
# inside the case directory — INCLUDING the ownership ledger, which a sweep
# WRITES witnessed terminations into: this suite must never be able to see,
# let alone touch, a real repository or the operator's real record.
RC=0
run_reaper() {
    local dir="$1" entity="$2"; shift 2
    local out
    # The process table and the harness's session registry are PINNED so the
    # exhaustion rule (worktree-ledger.py) means the same thing on every
    # machine: one claude process — this shell — started at epoch 0, with no
    # registry row, so it is UNACCOUNTED and exhaustion alone never decides.
    # Cases that want exhaustion to decide write a registry row themselves.
    out="$(REAP_DISCOVERY_SOURCES="primary,neighborhood" \
           REAP_TEAM_DIR="$dir/teams" \
           REAP_LEDGER="$dir/ledger.txt" \
           REAP_WORKTREE_LEDGER="$dir/wt-ledger.jsonl" \
           REAP_PROJECTS_DIR="$dir/projects" \
           RICHOS_CLAUDE_PROCESSES="${REAP_TEST_PROCS:-$$:0}" \
           RICHOS_SESSIONS_DIR="$dir/sessions" \
           CLAUDE_PID="$$" \
           "$REAPER" "$entity" --discover --entity "$entity" \
               --transcript "$dir/transcript.jsonl" "$@" 2>&1)"
    RC=$?
    printf '%s' "$out"
    # RC is set inside this function, and every caller invokes it inside a
    # command substitution — a SUBSHELL, so the assignment never reached the
    # caller and `[ "$RC" -eq 0 ]` was true in every case by initialization.
    # Discovered 2026-09-02 when case 6 reported rc=0 beside a verdict line
    # that had exited 3. The code is returned, and every caller captures $?.
    return "$RC"
}

LEDGER_PY="$SCRIPT_DIR/lib/worktree-ledger.py"
# ledger_record <case-dir> <args...> — write straight into the case's ledger.
ledger_record() {
    local dir="$1"; shift
    python3 "$LEDGER_PY" --ledger "$dir/wt-ledger.jsonl" record "$@" >/dev/null
}
MY_START="$(python3 "$LEDGER_PY" pid-start "$$")"
# A pid that provably no longer exists, with the start time it had while it
# did: the identity of a session that has ended.
sleep 5 &
DEAD_PID=$!
DEAD_START="$(python3 "$LEDGER_PY" pid-start "$DEAD_PID")"
kill "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null || true

# A complete two-repository world: an entity holding the native isolation
# worktrees (the liveness evidence) and a sibling repository holding the
# hand-rolled ones, reachable only because it sits beside the entity.
#
#   <dir>/entity                          adopted, native agent-live + agent-done
#   <dir>/other                           the sibling nothing points at
#   <dir>/other-wt/<name>                 hand-rolled worktrees of the sibling
#
# live-owner -> agent-live (LOCKED by a running pid)
# done-owner -> agent-done (registered, unlocked: an OBSERVED termination)
make_world() { # <case-name> -> prints the case dir
    local dir="$SANDBOX/$1"
    mkdir -p "$dir"
    seed_repo "$dir/entity" adopted >/dev/null
    seed_repo "$dir/other" >/dev/null
    add_native "$dir/entity" "live" "$$"
    add_native "$dir/entity" "done"
    write_transcript "$dir/transcript.jsonl" "live-owner=live" "done-owner=done"
    spawned_names "$dir" live-owner done-owner
    printf '%s\n' "$dir"
}

echo "=== reap-stale-worktrees (scope + safety) tests ==="

# 1. DISCOVERY. A sibling repository nothing names is swept. This is scope hole
#    #1, and it is the one that let 25 worktrees accumulate in repositories the
#    reaper had never been pointed at.
DIR="$(make_world discovery)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q -- "--- repo: $DIR/other "; then
    ok "a sibling repository, named by nothing, is discovered and swept"
else
    bad "discovery (rc=$RC)"
fi

# 1b. NEGATIVE CONTROL for case 1. Without --discover the same world yields the
#     OLD behavior — one repository — and says so in `blind:` rather than
#     letting the summary imply it looked everywhere. A discovery test that
#     never sees the undiscovered case proves nothing about discovery.
OUT="$(REAP_TEAM_DIR="$DIR/teams" REAP_LEDGER="$DIR/ledger.txt" REAP_WORKTREE_LEDGER="$DIR/wt-ledger.jsonl" \
       "$REAPER" "$DIR/entity" --entity "$DIR/entity" 2>&1)"
if ! printf '%s' "$OUT" | grep -q -- "--- repo: $DIR/other " \
   && printf '%s' "$OUT" | grep -q '=== blind: discovery is OFF'; then
    ok "without --discover only the primary repo is swept, and the gap is DECLARED"
else
    bad "no-discover control"
fi

# 2. THE SAFETY RULE. A hand-rolled worktree whose owner is ALIVE is never
#    selected — not merged-and-clean, not anything. This is the case that
#    destroys a live agent's uncommitted work if it regresses.
DIR="$(make_world live-owner)"
add_handrolled "$DIR/other" "$DIR/other-wt" live-owner live "$$"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/live-owner" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP live-owner owner-alive'; then
    ok "hand-rolled worktree of a LIVE owner survives --execute (owner-alive)"
else
    bad "live owner (rc=$RC dir=$([ -d "$DIR/other-wt/live-owner" ] && echo present || echo GONE))"
fi

# 3. NOT GUTTED. An owner that terminated OBSERVABLY, merged and clean, IS
#    reaped. Without this the suite would pass against a reaper that refuses
#    everything, which is the "satisfied by a corpse" failure.
DIR="$(make_world done-owner)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
BRANCH_GONE=1
git -C "$DIR/other" rev-parse --verify --quiet refs/heads/done-owner >/dev/null && BRANCH_GONE=0
if [ "$RC" -eq 0 ] && [ ! -d "$DIR/other-wt/done-owner" ] && [ "$BRANCH_GONE" -eq 1 ]; then
    ok "hand-rolled worktree of an observably terminated owner is reaped, branch deleted"
else
    bad "terminated owner (rc=$RC branch_gone=$BRANCH_GONE)"
fi

# 4. UNMERGED IS NEVER REAPED — even with a positive termination signal. The
#    commits are the handoff.
DIR="$(make_world unmerged)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
printf 'committed but never landed\n' >"$DIR/other-wt/done-owner/work.txt"
git -C "$DIR/other-wt/done-owner" add work.txt
git -C "$DIR/other-wt/done-owner" commit -q -m "unlanded handoff"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$DIR/other-wt/done-owner/work.txt" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP done-owner unmerged(+1)'; then
    ok "hand-rolled worktree with unlanded commits survives (unmerged)"
else
    bad "unmerged hand-rolled (rc=$RC)"
fi

# 5. DIRTY IS NEVER REAPED — uncommitted work outranks every other signal.
DIR="$(make_world dirty)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
printf 'uncommitted\n' >"$DIR/other-wt/done-owner/scratch.txt"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$DIR/other-wt/done-owner/scratch.txt" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP done-owner dirty(1)'; then
    ok "hand-rolled worktree with uncommitted work survives (dirty)"
else
    bad "dirty hand-rolled (rc=$RC)"
fi

# 6. AN UNKNOWN OWNER IS UNDECIDABLE, NOT DEAD. A worktree whose name matches
#    no agent is left alone and counted, rather than swept because nothing
#    objected.
DIR="$(make_world unknown-owner)"
# done-owner is what makes the sibling reap-eligible at all; without it the
# repository would be report-only and this case would pass for the wrong
# reason — a stranger's tree skipped by gate 0 rather than by gate 2.
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
# The tree is TEAMMATE-SHAPED (<role>-<model>-<identifier>) and nothing
# records it: that is a hole in the record, and the case that must FAIL.
add_handrolled "$DIR/other" "$DIR/other-wt" nobody-opus-x9
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 3 ] && [ -d "$DIR/other-wt/nobody-opus-x9" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP nobody-opus-x9 owner-unresolved' \
   && printf '%s' "$OUT" | grep -q '^=== verdict: FAIL — unresolved=1 '; then
    ok "hand-rolled worktree with an unresolvable owner survives (owner-unresolved), and the run is a FAIL (exit 3)"
else
    bad "unknown owner (rc=$RC verdict=$(printf '%s' "$OUT" | grep '^=== verdict' || echo NONE))"
fi

# 7. THE CASE THE WHOLE SAFETY RULE TURNS ON.
#    The owner's native isolation worktree is ABSENT. The liveness resolver
#    says NOT-ALIVE for that — and it is an ABSENCE, not an observation. Doctrine:
#    never infer an agent is dead from filesystem inactivity; require a positive
#    termination signal. So the tree survives, and it survives even though it is
#    merged, clean, unlocked and has no live process — every OTHER gate open.
DIR="$(make_world absent-native)"
add_handrolled "$DIR/other" "$DIR/other-wt" ghost-owner ghost
write_transcript "$DIR/transcript.jsonl" "live-owner=live" "done-owner=done" "ghost-owner=ghost"
spawned_names "$DIR" live-owner done-owner ghost-owner
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
# The reason string is asserted, not just the survival: this branch and case
# 6's "no agent matches" branch both print owner-unresolved, and they are
# different findings. `ghost-owner` DOES resolve to a real agent — the agent's
# isolation worktree is simply not there. Matching the generic prefix would let
# a regression that collapses the two read as a pass.
# The owner IS known (a path registration names agent `ghost`), so this is
# INDETERMINATE — a PENDING verdict, exit 0 — not UNRESOLVED. The two are
# counted apart precisely because only one of them grows forever.
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/ghost-owner" ] \
   && printf '%s' "$OUT" | grep -q "^SKIP ghost-owner owner-indeterminate(ghost-owner — no session identity on record for agent ghost (ghost-owner) and its isolation worktree is absent; absence is not a termination signal" \
   && printf '%s' "$OUT" | grep -q '^=== verdict: PENDING — indeterminate=1 '; then
    ok "owner whose isolation worktree is ABSENT (and no session identity recorded) is INDETERMINATE, never reaped, verdict PENDING"
else
    bad "absent native worktree (rc=$RC dir=$([ -d "$DIR/other-wt/ghost-owner" ] && echo present || echo GONE) line=$(printf '%s' "$OUT" | grep '^SKIP ghost-owner' || echo NONE))"
fi

# 8. DETACHED HEAD -> no-branch. There is nothing to check mergedness against,
#    and unverifiable is not permission.
#    The detached tree is deliberately owned by an agent that terminated
#    OBSERVABLY, so gate 2 passes and gate 3 is the gate actually under test.
#    Left unowned it would be skipped as owner-unresolved and this case would
#    prove nothing about the branch gate at all.
DIR="$(make_world detached)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
git -C "$DIR/other" worktree add -q --detach "$DIR/other-wt/detached-tree"
ledger_record "$DIR" registered --teammate detached-tree --agent-id done --session-id sess-now \
    --repo "$DIR/other" --worktree "$DIR/other-wt/detached-tree" --class hand-rolled
write_transcript "$DIR/transcript.jsonl" "live-owner=live" "done-owner=done" "detached-tree=done"
spawned_names "$DIR" live-owner done-owner detached-tree
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/detached-tree" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP detached-tree no-branch'; then
    ok "detached-HEAD worktree survives (no-branch)"
else
    bad "detached HEAD (rc=$RC)"
fi

# 9. REPORT-ONLY REPOSITORIES. A repository found only by the neighborhood scan
#    that holds no worktree owned by a teammate this machine recorded spawning
#    is inventoried and NEVER mutated. Discovery is allowed to be generous
#    exactly because removal is not.
DIR="$(make_world report-only)"
seed_repo "$DIR/stranger" >/dev/null
mkdir -p "$DIR/stranger-wt"
git -C "$DIR/stranger" worktree add -q -b some-branch "$DIR/stranger-wt/some-branch"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ -d "$DIR/stranger-wt/some-branch" ] \
   && printf '%s' "$OUT" | grep -q -- "--- repo: $DIR/stranger .*report-only" \
   && printf '%s' "$OUT" | grep -q '^SKIP some-branch report-only-repo'; then
    ok "a repository nobody's teammate touched is inventoried, never mutated"
else
    bad "report-only repo (rc=$RC)"
fi

# 10. THE LEDGER MUST NOT LAUNDER ELIGIBILITY. It carries eligibility forward;
#     it never confers it. Written wrong the first time and caught on the
#     second run of the rewrite: recording every DISCOVERED repository meant a
#     neighborhood-only repository was in the ledger, and the next sweep's
#     `ledger` source made it reap-eligible — the report-only boundary
#     evaporating after exactly one sweep, silently.
REAP_DISCOVERY_SOURCES="primary,neighborhood,ledger" REAP_TEAM_DIR="$DIR/teams" \
    REAP_LEDGER="$DIR/ledger.txt" REAP_WORKTREE_LEDGER="$DIR/wt-ledger.jsonl" REAP_PROJECTS_DIR="$DIR/projects" \
    "$REAPER" "$DIR/entity" --discover --entity "$DIR/entity" \
        --transcript "$DIR/transcript.jsonl" >/dev/null 2>&1
if [ -f "$DIR/ledger.txt" ] && ! grep -qxF "$DIR/stranger" "$DIR/ledger.txt" \
   && grep -qxF "$DIR/entity" "$DIR/ledger.txt"; then
    ok "the ledger records reap-eligible repositories only (no eligibility laundering)"
else
    bad "ledger contents: $(cat "$DIR/ledger.txt" 2>/dev/null | tr '\n' ' ')"
fi

# 11. THE DENOMINATOR IS REPORTED. `reaped=1 residue=0` was true and useless on
#     2026-09-01 because nothing said what it was a fraction of.
DIR="$(make_world coverage)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
add_handrolled "$DIR/other" "$DIR/other-wt" live-owner live "$$"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if printf '%s' "$OUT" | grep -q '^=== coverage (DRY-RUN): repos=2 ' \
   && printf '%s' "$OUT" | grep -q 'worktrees=4 native=2 hand-rolled=2' \
   && printf '%s' "$OUT" | grep -q '^=== sources:'; then
    ok "coverage line reports repos, worktrees, class split and undecidables"
else
    bad "coverage line: $(printf '%s' "$OUT" | grep '^=== coverage' || echo NONE)"
fi

# 12. A BLIND SPOT IS DECLARED, NOT DROPPED. Without the name -> agentId join
#     there is no owner liveness at all, so EVERY hand-rolled tree is
#     undecidable — and the report has to say that rather than skip quietly.
DIR="$(make_world blind)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
rm -f "$DIR/transcript.jsonl"
OUT="$(REAP_DISCOVERY_SOURCES="primary,neighborhood" REAP_TEAM_DIR="$DIR/teams" \
       REAP_LEDGER="$DIR/ledger.txt" REAP_WORKTREE_LEDGER="$DIR/wt-ledger.jsonl" REAP_PROJECTS_DIR="$DIR/projects" \
       "$REAPER" "$DIR/entity" --discover --entity "$DIR/entity" --execute 2>&1)"
if [ -d "$DIR/other-wt/done-owner" ] \
   && printf '%s' "$OUT" | grep -q '=== blind: owner liveness: no session transcript' \
   && printf '%s' "$OUT" | grep -q '=== blind: owner liveness: no ownership ledger exists yet' \
   && printf '%s' "$OUT" | grep -q '^SKIP done-owner owner-unresolved'; then
    ok "with no transcript and no ledger every hand-rolled tree survives and BOTH blindnesses are DECLARED"
else
    bad "declared blindness"
fi

# 13. RESIDUE AND ORPHANED PROCESSES ARE SCOPED TO REAL CONTAINERS. A directory
#     that merely happens to contain one worktree is not a worktree container —
#     the first run of this rewrite made /private/tmp one and reported 39
#     launchd sockets as residue. A signal buried in noise is a signal ignored.
DIR="$(make_world containers)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
mkdir -p "$DIR/other-wt/leftover-junk"
for i in 1 2 3 4 5 6; do mkdir -p "$DIR/scattered/not-a-worktree-$i"; done
git -C "$DIR/other" worktree add -q -b lonely "$DIR/scattered/lonely"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if printf '%s' "$OUT" | grep -q "^RESIDUE $DIR/other-wt/leftover-junk " \
   && ! printf '%s' "$OUT" | grep -q "^RESIDUE $DIR/scattered/not-a-worktree-1 " \
   && printf '%s' "$OUT" | grep -q "=== blind: '$DIR/scattered' holds a registered worktree"; then
    ok "residue is reported in a real container and the mostly-not-worktrees directory is declared blind"
else
    bad "container qualification"
fi

# 14. IDEMPOTENCE. A second sweep of an already-swept world is a clean no-op,
#     not a second round of errors.
DIR="$(make_world idempotent)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
run_reaper "$DIR" "$DIR/entity" --execute >/dev/null
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'reaped=0 ' \
   && printf '%s' "$OUT" | grep -q 'errors=0'; then
    ok "second sweep is a clean no-op (nothing reaped twice, no errors)"
else
    bad "idempotence (rc=$RC summary=$(printf '%s' "$OUT" | grep '^=== summary'))"
fi

# 15. THE ACCEPTANCE TEST — A WORKTREE FROM A PRIOR SESSION IS REAPED.
#     No native worktree in the entity (the land removed it long ago), no
#     transcript row for the name (that session's transcript lives under a
#     project directory nobody sweeps). Only the ledger knows: the owner was
#     registered with a session pid + start time, and that process is gone.
#     Every one of the four earlier fixes left this tree owner-undecidable.
DIR="$(make_world prior-session)"
add_handrolled "$DIR/other" "$DIR/other-wt" zach-opus-old1
ledger_record "$DIR" registered --teammate zach-opus-old1 --agent-id old1 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$DIR/entity" \
    --worktree "$DIR/other-wt/zach-opus-old1" --class native
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
BRANCH_GONE=1
git -C "$DIR/other" rev-parse --verify --quiet refs/heads/zach-opus-old1 >/dev/null && BRANCH_GONE=0
if [ "$RC" -eq 0 ] && [ ! -d "$DIR/other-wt/zach-opus-old1" ] && [ "$BRANCH_GONE" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q '(owner zach-opus-old1 terminated — its host session pid .* is gone'; then
    ok "PRIOR SESSION: a hand-rolled worktree whose owner's session is provably gone is reaped from the ledger alone — no native worktree, no transcript"
else
    bad "prior-session reap (rc=$RC dir=$([ -d "$DIR/other-wt/zach-opus-old1" ] && echo present || echo gone) branch_gone=$BRANCH_GONE)"
fi

# 15b. NEGATIVE CONTROL: same registration shape, but the session is THIS
#      process — still running. INDETERMINATE, PENDING, untouched, and the pid
#      is named so an operator can see what it is waiting on.
DIR="$(make_world live-session)"
add_handrolled "$DIR/other" "$DIR/other-wt" zach-opus-now1
ledger_record "$DIR" registered --teammate zach-opus-now1 --agent-id now1 --session-id sess-now \
    --session-pid "$$" --pid-start "$MY_START" --repo "$DIR/entity" \
    --worktree "$DIR/other-wt/zach-opus-now1" --class native
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/zach-opus-now1" ] \
   && printf '%s' "$OUT" | grep -q "^SKIP zach-opus-now1 owner-indeterminate(zach-opus-now1 — no native isolation worktree is registered for agent now1 (zach-opus-now1) while its session pid $$ is still running" \
   && printf '%s' "$OUT" | grep -q '^=== verdict: PENDING'; then
    ok "LIVE SESSION, native absent: INDETERMINATE naming the pid, verdict PENDING, nothing removed"
else
    bad "live-session control (rc=$RC dir=$([ -d "$DIR/other-wt/zach-opus-now1" ] && echo present || echo GONE) line=$(printf '%s' "$OUT" | grep '^SKIP zach-opus-now1' || echo NONE))"
fi

# 15c. PID REUSED: the pid is running but its start time is not the recorded
#      one. A bare kill -0 would say alive; the identity check says gone.
DIR="$(make_world pid-reuse)"
add_handrolled "$DIR/other" "$DIR/other-wt" zach-opus-reuse1
ledger_record "$DIR" registered --teammate zach-opus-reuse1 --agent-id reuse1 --session-id sess-x \
    --session-pid "$$" --pid-start "Mon 1 Jan 00:00:00 1990" --repo "$DIR/entity" \
    --worktree "$DIR/other-wt/zach-opus-reuse1" --class native
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -d "$DIR/other-wt/zach-opus-reuse1" ] \
   && printf '%s' "$OUT" | grep -q 'terminated — its host session pid .* is reused'; then
    ok "PID REUSE: a running pid with a different start time is a gone session — reaped"
else
    bad "pid reuse (rc=$RC dir=$([ -d "$DIR/other-wt/zach-opus-reuse1" ] && echo present || echo gone))"
fi

# 16. THE WITNESS SURVIVES THE LAND. Sweep 1 (dry-run) sees done-owner's native
#     worktree registered+unlocked and WRITES that to the ledger. Then the
#     native worktree is removed — what a land does. Sweep 2 still selects the
#     hand-rolled tree, from the record. The negative half: with the ledger
#     wiped between the sweeps, the same tree is INDETERMINATE (session alive).
DIR="$(make_world witness)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done
run_reaper "$DIR" "$DIR/entity" >/dev/null
if grep -q '"event": "terminated"' "$DIR/wt-ledger.jsonl" 2>/dev/null \
   && grep -q '"agent_id": "done"' "$DIR/wt-ledger.jsonl"; then
    ok "a registered+unlocked native worktree is WRITTEN to the ledger as a witnessed termination"
else
    bad "witness write: $(cat "$DIR/wt-ledger.jsonl" 2>/dev/null | tail -2)"
fi
git -C "$DIR/entity" worktree remove "$DIR/entity/.claude/worktrees/agent-done" >/dev/null 2>&1
git -C "$DIR/entity" branch -d worktree-agent-done >/dev/null 2>&1
rm -f "$DIR/transcript.jsonl"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if printf '%s' "$OUT" | grep -q '^DRY-RUN REAP done-owner' \
   && printf '%s' "$OUT" | grep -q '(owner done-owner terminated — witnessed termination on record'; then
    ok "AFTER the native worktree is removed (the land), the hand-rolled tree is STILL selected from the witnessed record"
else
    bad "post-land decidability: $(printf '%s' "$OUT" | grep 'done-owner' || echo NONE)"
fi
# negative half: wipe the witness, keep the registration -> INDETERMINATE
grep -v '"event": "terminated"' "$DIR/wt-ledger.jsonl" >"$DIR/wt-ledger.tmp" && mv "$DIR/wt-ledger.tmp" "$DIR/wt-ledger.jsonl"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if printf '%s' "$OUT" | grep -q '^SKIP done-owner owner-indeterminate'; then
    ok "without the witness (same registration, live session) the same tree is INDETERMINATE — the record decides, not the removal"
else
    bad "witness negative: $(printf '%s' "$OUT" | grep 'done-owner' || echo NONE)"
fi

# 17. AN EXECUTED NATIVE REAP IS ITSELF WITNESSED. Reaping agent-done writes a
#     'terminated' record with witness reaper-removal.
DIR="$(make_world native-witness)"
run_reaper "$DIR" "$DIR/entity" --execute >/dev/null
# One witness per agent id (`record --once`): the unlock OBSERVATION at gate 1
# always precedes the removal, so the removal's own write is a no-op here and
# exists for the unlock-stale path. The assertion is that exactly one
# terminated record names agent `done`, and that it was written by the reaper.
N_DONE="$(grep -c '"agent_id": "done"' "$DIR/wt-ledger.jsonl" 2>/dev/null || echo 0)"
if [ ! -d "$DIR/entity/.claude/worktrees/agent-done" ] && [ "$N_DONE" -eq 1 ] \
   && grep -q '"witness": "reaper-observation"' "$DIR/wt-ledger.jsonl"; then
    ok "reaping a native worktree leaves exactly ONE witnessed termination for its agent, written by the reaper"
else
    bad "native reap witness (records for done: $N_DONE): $(cat "$DIR/wt-ledger.jsonl" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
fi

# 18. THE BRANCH SWEEP. Three orphan branches with no worktree: a merged native
#     shaped one (SWEPT), an unmerged native-shaped one (+1, SKIPPED, the live
#     negative in femcboost is worktree-agent-a66286903967ee525), a merged
#     teammate-shaped one (SWEPT) — and an operator's own merged topic branch,
#     which is NOT teammate-shaped and is NEVER a candidate.
DIR="$(make_world branches)"
git -C "$DIR/entity" branch worktree-agent-orphan1 main
git -C "$DIR/entity" branch zach-opus-orphan2 main
git -C "$DIR/entity" branch feature-topic main
git -C "$DIR/entity" branch worktree-agent-keep main
git -C "$DIR/entity" worktree add -q "$DIR/keep-tmp" worktree-agent-keep
printf 'unlanded\n' >"$DIR/keep-tmp/work.txt"
git -C "$DIR/keep-tmp" add work.txt
git -C "$DIR/keep-tmp" commit -q -m "one real commit never landed"
git -C "$DIR/entity" worktree remove "$DIR/keep-tmp" >/dev/null 2>&1
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
B1=1; git -C "$DIR/entity" rev-parse --verify --quiet refs/heads/worktree-agent-orphan1 >/dev/null && B1=0
B2=1; git -C "$DIR/entity" rev-parse --verify --quiet refs/heads/zach-opus-orphan2 >/dev/null && B2=0
K=0;  git -C "$DIR/entity" rev-parse --verify --quiet refs/heads/worktree-agent-keep >/dev/null && K=1
F=0;  git -C "$DIR/entity" rev-parse --verify --quiet refs/heads/feature-topic >/dev/null && F=1
if [ "$RC" -eq 0 ] && [ "$B1" -eq 1 ] && [ "$B2" -eq 1 ] && [ "$K" -eq 1 ] && [ "$F" -eq 1 ] \
   && printf '%s' "$OUT" | grep -q '^SWEEP-BRANCH worktree-agent-orphan1$' \
   && printf '%s' "$OUT" | grep -q '^SWEEP-BRANCH zach-opus-orphan2$' \
   && printf '%s' "$OUT" | grep -q '^SKIP-BRANCH worktree-agent-keep unmerged(+1)$' \
   && ! printf '%s' "$OUT" | grep -q 'feature-topic' \
   && printf '%s' "$OUT" | grep -q 'branches-swept=2 branches-skipped=1'; then
    ok "orphan branches: merged teammate-shaped ones are swept, the unmerged one (+1) is kept, the operator's topic branch is never a candidate"
else
    bad "branch sweep (rc=$RC orphan1_gone=$B1 orphan2_gone=$B2 keep_present=$K topic_present=$F): $(printf '%s' "$OUT" | grep -E 'BRANCH|branches-' | tr '\n' ' ')"
fi

# 18b. A branch attached to a registered worktree belongs to the worktree pass
#      and is never touched by the branch pass, even when merged and clean.
DIR="$(make_world attached)"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if ! printf '%s' "$OUT" | grep -q 'SWEEP-BRANCH worktree-agent-live' \
   && ! printf '%s' "$OUT" | grep -q 'SWEEP-BRANCH worktree-agent-done'; then
    ok "branches attached to registered worktrees are never branch-sweep candidates"
else
    bad "attached branch swept: $(printf '%s' "$OUT" | grep 'SWEEP-BRANCH' | tr '\n' ' ')"
fi

# 19. VERDICT CLEAN: every candidate decided (live owner skipped, dead owner
#     reaped) -> CLEAN, exit 0. The positive half of the verdict contract.
DIR="$(make_world clean-verdict)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
add_handrolled "$DIR/other" "$DIR/other-wt" live-owner live "$$"
OUT="$(run_reaper "$DIR" "$DIR/entity")"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^=== verdict: CLEAN' \
   && printf '%s' "$OUT" | grep -q 'undecidable=0 unresolved=0 indeterminate=0'; then
    ok "verdict CLEAN when every candidate is decided"
else
    bad "clean verdict (rc=$RC): $(printf '%s' "$OUT" | grep -E '^=== (verdict|coverage)' | tr '\n' ' ')"
fi

# 20. A TRANSCRIPT IS NOT OWNERSHIP. No --transcript given; the projects
#     directory holds TWO transcripts, and the tree's name appears in the
#     OLDER one, joined to an agent whose session is provably over by
#     exhaustion. Until 2026-09-03 that reaped the tree. A name join is a
#     reusable key, so it is no longer ownership: the tree is owner-unresolved,
#     kept, and the run FAILS — the hole in the record is reported, not filled
#     by a guess. 20b is the same world with an exact-path record, and THAT is
#     reaped; 20c is 20b with the session unaccounted for.
DIR="$(make_world older-transcript)"
add_handrolled "$DIR/other" "$DIR/other-wt" art-opus-old1
mkdir -p "$DIR/projects/-some-project" "$DIR/sessions"
NOW="$(python3 -c 'import time; print(int(time.time()))')"
OLD_SID="aaaaaaaa-0000-4000-8000-000000000001"
NEW_SID="bbbbbbbb-0000-4000-8000-000000000002"
write_transcript "$DIR/projects/-some-project/$OLD_SID.jsonl" "art-opus-old1=oldart1"
touch -t "$(date -r $((NOW - 7200)) +%Y%m%d%H%M.%S)" "$DIR/projects/-some-project/$OLD_SID.jsonl"
write_transcript "$DIR/projects/-some-project/$NEW_SID.jsonl" "live-owner=live" "done-owner=done"
printf '{"pid":%s,"sessionId":"%s","startedAt":%s000}
' "$$" "$NEW_SID" $((NOW - 1800)) >"$DIR/sessions/$$.json"
OUT="$(REAP_TEST_PROCS="$$:$((NOW - 1800))" REAP_DISCOVERY_SOURCES="primary,neighborhood" REAP_TEAM_DIR="$DIR/teams"        REAP_LEDGER="$DIR/ledger.txt" REAP_WORKTREE_LEDGER="$DIR/wt-ledger.jsonl" REAP_PROJECTS_DIR="$DIR/projects"        RICHOS_CLAUDE_PROCESSES="$$:$((NOW - 1800))" RICHOS_SESSIONS_DIR="$DIR/sessions" CLAUDE_PID="$$"        "$REAPER" "$DIR/entity" --discover --entity "$DIR/entity" --execute 2>&1)"
RC=$?
if [ "$RC" -eq 3 ] && [ -d "$DIR/other-wt/art-opus-old1" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP art-opus-old1 owner-unresolved(.*a transcript joins the name .art-opus-old1. to an agent, and that is NOT accepted as ownership'; then
    ok "TRANSCRIPT ONLY: a name joined to an agent in an older transcript is NOT ownership — kept, owner-unresolved, run FAILS"
else
    bad "older-transcript refusal (rc=$RC dir=$([ -d "$DIR/other-wt/art-opus-old1" ] && echo present || echo gone)): $(printf '%s' "$OUT" | grep -E 'art-opus-old1|blind: owner' | tr '\n' ' ')"
fi

# 20b. POSITIVE CONTROL: the same tree with an EXACT-PATH record naming the old
#      session (no pid, the prior-session shape) — exhaustion proves that
#      session over and the tree is reaped.
ledger_record "$DIR" registered --teammate art-opus-old1 --agent-id oldart1 --session-id "$OLD_SID" \
    --repo "$DIR/other" --worktree "$DIR/other-wt/art-opus-old1" --branch art-opus-old1 --class hand-rolled
OUT="$(REAP_TEST_PROCS="$$:$((NOW - 1800))" REAP_DISCOVERY_SOURCES="primary,neighborhood" REAP_TEAM_DIR="$DIR/teams" \
       REAP_LEDGER="$DIR/ledger.txt" REAP_WORKTREE_LEDGER="$DIR/wt-ledger.jsonl" REAP_PROJECTS_DIR="$DIR/projects" \
       RICHOS_CLAUDE_PROCESSES="$$:$((NOW - 1800))" RICHOS_SESSIONS_DIR="$DIR/sessions" CLAUDE_PID="$$" \
       "$REAPER" "$DIR/entity" --discover --entity "$DIR/entity" --execute 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ ! -d "$DIR/other-wt/art-opus-old1" ] \
   && printf '%s' "$OUT" | grep -q '(owner art-opus-old1 terminated — its session aaaaaaaa is over by exhaustion'; then
    ok "PATH-REGISTERED to a prior session: exhaustion proves that session over — reaped (positive control for 20)"
else
    bad "older-session path record (rc=$RC dir=$([ -d "$DIR/other-wt/art-opus-old1" ] && echo present || echo gone)): $(printf '%s' "$OUT" | grep -E 'art-opus-old1|blind: owner' | tr '\n' ' ')"
fi

# 20c. NEGATIVE: same record, but the running process is UNACCOUNTED (no
#      registry row) -> INDETERMINATE, PENDING, tree kept.
rm -f "$DIR/sessions/$$.json"
git -C "$DIR/other" worktree add -q "$DIR/other-wt/art-opus-old1" art-opus-old1 2>/dev/null \
    || git -C "$DIR/other" worktree add -q -b art-opus-old1 "$DIR/other-wt/art-opus-old1"
OUT="$(REAP_DISCOVERY_SOURCES="primary,neighborhood" REAP_TEAM_DIR="$DIR/teams" \
       REAP_LEDGER="$DIR/ledger.txt" REAP_WORKTREE_LEDGER="$DIR/wt-ledger.jsonl" REAP_PROJECTS_DIR="$DIR/projects" \
       RICHOS_CLAUDE_PROCESSES="$$:$((NOW - 9000))" RICHOS_SESSIONS_DIR="$DIR/sessions" CLAUDE_PID="$$" \
       "$REAPER" "$DIR/entity" --discover --entity "$DIR/entity" --execute 2>&1)"
if [ -d "$DIR/other-wt/art-opus-old1" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP art-opus-old1 owner-indeterminate(.*not accounted for'; then
    ok "PATH-REGISTERED, unaccounted running process: INDETERMINATE, kept"
else
    bad "older-session negative: $(printf '%s' "$OUT" | grep 'art-opus-old1' | tr '\n' ' ')"
fi

# 21. NEVER WRITES THE OPERATOR'S REAL LEDGER FROM A SANDBOX: REAP_WORKTREE_LEDGER
#     is honored for every write (the witness in 16 landed in the case dir).
if [ -f "$DIR/wt-ledger.jsonl" ] || [ -f "$SANDBOX/witness/wt-ledger.jsonl" ]; then
    ok "witnessed terminations are written to the ledger the run was pointed at"
else
    bad "ledger redirection"
fi

# 22. OPERATOR WORKTREES ARE NOT A FAILURE OF THE RECORD. A hand-rolled tree
#     whose name is neither teammate-shaped nor a spawned name (a CI checkout,
#     another tool's worktree — /private/tmp/ci-base and a Codex worktree in
#     richos, measured) is inventoried, never mutated, and never a verdict.
DIR="$(make_world operator)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
add_handrolled "$DIR/other" "$DIR/other-wt" ci-base
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/ci-base" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP ci-base operator-worktree(' \
   && printf '%s' "$OUT" | grep -q 'unresolved=0 indeterminate=0 operator=1' \
   && printf '%s' "$OUT" | grep -q '^=== verdict: CLEAN'; then
    ok "a non-teammate worktree is SKIP operator-worktree, counted apart, kept, and the run is CLEAN"
else
    bad "operator worktree (rc=$RC): $(printf '%s' "$OUT" | grep -E 'ci-base|^=== (verdict|coverage)' | tr '\n' ' ' | cut -c1-300)"
fi

# 22b. NEGATIVE: the SAME unshaped name, once it is a name this machine
#      recorded spawning, is a teammate's tree with no record -> unresolved, FAIL.
DIR="$(make_world operator-neg)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner done "$$"
add_handrolled "$DIR/other" "$DIR/other-wt" ci-base
spawned_names "$DIR" live-owner done-owner ci-base
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q '^SKIP ci-base owner-unresolved('; then
    ok "the same unshaped name, once recorded as spawned, is a teammate's unresolved tree and FAILS the run"
else
    bad "operator negative (rc=$RC): $(printf '%s' "$OUT" | grep -E 'ci-base' | tr '\n' ' ' | cut -c1-300)"
fi

# 23. A REGISTRATION BY PATH BEATS THE NAME RULE. A tree with an unshaped name
#     registered by exact path (what create-teammate-worktree.sh writes) to a
#     session that has ended is reaped — no name convention needed.
DIR="$(make_world path-reg)"
add_handrolled "$DIR/other" "$DIR/other-wt" feature-topic
ledger_record "$DIR" registered --teammate mark-opus-p9 --agent-id p9 --session-id sess-old \
    --session-pid "$DEAD_PID" --pid-start "$DEAD_START" --repo "$DIR/other" \
    --worktree "$DIR/other-wt/feature-topic" --branch feature-topic --class hand-rolled
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -d "$DIR/other-wt/feature-topic" ] \
   && printf '%s' "$OUT" | grep -q '(owner feature-topic terminated — its host session pid'; then
    ok "a path-registered tree with an unshaped name is judged by its registration and reaped"
else
    bad "path registration (rc=$RC): $(printf '%s' "$OUT" | grep -E 'feature-topic' | tr '\n' ' ' | cut -c1-300)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== reap-stale-worktrees (scope + safety) tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== reap-stale-worktrees (scope + safety) tests: all $PASS passed ==="
    exit 0
fi
