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

add_handrolled() { # <repo> <container> <name>
    local repo="$1" container="$2" name="$3"
    mkdir -p "$container"
    git -C "$repo" worktree add -q -b "$name" "$container/$name"
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
# inside the case directory: this suite must never be able to see, let alone
# touch, a real repository.
RC=0
run_reaper() {
    local dir="$1" entity="$2"; shift 2
    local out
    out="$(REAP_DISCOVERY_SOURCES="primary,neighborhood" \
           REAP_TEAM_DIR="$dir/teams" \
           REAP_LEDGER="$dir/ledger.txt" \
           REAP_PROJECTS_DIR="$dir/projects" \
           "$REAPER" "$entity" --discover --entity "$entity" \
               --transcript "$dir/transcript.jsonl" "$@" 2>&1)"
    RC=$?
    printf '%s' "$out"
}

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
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
OUT="$(run_reaper "$DIR" "$DIR/entity")"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q -- "--- repo: $DIR/other "; then
    ok "a sibling repository, named by nothing, is discovered and swept"
else
    bad "discovery (rc=$RC)"
fi

# 1b. NEGATIVE CONTROL for case 1. Without --discover the same world yields the
#     OLD behavior — one repository — and says so in `blind:` rather than
#     letting the summary imply it looked everywhere. A discovery test that
#     never sees the undiscovered case proves nothing about discovery.
OUT="$(REAP_TEAM_DIR="$DIR/teams" REAP_LEDGER="$DIR/ledger.txt" \
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
add_handrolled "$DIR/other" "$DIR/other-wt" live-owner
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
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
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
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
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
printf 'committed but never landed\n' >"$DIR/other-wt/done-owner/work.txt"
git -C "$DIR/other-wt/done-owner" add work.txt
git -C "$DIR/other-wt/done-owner" commit -q -m "unlanded handoff"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
if [ "$RC" -eq 0 ] && [ -f "$DIR/other-wt/done-owner/work.txt" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP done-owner unmerged(+1)'; then
    ok "hand-rolled worktree with unlanded commits survives (unmerged)"
else
    bad "unmerged hand-rolled (rc=$RC)"
fi

# 5. DIRTY IS NEVER REAPED — uncommitted work outranks every other signal.
DIR="$(make_world dirty)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
printf 'uncommitted\n' >"$DIR/other-wt/done-owner/scratch.txt"
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
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
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
add_handrolled "$DIR/other" "$DIR/other-wt" nobody-owns-this
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/nobody-owns-this" ] \
   && printf '%s' "$OUT" | grep -q '^SKIP nobody-owns-this owner-unresolved'; then
    ok "hand-rolled worktree with an unresolvable owner survives (owner-unresolved)"
else
    bad "unknown owner (rc=$RC)"
fi

# 7. THE CASE THE WHOLE SAFETY RULE TURNS ON.
#    The owner's native isolation worktree is ABSENT. The liveness resolver
#    says NOT-ALIVE for that — and it is an ABSENCE, not an observation. Doctrine:
#    never infer an agent is dead from filesystem inactivity; require a positive
#    termination signal. So the tree survives, and it survives even though it is
#    merged, clean, unlocked and has no live process — every OTHER gate open.
DIR="$(make_world absent-native)"
add_handrolled "$DIR/other" "$DIR/other-wt" ghost-owner
write_transcript "$DIR/transcript.jsonl" "live-owner=live" "done-owner=done" "ghost-owner=ghost"
spawned_names "$DIR" live-owner done-owner ghost-owner
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
# The reason string is asserted, not just the survival: this branch and case
# 6's "no agent matches" branch both print owner-unresolved, and they are
# different findings. `ghost-owner` DOES resolve to a real agent — the agent's
# isolation worktree is simply not there. Matching the generic prefix would let
# a regression that collapses the two read as a pass.
if [ "$RC" -eq 0 ] && [ -d "$DIR/other-wt/ghost-owner" ] \
   && printf '%s' "$OUT" | grep -q "^SKIP ghost-owner owner-unresolved(ghost-owner — verdict NOT-ALIVE only because its isolation worktree is ABSENT"; then
    ok "owner whose isolation worktree is ABSENT is undecidable, never reaped"
else
    bad "absent native worktree (rc=$RC dir=$([ -d "$DIR/other-wt/ghost-owner" ] && echo present || echo GONE))"
fi

# 8. DETACHED HEAD -> no-branch. There is nothing to check mergedness against,
#    and unverifiable is not permission.
#    The detached tree is deliberately owned by an agent that terminated
#    OBSERVABLY, so gate 2 passes and gate 3 is the gate actually under test.
#    Left unowned it would be skipped as owner-unresolved and this case would
#    prove nothing about the branch gate at all.
DIR="$(make_world detached)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
git -C "$DIR/other" worktree add -q --detach "$DIR/other-wt/detached-tree"
write_transcript "$DIR/transcript.jsonl" "live-owner=live" "done-owner=done" "detached-tree=done"
spawned_names "$DIR" live-owner done-owner detached-tree
OUT="$(run_reaper "$DIR" "$DIR/entity")"
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
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
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
    REAP_LEDGER="$DIR/ledger.txt" REAP_PROJECTS_DIR="$DIR/projects" \
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
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
add_handrolled "$DIR/other" "$DIR/other-wt" live-owner
OUT="$(run_reaper "$DIR" "$DIR/entity")"
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
       REAP_LEDGER="$DIR/ledger.txt" REAP_PROJECTS_DIR="$DIR/projects" \
       "$REAPER" "$DIR/entity" --discover --entity "$DIR/entity" --execute 2>&1)"
if [ -d "$DIR/other-wt/done-owner" ] \
   && printf '%s' "$OUT" | grep -q '=== blind: owner liveness: no session transcript'; then
    ok "with no transcript every hand-rolled tree survives and the blindness is DECLARED"
else
    bad "declared blindness"
fi

# 13. RESIDUE AND ORPHANED PROCESSES ARE SCOPED TO REAL CONTAINERS. A directory
#     that merely happens to contain one worktree is not a worktree container —
#     the first run of this rewrite made /private/tmp one and reported 39
#     launchd sockets as residue. A signal buried in noise is a signal ignored.
DIR="$(make_world containers)"
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
mkdir -p "$DIR/other-wt/leftover-junk"
for i in 1 2 3 4 5 6; do mkdir -p "$DIR/scattered/not-a-worktree-$i"; done
git -C "$DIR/other" worktree add -q -b lonely "$DIR/scattered/lonely"
OUT="$(run_reaper "$DIR" "$DIR/entity")"
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
add_handrolled "$DIR/other" "$DIR/other-wt" done-owner
run_reaper "$DIR" "$DIR/entity" --execute >/dev/null
OUT="$(run_reaper "$DIR" "$DIR/entity" --execute)"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'reaped=0 ' \
   && printf '%s' "$OUT" | grep -q 'errors=0'; then
    ok "second sweep is a clean no-op (nothing reaped twice, no errors)"
else
    bad "idempotence (rc=$RC summary=$(printf '%s' "$OUT" | grep '^=== summary'))"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== reap-stale-worktrees (scope + safety) tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== reap-stale-worktrees (scope + safety) tests: all $PASS passed ==="
    exit 0
fi
