#!/usr/bin/env bash
#
# reap-stale-worktrees.sh — THE WORKTREE REAPER.
#
# ===========================================================================
# WHAT IT IS FOR
# ===========================================================================
# Every file-writing teammate gets a git worktree. The orchestrator is supposed
# to remove each one at land time; across restarts, dropped handoffs and
# interrupted sessions they pile up instead. This is the safety net: a
# conservative sweep that removes ONLY worktrees provably safe to discard,
# DRY-RUN by default.
#
# ===========================================================================
# WHY IT WAS REBUILT (2026-09-01) — IT RAN, IT REPORTED SUCCESS, AND IT WAS
# AIMED AT AN EMPTY ROOM
# ===========================================================================
# At that morning's session start this script printed
#
#     reaped=1 skipped=0 errors=0 residue=0
#
# and by evening there were 19 registered worktrees in `richos` and 6 more in
# `richos-hq` that it had never looked at, in that session or any session
# before it. Nothing was broken. Three scope assumptions were wrong, and the
# summary line was written as if none of them existed:
#
#   1. ONE REPOSITORY. It resolved a single repo root — the governed entity —
#      and swept that. The engineers were working in two other repositories.
#   2. ONE PATH CONVENTION. It scanned `<repo>/.claude/worktrees/agent-*`,
#      the NATIVE isolation layout. The trees that accumulated were at
#      `/Users/alex/ab/richos-wt/<name>` and `<repo>/.worktrees/<name>`.
#      Neither matched, so neither was ever a candidate.
#   3. ONE MOMENT. SessionStart only. A twelve-hour session accumulates
#      everything and clears nothing until the next session opens.
#
# And the design assumption was inverted. It was built for native isolation
# worktrees, while cross-repository work runs in hand-rolled worktrees BY
# CONSTRUCTION (native isolation roots at the session's repository) — and that
# is the common case, not the exception: 48 of 53 worktrees on this machine on
# 2026-09-02. It covered the rare case and missed the standard one. Since
# 2026-09-02 every cross-repository worktree is created and registered by
# scripts/create-teammate-worktree.sh, and the ownership ledger — not the
# lock — is the record this reaper judges it by (see the safety rule below).
#
# The fix is scope, not a second reaper. A second reaper would be the same
# defect one level up: two sweeps, each certain about its own half.
#
# ===========================================================================
# THE THREE THINGS THAT CHANGED
# ===========================================================================
#
# A. REPOSITORIES ARE DISCOVERED, NOT LISTED. `--discover` unions candidate
#    repositories from named, honest sources — never a hard-coded inventory of
#    repo names, because a typed inventory is exactly the thing that falls
#    behind. Sources, each named in the output:
#
#      primary          the repo root this run was pointed at
#      engine           the repository the engine's own bytes live in
#      inflight-repos   <team-dir>/inflight-repos.txt — the repositories the
#                       session's own git-jurisdiction resolver observed
#      event-logs       `cwd` fields in the session's worker/idle/task event
#                       logs, resolved to their main checkout
#      ledger           repositories this reaper has seen before
#      neighborhood     the immediate children of the parent directory of a
#                       repository already known — this is what finds a
#                       sibling checkout and a sibling worktree container
#                       (`richos-hq`, `richos-hq-wt/`) that no log mentions
#
#    Every candidate is resolved through `git worktree list`, so a candidate
#    is accepted because git says it is a checkout, not because its name
#    looked right.
#
# B. WORKTREES COME FROM `git worktree list`, NOT FROM A PATH SHAPE. Every
#    linked worktree of every swept repository is a candidate regardless of
#    where it sits on disk. Path shape is now used for ONE thing only —
#    classification:
#
#      native       <repo>/.claude/worktrees/agent-*   (harness-created)
#      hand-rolled  anything else                      (operator-created)
#
#    and the two classes get different LIVENESS RULES, below, because they
#    carry different evidence.
#
# C. (RETIRED 2026-09-03) It used to run with --execute when an agent
#    finished and at every session start. Both triggers are gone: no sweep
#    decides an agent's liveness any more (docs/plans/worktree-real-fix-
#    2026-09-03.md). This script is now an INVENTORY, run in DRY-RUN by
#    session-start-reap-worktrees.sh; `--execute` remains an operator's
#    by-hand act and is reached by no hook.
#
# ===========================================================================
# WHY IT IS DRY-RUN BY DEFAULT, AND EXACTLY WHAT TURNS REMOVAL ON (2026-09-05)
# ===========================================================================
# The CEO opened his IDE on 2026-09-04, found 17 `agent-*` directories under
# femcboost/.claude/worktrees/ and asked for "an automatic mechanism for
# cleaning those things up". The mechanism was not missing. It was INERT, and
# worse than inert: this file's own session-start run ended
#
#     reaped=11 skipped=21 errors=0 residue=0   (DRY-RUN, nothing removed)
#
# `reaped=11` in a run that removed NOTHING. The parenthetical was true and
# nobody reads a parenthetical past a number in the past tense. That is this
# project's standing failure class — a check reporting green over something
# that never ran — wearing a cleanup script's clothes.
#
# THE ANSWER TAKEN: DRY-RUN STAYS THE DEFAULT, and the report stops lying.
#
# Removal is NOT this script's job any more and re-arming it would be a
# regression, not a fix. On 2026-09-03 the CEO ruled the sweep-decides-
# liveness design dead — "The system should stop trying to discover whether
# the agent might return. It is forbidden to return." — after nine rounds of
# it failed in nine shapes, the last by removing a LIVE agent's worktree.
# Removal now belongs to the worktree TRANSACTION: a terminal event claims it,
# and reconcile-terminal-worktrees.py (launchd-driven) captures, verifies,
# unregisters and removes. That machine works — 75 removed, measured
# 2026-09-05 — so the automatic mechanism the CEO asked for EXISTS for every
# worktree a transaction claims.
#
# What it does not cover is a worktree NO transaction ever claimed: spawned
# before the transaction store, or by a route that wrote no terminal event.
# Nothing will ever come for those, and they are exactly the pile in his IDE.
# So this inventory's job is to make that population impossible to misread:
#
#   * In DRY-RUN the summary NEVER uses the past tense. It prints
#     `removed=0 would-remove=N`. `reaped=N` appears only under --execute,
#     where it is a count of removals that happened.
#   * `would-remove>0` is a PENDING verdict, never CLEAN, and the verdict
#     line names the one command that turns removal on:
#         scripts/reap-stale-worktrees.sh <repo-root> --discover --execute
#     That is an OPERATOR's by-hand act. No hook passes --execute, and Layer Q
#     of the integrity probe asserts that none ever does.
#   * Under --execute, removal goes through scripts/remove-agent-worktree.sh —
#     the sanctioned remover — so the ENTITY-lock liveness check runs a second
#     time, fail-closed, and deregistration happens the blessed way. The gates
#     below are a FILTER; the remover is the AUTHORITY. Two implementations of
#     "alive" is how one of them silently becomes the stale one, and this
#     script used to be the second one.
#
# ===========================================================================
# SHELLS ARE LABELED, NEVER TREATED AS DISPOSABLE (2026-09-05)
# ===========================================================================
# A cross-repository spawn gets a native worktree in the SESSION's repository
# and a hand-rolled one in the repository it actually edits. The native one is
# never written to, and the row that asked for this work called it "a worktree
# it will never use". That is FALSE and the error is dangerous in the fatal
# direction: the shell holds no files and one thing that matters — the
# PLATFORM-OWNED LOCK that scripts/agent-liveness.sh reads to answer "is this
# agent alive". A hand-rolled tree takes no lock at all. Remove a shell whose
# agent is still running and you have destroyed the only evidence that it is
# running. "Never written to" is true; "never used" is not.
#
# So `shell` is a REPORTING label and it is wired to NOTHING that decides. It
# is printed (`native-shell`) and counted (`shells=N` on the coverage line) so
# that a reader can tell a 266 MB never-read witness from a real workspace,
# and so that an `unmerged(+1)` on a SHELL reads as the anomaly it is rather
# than as ordinary unlanded work. Every gate treats a shell exactly as it
# treats any other native worktree.
#
# ===========================================================================
# UNMERGED WORK IS NAMED, NOT JUST COUNTED (2026-09-05)
# ===========================================================================
# `SKIP agent-a44e6817bce90ed1c unmerged(+1)` was this file's whole report on
# a worktree whose single commit is
#
#     BLOCKED.md: the 'parked until' fixture dispatched an Agent, so the
#     arm-2 rule as specified reads it green
#
# — a teammate's escalation, written exactly as the protocol of the day told
# it to, committed on a branch nobody merged, and still sitting there three
# days later beside a second one. The gate was right: unmerged work is never
# swept. The REPORT was useless, and that is why nobody looked. Every
# `unmerged` skip now carries the commit subjects (up to three), because the
# subject line is what makes the difference between "some branch" and "a
# person is blocked in here".
#
# ===========================================================================
# ONE DIRECTORY, TWO REPOSITORIES (2026-09-05)
# ===========================================================================
# /Users/alex/ab/richos-alex is a COPY of richos's .git, and it registers the
# same four worktree paths as /Users/alex/ab/richos. Discovery found both, so
# every one of those four was inventoried twice: `would-remove=11` over SEVEN
# distinct directories. Under --execute the second repository would then run
# `git worktree remove` against a directory the first had already deleted, and
# a spurious error would fail an otherwise clean run. A worktree path is now
# claimed by the FIRST reap-eligible repository that registers it; any later
# claimant is `SKIP <id> duplicate-registration(...)`, counted apart, and
# never acted on.
#
# ===========================================================================
# THE SAFETY RULE — ABSOLUTE
# ===========================================================================
# NEVER REMOVE A WORKTREE THAT IS OR MIGHT BE LIVE. Doctrine: *never infer an
# agent is dead from filesystem inactivity; require a positive termination
# signal.* Reaping a live agent's worktree destroys uncommitted work.
#
# A NATIVE worktree carries its own positive signal: a live agent's isolation
# worktree is LOCKED, and the lock names the session pid. An absent or stale
# lock is an observation, and gate 1 reads it.
#
# A HAND-ROLLED WORKTREE HAS NO LOCK. None is ever taken there, so quiet is
# not death and inactivity proves nothing at all. So a hand-rolled tree is
# reaped only when a positive termination signal for its OWNER exists.
#
# ===========================================================================
# WHERE THAT SIGNAL COMES FROM (2026-09-02) — THE LEDGER, NOT THE LOCK
# ===========================================================================
# This used to read the owner's NATIVE isolation-worktree lock and nothing
# else. That native worktree is deleted at land time, so from that moment the
# hand-rolled tree was PERMANENTLY undecidable: cleaning up one repository
# destroyed the only evidence that could ever clean up another. Four fixes
# (repositories, path shapes, the agent-finish trigger, a guard tightening)
# were each correct and each forward-only, and 29 worktrees in `richos` sat
# `owner-undecidable` through all of them with the blind line "no session
# transcript found for entity '/Users/alex/ab/richos'" — a project directory
# that holds zero transcripts and always will, because no session starts there.
#
# So RichOS now OWNS the record: scripts/lib/worktree-ledger.py, at
# ~/.claude/state/worktree-ledger.jsonl, outside every repository and every
# session team directory. Registrations are written at spawn (teammate, agent
# id, session id, session pid + start time, repo, worktree, branch); witnessed
# terminations are written the moment this reaper or the sanctioned remover
# SEES a native worktree registered-and-unlocked; finish signals are retained
# as advisory. The judgment, per registration, is:
#
#   witnessed termination on record ................ NOT-ALIVE
#   native isolation worktree LOCKED, pid running ... ALIVE
#   native registered and unlocked / stale-locked ... NOT-ALIVE — OBSERVED now,
#                                                     and WRITTEN to the ledger
#                                                     so the land cannot
#                                                     destroy it
#   native ABSENT, session pid+start provably gone .. NOT-ALIVE — the process
#                                                     every agent of that
#                                                     session ran inside no
#                                                     longer exists. Same
#                                                     evidence class as a stale
#                                                     lock, retained past the
#                                                     lock's deletion
#   native ABSENT, session pid still running ........ INDETERMINATE, naming the
#                                                     pid; decidable when that
#                                                     session ends
#   no session identity recorded, native absent ..... INDETERMINATE
#   no registration and no transcript join .......... UNRESOLVED
#
#   ALIVE ............ SKIP owner-alive
#   INDETERMINATE .... SKIP owner-indeterminate   (owner KNOWN; transient)
#   UNRESOLVED ....... SKIP owner-unresolved      (NO record; permanent, and a
#                                                  FAILURE of the record — see
#                                                  the verdict line) — unless
#                                                  the tree is not teammate-
#                                                  shaped and no spawn record
#                                                  names it: then it is an
#                                                  OPERATOR worktree (a CI
#                                                  checkout, another tool's),
#                                                  SKIP operator-worktree,
#                                                  inventoried, never a verdict
#   NOT-ALIVE ........ positive signal; continue to the remaining gates
#
# Owner name = the worktree's branch name, else its directory name (the
# convention this project actually uses), OR an exact worktree-path
# registration written by scripts/create-teammate-worktree.sh, which needs no
# name at all. The session transcript's name -> agentId join is kept as a
# FALLBACK only; it was the PRIMARY source and it is the wrong key by
# construction (looked up under the swept repository's project directory,
# newest transcript only).
#
# ABSENCE IS STILL NEVER A TERMINATION SIGNAL. Nothing above accepts "not where
# I looked". A native worktree that is simply gone lands in INDETERMINATE until
# the session that owned it is provably gone — which is process evidence, not
# filesystem inactivity.
#
# TeammateIdle / TaskCompleted / SubagentStop are RECORDED and REPORTED and do
# not decide: an idle teammate can be resumed by a message (the engine's own
# guard-resume-isolation.sh permits exactly that), a completed task is
# task-grain, and SubagentStop fires at the end of every turn.
#
# C above still matters — at agent-finish the evidence is freshest — but it is
# no longer the ONLY moment the evidence exists. That is the whole change.
#
# INDETERMINATE IS A REAL ANSWER AND IS NEVER GUESSED INTO EITHER OTHER ONE.
# UNRESOLVED IS NOT INDETERMINATE: one is "owner known, verdict pending", the
# other is "nobody ever recorded an owner", and only the second one grows
# forever. They are counted apart (`indeterminate=N unresolved=N`) and the
# second one FAILS the run (verdict FAIL, exit 3) so it can never again print
# as a routine line beside `reaped=5`.
#
# ===========================================================================
# THE GATES — a tree is REAP-eligible only if ALL of them hold, in order
# ===========================================================================
#   0. Its repository is REAP-ELIGIBLE. A repository known ONLY from the
#      neighborhood scan, holding no worktree owned by a teammate this machine
#      has a record of spawning, is REPORT-ONLY: it is inventoried and
#      printed and never mutated. Discovery is allowed to be generous
#      precisely because removal is not.
#   1. NOT locked. A lock means "possibly still in use" and is always
#      respected. With --unlock-stale a lock is broken ONLY when BOTH no live
#      process references the path AND the lock file is >2h old.
#   2. (hand-rolled only) A positive owner-termination signal, above.
#   3. Its branch is a merge-base ancestor of the repository's own HEAD
#      branch (no hardcoded "main"). Unmerged -> SKIP unmerged(+N). Detached
#      or missing branch -> SKIP no-branch: unverifiable is not permission.
#   4. `git status --porcelain` is empty, tracked AND untracked.
#   5. No live process references the tree path.
#
# Removal is the sanctioned two-step (worktree removal without --force, then
# branch deletion with -d and never -D). A branch with unmerged commits
# refuses -d, which is the backstop for a gate 3 that is somehow wrong.
#
# ===========================================================================
# THE BRANCH SWEEP — orphan branches whose worktree is already gone
# ===========================================================================
# `git branch -d` above lives inside the per-worktree loop, so it only ever
# sees a branch still attached to a registered worktree. A branch whose
# worktree vanished by any other route (a raw removal, the harness's own
# auto-clean, a prune) was unreachable by the only code that could delete it —
# permanently. femcboost held four such orphans on 2026-09-02.
#
# So after the worktree loop, every reap-eligible repository gets a pass over
# refs/heads/. A branch is a CANDIDATE only if it is teammate-shaped —
# `worktree-*` (native isolation), `<role>-<model>-<identifier>` (the spawn
# name contract), or a branch the ledger registered for this repository — so
# an operator's own topic branches are never touched. A candidate is swept
# only if ALL hold: it is not the repository's current branch; no worktree is
# registered on it; it is a merge-base ancestor of HEAD; no live process
# references it. Unmerged -> SKIP-BRANCH unmerged(+N), and `-d` (never `-D`)
# is the backstop. `worktree-agent-a66286903967ee525` in femcboost is
# UNMERGED (+1) and is the standing live negative for this pass.
#
# ===========================================================================
# PROCESSES, NOT JUST DIRECTORIES
# ===========================================================================
# A background child can outlive BOTH its agent AND its worktree, then
# re-create the path and write ghost state into it. So every worktree
# CONTAINER directory is scanned for processes referencing a path that is not
# a registered worktree, and each one is NAMED (`ORPHAN-PROCESS`). They are
# never killed here — naming them is the deliverable; killing someone else's
# process is not a decision a session-start hook gets to make.
#
# ===========================================================================
# THE DENOMINATOR IS PART OF THE REPORT
# ===========================================================================
# `reaped=1 skipped=0 errors=0 residue=0` was TRUE on the morning this was
# rewritten, and it was a false green, because it described one repository out
# of three and one path convention out of two while sounding like it described
# everything. So the summary now carries its own scope:
#
#   === summary (EXECUTE): reaped=N skipped=N errors=N residue=N
#       orphan-processes=N branches-swept=N branches-skipped=N ===
#   === summary (DRY-RUN): removed=0 would-remove=N skipped=N ... ===
#   === coverage (MODE): repos=N reap-eligible=N report-only=N unreachable=N
#       worktrees=N native=N shells=N hand-rolled=N undecidable=N unresolved=N
#       indeterminate=N ===
#   === sources: <label>=<count> ... ===
#   === blind: <what this run could NOT see>  (or: none declared) ===
#   === verdict: CLEAN | PENDING — ... | FAIL — ... ===
#
# A number that is not known is printed as not known. `blind:` is where a
# future version of this defect has to declare itself.
#
# THE VERDICT LINE IS THE PART THAT CANNOT READ AS ROUTINE. On 2026-09-02 the
# session banner said `reaped=5 skipped=49 errors=0` — a success-shaped line —
# for a run in which zero of the 47 real offenders could ever be touched;
# `undecidable=47` sat beside it as information. Now: `unresolved>0` is a FAIL
# (exit 3) because it means the record has a hole that only an operator can
# close; `indeterminate>0` is PENDING because every one of those names a
# session pid and resolves itself when that session ends; anything else is
# CLEAN. The wrappers put the verdict FIRST in what they announce.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   scripts/reap-stale-worktrees.sh [repo-root] [options]
#
#     repo-root          Optional. Defaults to the resolved main checkout.
#     --execute          Perform removals/unlocks/prune. Without it: DRY-RUN
#                        (report only, zero mutation) — the default.
#     --unlock-stale     Allow breaking a lock that is >2h old with no live
#                        process referencing the tree.
#     --discover         Union in other repositories from the sources above.
#                        OFF by default, so a run pointed at one root sweeps
#                        exactly that root — which is what every hermetic test
#                        and probe canary depends on.
#     --entity <path>    The repository whose NATIVE isolation-worktree locks
#                        are authoritative for owner liveness. Defaults to the
#                        primary repo root.
#     --transcript <p>   A session transcript for the name -> agentId join
#                        (FALLBACK source; repeatable). Auto-detected when
#                        absent: the newest under ~/.claude/projects/<entity
#                        slug>/ AND the newest anywhere under
#                        ~/.claude/projects/. Its absence is DECLARED.
#
#   Environment (test affordances; never set in a real session):
#     REAP_DISCOVERY_SOURCES   comma list restricting the sources above
#     REAP_TEAM_DIR            stands in for ~/.claude/teams
#     REAP_LEDGER              stands in for the known-repositories ledger
#     REAP_WORKTREE_LEDGER     stands in for ~/.claude/state/worktree-ledger.jsonl
#                              (the ownership ledger). EVERY sandbox run MUST
#                              set it: a sweep writes witnessed terminations,
#                              and a test that writes them into the operator's
#                              real ledger is a test with side effects.
#     REAP_ENGINE_ROOT         stands in for the engine checkout
#     REAP_PROJECTS_DIR        stands in for ~/.claude/projects
#     REAP_NEIGHBORHOOD_MAX    max entries in a parent dir before the
#                              neighborhood scan declares itself blind (200)
#     REAP_REMOVER             stands in for scripts/remove-agent-worktree.sh.
#                              The suite needs to TAKE THE REMOVER AWAY and see
#                              removal stop, because a routing that still works
#                              when the thing it routes to is gone is not a
#                              routing. Never set in a real session.
#
# Before each real removal, scripts/collect-worktree-artifacts.sh is run
# against the tree if the swept repository has one — mirrors land-time
# practice. Never run in DRY-RUN (it writes artifact dirs).
#
# Run in DRY-RUN by scripts/hooks/session-start-reap-worktrees.sh (SessionStart)
# as the session's worktree inventory; no hook passes --execute. Covered by
# the integrity probe's Layer Q, which asserts exactly that.
#
# Exit codes:
#   0  clean run (a SKIP is not an error; verdict CLEAN or PENDING)
#   1  unexpected error (missing/invalid repo, a removal failed, etc.)
#   3  ran clean, but verdict FAIL: at least one hand-rolled worktree has NO
#      ownership record (owner-unresolved). Nothing was mutated wrongly; the
#      RECORD has a hole, and that is not allowed to print as routine.
#
# The verdict is PENDING (exit 0) — never CLEAN — while any of these hold, and
# it names ALL of them rather than the first: indeterminate owners, worktrees
# quarantined by a terminal transaction, and (DRY-RUN only) `would-remove>0`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

usage() {
    cat <<'EOF'
Usage: scripts/reap-stale-worktrees.sh [repo-root] [options]

  repo-root          Optional. Defaults to the resolved main checkout.
  --execute          Perform removals/unlocks/prune. Without it: DRY-RUN.
  --unlock-stale     Break a lock >2h old with no live process on the tree.
  --discover         Union in other repositories from the discovery sources
                      (primary, engine, inflight-repos, event-logs, ledger,
                      neighborhood). Off by default.
  --entity <path>    Repository whose native isolation locks decide owner
                      liveness. Defaults to the primary repo root.
  --transcript <p>   Session transcript for the teammate-name -> agentId join
                      (fallback source; repeatable).
  -h, --help         Show this help.
EOF
}

EXECUTE=0
UNLOCK_STALE=0
DISCOVER=0
REPO_ROOT_ARG=""
ENTITY_ARG=""
TRANSCRIPT_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
    --execute)      EXECUTE=1; shift ;;
    --unlock-stale) UNLOCK_STALE=1; shift ;;
    --discover)     DISCOVER=1; shift ;;
    --no-discover)  DISCOVER=0; shift ;;
    --entity)       ENTITY_ARG="${2:-}"; shift 2 ;;
    --transcript)   TRANSCRIPT_ARGS+=("${2:-}"); shift 2 ;;
    -h | --help)    usage; exit 0 ;;
    -*)
        echo "ERROR: unknown flag: $1" >&2
        usage >&2
        exit 1
        ;;
    *)
        if [ -n "$REPO_ROOT_ARG" ]; then
            echo "ERROR: unexpected extra positional argument: $1" >&2
            exit 1
        fi
        REPO_ROOT_ARG="$1"
        shift
        ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 1; }

# --- Resolve the PRIMARY repo root -----------------------------------------
_RMC_LIB="$LIB_DIR/resolve-main-checkout.sh"
_FALLBACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -n "$REPO_ROOT_ARG" ]; then
    [ -d "$REPO_ROOT_ARG" ] || { echo "ERROR: repo-root does not exist: $REPO_ROOT_ARG" >&2; exit 1; }
    REPO_ROOT="$(cd "$REPO_ROOT_ARG" && pwd)"
elif [ -f "$_RMC_LIB" ]; then
    # shellcheck source=lib/resolve-main-checkout.sh
    . "$_RMC_LIB"
    REPO_ROOT="$(resolve_main_checkout "$SCRIPT_DIR" "$_FALLBACK_ROOT")"
else
    REPO_ROOT="$_FALLBACK_ROOT"
fi

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: not a git repository: $REPO_ROOT" >&2; exit 1; }

ENTITY_ROOT="${ENTITY_ARG:-$REPO_ROOT}"

if [ "$EXECUTE" -eq 1 ]; then
    MODE_LABEL="EXECUTE"
else
    MODE_LABEL="DRY-RUN"
fi

# --- Blind list: everything this run could NOT see --------------------------
# Written to as the run proceeds and printed at the end. An empty blind list is
# a CLAIM, not a default: it says "nothing was out of reach", and that claim is
# what the old summary line made silently and wrongly.
BLIND=()
blind() { BLIND+=("$1"); }

# --- Small helpers ----------------------------------------------------------

mtime_of() { # <file> -> epoch seconds on stdout, or nonzero exit
    local f="$1" v
    v="$(stat -f %m "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
    v="$(stat -c %Y "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        v="$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
    fi
    return 1
}

live_pids_for() { # <path> -> comma-separated pids on stdout (may be empty)
    local path="$1" out=""
    if command -v pgrep >/dev/null 2>&1; then
        # Exclude this process and its parent: the reaper's own command line can
        # carry a path it is judging, and a tool that reports ITSELF as the live
        # process would never reap anything and never say why.
        out="$(pgrep -f "$path" 2>/dev/null | grep -v -x -e "$$" -e "${PPID:-0}" | tr '\n' ',' | sed 's/,$//' || true)"
    fi
    printf '%s' "$out"
}

# repo_main_of <path> -> the MAIN checkout of the repository containing <path>.
# `git worktree list`'s FIRST entry is the main worktree by definition, so this
# normalizes a linked worktree, a subdirectory, or a checkout to one identity —
# without parsing .git files or guessing from directory names.
repo_main_of() {
    local p="$1" main=""
    [ -n "$p" ] && [ -d "$p" ] || return 1
    main="$(git -C "$p" worktree list --porcelain 2>/dev/null | sed -n '1s|^worktree ||p')" || return 1
    [ -n "$main" ] || return 1
    (cd "$main" 2>/dev/null && pwd -P) || return 1
}

REPOS=()
REPO_SRCS=()

add_repo() { # <path-or-worktree> <source-label>
    local raw="${1:-}" src="$2" main="" i
    [ -n "$raw" ] || return 1
    main="$(repo_main_of "$raw" 2>/dev/null || true)"
    [ -n "$main" ] || return 1
    if [ "${#REPOS[@]}" -gt 0 ]; then
        for i in $(seq 0 $(( ${#REPOS[@]} - 1 ))); do
            if [ "${REPOS[$i]}" = "$main" ]; then
                case ",${REPO_SRCS[$i]}," in
                *",$src,"*) : ;;
                *) REPO_SRCS[$i]="${REPO_SRCS[$i]},$src" ;;
                esac
                return 0
            fi
        done
    fi
    REPOS+=("$main")
    REPO_SRCS+=("$src")
    return 0
}

# ===========================================================================
# DISCOVERY
# ===========================================================================
SOURCES_ENABLED="${REAP_DISCOVERY_SOURCES:-primary,engine,inflight-repos,event-logs,ledger,neighborhood}"
src_on() { case ",$SOURCES_ENABLED," in *",$1,"*) return 0 ;; esac; return 1; }

TEAM_DIR_BASE="${REAP_TEAM_DIR:-$HOME/.claude/teams}"
LEDGER="${REAP_LEDGER:-$HOME/.claude/state/reap-known-repos.txt}"
NEIGHBORHOOD_MAX="${REAP_NEIGHBORHOOD_MAX:-200}"

add_repo "$REPO_ROOT" primary || true

if [ "$DISCOVER" -eq 1 ]; then
    # --- engine: the repository the engine's own bytes live in --------------
    if src_on engine; then
        _eng="${REAP_ENGINE_ROOT:-${RICHOS_ENGINE_ROOT:-${CLAUDE_PLUGIN_ROOT:-$_FALLBACK_ROOT}}}"
        add_repo "$_eng" engine \
            || blind "engine source: '$_eng' is not inside a git checkout, so the engine's own repository was not swept"
    fi

    # --- inflight-repos: what the session's git-jurisdiction resolver saw ----
    if src_on inflight-repos; then
        _seen_any=0
        if [ -d "$TEAM_DIR_BASE" ]; then
            for _f in "$TEAM_DIR_BASE"/*/inflight-repos.txt; do
                [ -f "$_f" ] || continue
                _seen_any=1
                while IFS= read -r _line || [ -n "$_line" ]; do
                    [ -n "$_line" ] || continue
                    add_repo "$_line" inflight-repos || true
                done <"$_f"
            done
        fi
        [ "$_seen_any" -eq 1 ] \
            || blind "inflight-repos source: no inflight-repos.txt under $TEAM_DIR_BASE — repositories this session touched only through a hand-rolled worktree may be invisible to this source"
    fi

    # --- event-logs: cwd fields in the session's own lifecycle logs ---------
    if src_on event-logs; then
        if command -v python3 >/dev/null 2>&1 && [ -d "$TEAM_DIR_BASE" ]; then
            while IFS= read -r _line || [ -n "$_line" ]; do
                [ -n "$_line" ] || continue
                add_repo "$_line" event-logs || true
            done < <(TEAM_DIR_BASE="$TEAM_DIR_BASE" python3 - <<'PY' 2>/dev/null || true
import glob, json, os
base = os.environ["TEAM_DIR_BASE"]
seen = set()
for name in ("worker-events.jsonl", "idle-events.jsonl", "task-events.jsonl"):
    for p in glob.glob(os.path.join(base, "*", name)):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if '"cwd"' not in line:
                        continue
                    try:
                        cwd = (json.loads(line).get("cwd") or "").strip()
                    except Exception:
                        continue
                    if cwd and cwd not in seen:
                        seen.add(cwd)
                        print(cwd)
        except Exception:
            continue
PY
            )
        else
            blind "event-logs source: python3 unavailable or $TEAM_DIR_BASE absent — agent cwds were not read"
        fi
    fi

    # --- ledger: repositories this reaper has seen before -------------------
    if src_on ledger; then
        if [ -f "$LEDGER" ]; then
            while IFS= read -r _line || [ -n "$_line" ]; do
                [ -n "$_line" ] || continue
                add_repo "$_line" ledger || true
            done <"$LEDGER"
        fi
    fi

    # --- neighborhood: siblings of a repository already known ---------------
    # This is the source that finds a checkout and a worktree container no log
    # mentions. It is bounded on purpose: never $HOME, never /, and never a
    # parent with more entries than REAP_NEIGHBORHOOD_MAX — and every bound it
    # hits is DECLARED rather than silently applied.
    if src_on neighborhood; then
        _seed_count="${#REPOS[@]}"
        _parents=""
        if [ "$_seed_count" -gt 0 ]; then
            for _i in $(seq 0 $(( _seed_count - 1 ))); do
                _p="$(dirname "${REPOS[$_i]}")"
                case "$_parents" in *"|$_p|"*) continue ;; esac
                _parents="$_parents|$_p|"
            done
        fi
        _home_p="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
        _oldifs="$IFS"; IFS='|'
        for _p in $_parents; do
            IFS="$_oldifs"
            if [ -n "$_p" ] && [ -d "$_p" ]; then
                if [ "$_p" = "/" ] || [ "$_p" = "$_home_p" ]; then
                    blind "neighborhood scan skipped for '$_p' — scanning \$HOME or / is not a bounded question, so sibling repositories there are NOT covered"
                else
                    _n="$(ls -1 "$_p" 2>/dev/null | wc -l | tr -d ' ')"
                    if [ -n "$_n" ] && [ "$_n" -gt "$NEIGHBORHOOD_MAX" ]; then
                        blind "neighborhood scan skipped for '$_p' — $_n entries exceeds REAP_NEIGHBORHOOD_MAX=$NEIGHBORHOOD_MAX, so sibling repositories there are NOT covered"
                    else
                        for _c in "$_p"/*; do
                            [ -d "$_c" ] || continue
                            add_repo "$_c" neighborhood || true
                        done
                    fi
                fi
            fi
            IFS='|'
        done
        IFS="$_oldifs"
    fi
else
    blind "discovery is OFF (--discover not passed) — ONLY '$REPO_ROOT' was considered; worktrees in every other repository on this machine are invisible to this run"
fi

# ===========================================================================
# OWNER JUDGMENT — the ledger first, the transcript as fallback, ONE resolver
# ===========================================================================
# The verdict for every hand-rolled worktree comes from ONE call into
# scripts/lib/worktree-ledger.py (judge-batch), which itself IMPORTS
# scripts/lib/agent-liveness.py for the lock rule rather than paraphrasing it.
# There is deliberately no second implementation of "alive" here: two of them
# is how one silently becomes the stale one.
#
# The table is built AFTER the inventory (it needs the candidate list) and
# BEFORE the sweep. Its absence is DECLARED, never silently treated as "every
# owner is dead" or "every owner is alive".
LEDGER_PY="$LIB_DIR/worktree-ledger.py"
LIVENESS_PY="$LIB_DIR/agent-liveness.py"
WT_LEDGER="${REAP_WORKTREE_LEDGER:-${RICHOS_WORKTREE_LEDGER:-$HOME/.claude/state/worktree-ledger.jsonl}}"
export RICHOS_WORKTREE_LEDGER="$WT_LEDGER"

# --- The transcript FALLBACK ----------------------------------------------
# Kept for spawns that predate the ledger. It was the ONLY source, keyed by
# the SWEPT repository's project directory and reading the newest transcript
# there — for a cross-repository sweep, a directory holding no transcript at
# all, and even elsewhere never the file that names last week's agent. Now
# the ledger library indexes EVERY transcript under the projects directory
# (measured: ~150 files, 0.7s) unless explicit --transcript paths were given,
# which is what a hermetic test passes.
TRANSCRIPTS=()
TRANSCRIPT_MODE=""
_projects="${REAP_PROJECTS_DIR:-$HOME/.claude/projects}"
if [ "${#TRANSCRIPT_ARGS[@]}" -gt 0 ]; then
    for _t in "${TRANSCRIPT_ARGS[@]}"; do
        [ -n "$_t" ] && [ -f "$_t" ] && TRANSCRIPTS+=("$_t")
    done
    TRANSCRIPT_MODE="explicit"
    [ "${#TRANSCRIPTS[@]}" -gt 0 ] \
        || blind "owner liveness: no session transcript found at the --transcript path(s) given — the transcript FALLBACK is unavailable; owners are judged from the ownership ledger alone"
elif [ -d "$_projects" ] && [ -n "$(ls -1 "$_projects"/*/*.jsonl 2>/dev/null | head -1)" ]; then
    TRANSCRIPT_MODE="index"
else
    blind "owner liveness: no session transcript found under '$_projects' — the transcript FALLBACK is unavailable; owners are judged from the ownership ledger alone"
fi

# --- Teammate names this machine has a record of spawning -------------------
# Used ONLY to decide whether a neighborhood-discovered repository is
# reap-eligible or report-only. It is evidence that a session touched that
# repository; it is never evidence that anyone is dead. Three sources: the
# per-session spawned-names.log, the ledger's registered teammates, and every
# name any transcript joins to an agent id — the last two outlive the session
# directory, which is what lets a prior session's repository stay eligible.
SPAWNED_NAMES=""
if [ -d "$TEAM_DIR_BASE" ]; then
    for _f in "$TEAM_DIR_BASE"/*/spawned-names.log; do
        [ -f "$_f" ] || continue
        SPAWNED_NAMES="$SPAWNED_NAMES
$(cat "$_f" 2>/dev/null || true)"
    done
fi
if [ -f "$LEDGER_PY" ] && command -v python3 >/dev/null 2>&1; then
    _nargs=()
    if [ "$TRANSCRIPT_MODE" = "explicit" ] && [ "${#TRANSCRIPTS[@]}" -gt 0 ]; then
        for _t in "${TRANSCRIPTS[@]}"; do _nargs+=(--transcript "$_t"); done
    elif [ "$TRANSCRIPT_MODE" = "index" ]; then
        _nargs+=(--projects-dir "$_projects")
    fi
    SPAWNED_NAMES="$SPAWNED_NAMES
$(RICHOS_PROJECTS_DIR="$_projects" python3 "$LEDGER_PY" --ledger "$WT_LEDGER" names ${_nargs[@]+"${_nargs[@]}"} 2>/dev/null || true)"
fi
is_spawned_name() { # <name>
    [ -n "${1:-}" ] || return 1
    [ -n "$SPAWNED_NAMES" ] || return 1
    printf '%s\n' "$SPAWNED_NAMES" | grep -qx -- "$1"
}

# --- What counts as a TEAMMATE's worktree at all ----------------------------
# The inventory is not exclusively ours: `richos` holds a CI checkout at
# /private/tmp/ci-base and a Codex worktree at ~/.codex/worktrees/2204/richos
# (measured 2026-09-02). Neither is teammate-shaped, neither is in any spawn
# record, and neither is a hole in OUR record — so neither may FAIL the run.
# A hand-rolled tree is teammate-owned when its branch or directory name is
# teammate-shaped (`worktree-*`, `<role>-<model>-<identifier>`) OR is a name
# this machine has a record of spawning. Anything else is an OPERATOR worktree:
# inventoried and printed every run, never mutated, never a verdict.
# (A registration by exact path is judged BEFORE this question is asked, so a
# helper-created tree with any name at all is still a teammate's.)
_models="${ALLOWED_MODELS:-}"
if [ -z "$_models" ] && [ -f "$ENTITY_ROOT/orchestration.config" ]; then
    _models="$(sed -n 's/^ALLOWED_MODELS="\(.*\)"$/\1/p' "$ENTITY_ROOT/orchestration.config" | head -1)"
fi
[ -n "$_models" ] || _models="fable opus sonnet haiku"
TEAMMATE_BRANCH_RE="^[a-z][a-z0-9]{1,15}-($(printf '%s' "$_models" | tr ' ' '|'))-[a-z0-9]{1,12}$"
is_teammate_shaped() { # <name>
    [ -n "${1:-}" ] || return 1
    case "$1" in worktree-*) return 0 ;; esac
    printf '%s' "$1" | grep -qE "$TEAMMATE_BRANCH_RE"
}
is_teammate_owned() { # <branch-or-owner> <dirname>
    is_teammate_shaped "${1:-}" || is_teammate_shaped "${2:-}" \
        || is_spawned_name "${1:-}" || is_spawned_name "${2:-}"
}

# Worktree PATHS the ledger has registered — what create-teammate-worktree.sh
# writes. A registration by path makes a repository reap-eligible and its tree
# a teammate's, whatever the tree is named.
REGISTERED_PATHS=""
if [ -f "$LEDGER_PY" ] && [ -f "$WT_LEDGER" ] && command -v python3 >/dev/null 2>&1; then
    REGISTERED_PATHS="$(python3 "$LEDGER_PY" --ledger "$WT_LEDGER" paths 2>/dev/null || true)"
fi
is_registered_path() { # <path>
    [ -n "${1:-}" ] && [ -n "$REGISTERED_PATHS" ] || return 1
    local real
    real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
    printf '%s\n' "$REGISTERED_PATHS" | grep -qxF -- "$real"
}

# ===========================================================================
# INVENTORY — every linked worktree of every discovered repository
# ===========================================================================
# Parallel arrays; bash 3.2 (macOS) has no associative arrays.
WT_REPO=()
WT_PATH=()
WT_LOCKED=()
WT_BRANCH=()
WT_CLASS=()

REPO_REACHABLE=()
REPO_ELIGIBLE=()
REGISTERED_ALL=""
CONTAINERS=""

_cur_path=""
_cur_locked=0
_cur_branch=""
_have=0
_first=1
_repo_has_teammate=0
_repo_now=""

flush_wt() {
    [ "$_have" -eq 1 ] || return 0
    REGISTERED_ALL="$REGISTERED_ALL
$_cur_path"
    if [ "$_first" -eq 1 ]; then
        # The repository's own main worktree. Never a candidate, and it is
        # skipped by POSITION (git guarantees it is the first entry) rather
        # than by any path shape.
        _first=0
        return 0
    fi
    WT_REPO+=("$_repo_now")
    WT_PATH+=("$_cur_path")
    WT_LOCKED+=("$_cur_locked")
    WT_BRANCH+=("$_cur_branch")
    case "$_cur_path" in
    "$_repo_now"/.claude/worktrees/agent-*) WT_CLASS+=("native") ;;
    *)                                      WT_CLASS+=("hand-rolled") ;;
    esac
    if is_spawned_name "$_cur_branch" || is_spawned_name "$(basename "$_cur_path")" \
       || is_registered_path "$_cur_path"; then
        _repo_has_teammate=1
    fi
    _cont="$(dirname "$_cur_path")"
    case "$CONTAINERS" in *"|$_cont|"*) : ;; *) CONTAINERS="$CONTAINERS|$_cont|" ;; esac
    return 0
}

if [ "${#REPOS[@]}" -gt 0 ]; then
    for _ri in $(seq 0 $(( ${#REPOS[@]} - 1 ))); do
        _repo_now="${REPOS[$_ri]}"
        porcelain="$(git -C "$_repo_now" worktree list --porcelain 2>/dev/null || true)"
        if [ -z "$porcelain" ]; then
            REPO_REACHABLE+=("0")
            REPO_ELIGIBLE+=("0")
            blind "repository '$_repo_now' (source: ${REPO_SRCS[$_ri]}): 'git worktree list' returned nothing — its worktrees were NOT examined"
            continue
        fi
        REPO_REACHABLE+=("1")

        _first=1
        _cur_path=""; _cur_locked=0; _cur_branch=""; _have=0
        _repo_has_teammate=0

        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
            worktree\ *)
                flush_wt
                _cur_path="${line#worktree }"
                _cur_locked=0
                _cur_branch=""
                _have=1
                ;;
            locked*)              _cur_locked=1 ;;
            branch\ refs/heads/*) _cur_branch="${line#branch refs/heads/}" ;;
            esac
        done <<PORCELAIN_EOF
$porcelain
PORCELAIN_EOF
        flush_wt

        # Gate 0 — is this repository reap-eligible, or report-only?
        case ",${REPO_SRCS[$_ri]}," in
        *,primary,* | *,engine,* | *,inflight-repos,* | *,event-logs,* | *,ledger,*)
            REPO_ELIGIBLE+=("1") ;;
        *)
            if [ "$_repo_has_teammate" -eq 1 ]; then
                REPO_ELIGIBLE+=("1")
            else
                REPO_ELIGIBLE+=("0")
            fi
            ;;
        esac

        # A repo's own conventional containers, even when currently empty, so
        # residue and orphan processes there are still looked for.
        for _c in "$_repo_now/.claude/worktrees" "$_repo_now/.worktrees"; do
            [ -d "$_c" ] || continue
            case "$CONTAINERS" in *"|$_c|"*) : ;; *) CONTAINERS="$CONTAINERS|$_c|" ;; esac
        done
    done
fi

# --- Persist the ledger — REAP-ELIGIBLE REPOSITORIES ONLY -------------------
# The ledger's job is to remember a repository whose session evidence has since
# expired, so a tree there is still swept next week. It is emphatically NOT a
# way for a repository to earn eligibility by having once been looked at.
#
# THIS WAS WRITTEN WRONG FIRST AND CAUGHT ON THE SECOND RUN. Recording every
# DISCOVERED repository meant a neighborhood-only repository was written to the
# ledger, and on the next run the `ledger` source made it reap-eligible — the
# report-only boundary evaporated after exactly one sweep, silently, and 20
# repositories nobody had touched became removable. Eligibility is decided by
# session evidence; the ledger only carries eligibility forward, never confers
# it. Written in both modes: knowing a repository exists is an observation, not
# a mutation, and a ledger that only grew under --execute would be empty on
# precisely the runs trying to find out what is out there.
if [ "$DISCOVER" -eq 1 ] && src_on ledger && [ "${#REPOS[@]}" -gt 0 ]; then
    _ldir="$(dirname "$LEDGER")"
    if mkdir -p "$_ldir" 2>/dev/null; then
        {
            for _i in $(seq 0 $(( ${#REPOS[@]} - 1 ))); do
                [ "${REPO_ELIGIBLE[$_i]}" = "1" ] || continue
                printf '%s\n' "${REPOS[$_i]}"
            done
            [ -f "$LEDGER" ] && cat "$LEDGER"
            true
        } | sort -u >"$LEDGER.tmp.$$" 2>/dev/null \
            && mv "$LEDGER.tmp.$$" "$LEDGER" 2>/dev/null \
            || rm -f "$LEDGER.tmp.$$" 2>/dev/null || true
    fi
fi

# --- The owner-verdict table: one judge-batch call over every hand-rolled
# candidate in a reap-eligible repository -----------------------------------
OWNER_VERDICTS=""
_hr_tsv=""
if [ "${#WT_PATH[@]}" -gt 0 ]; then
    for _i in $(seq 0 $(( ${#WT_PATH[@]} - 1 ))); do
        [ "${WT_CLASS[$_i]}" = "hand-rolled" ] || continue
        _hr_tsv="$_hr_tsv${WT_REPO[$_i]}	${WT_PATH[$_i]}	${WT_BRANCH[$_i]}	$(basename "${WT_PATH[$_i]}")
"
    done
fi
if [ -n "$_hr_tsv" ]; then
    if [ ! -f "$LEDGER_PY" ]; then
        blind "owner liveness: the ownership ledger library is missing at $LEDGER_PY — EVERY hand-rolled worktree is undecidable in this run and none can be reaped"
    elif ! command -v python3 >/dev/null 2>&1; then
        blind "owner liveness: python3 is not on PATH — EVERY hand-rolled worktree is undecidable in this run"
    else
        [ -f "$LIVENESS_PY" ] || blind "owner liveness: the lock resolver is missing at $LIVENESS_PY — native locks cannot be read; owners are judged from recorded session identity and witnessed terminations only"
        [ -f "$WT_LEDGER" ] || blind "owner liveness: no ownership ledger exists yet at $WT_LEDGER — no spawn has been registered on this machine; owners can be judged only through the transcript fallback"
        _targs=()
        if [ "$TRANSCRIPT_MODE" = "explicit" ] && [ "${#TRANSCRIPTS[@]}" -gt 0 ]; then
            for _t in "${TRANSCRIPTS[@]}"; do _targs+=(--transcript "$_t"); done
        elif [ "$TRANSCRIPT_MODE" = "index" ]; then
            _targs+=(--projects-dir "$_projects")
        fi
        OWNER_VERDICTS="$(printf '%s' "$_hr_tsv" | RICHOS_PROJECTS_DIR="$_projects" python3 "$LEDGER_PY" --ledger "$WT_LEDGER" judge-batch --entity "$ENTITY_ROOT" ${_targs[@]+"${_targs[@]}"} 2>/dev/null || true)"
        if [ -z "$OWNER_VERDICTS" ]; then
            blind "owner liveness: judge-batch produced no verdicts (ledger: $WT_LEDGER) — every hand-rolled worktree is undecidable in this run"
        fi
    fi
fi

owner_verdict_for() { # <path> -> "<verdict><TAB><agent-ids><TAB><reason>" or empty
    [ -n "$OWNER_VERDICTS" ] || return 0
    printf '%s\n' "$OWNER_VERDICTS" | awk -F'\t' -v p="$1" '$1==p {print $2"\t"$3"\t"$4; exit}'
}

# record_terminated <agent-id> <worktree> <reason> <witness> — copy a witnessed
# termination into the ledger, once per agent. Best-effort: an unwritable
# ledger never changes a sweep's verdict, it only loses tomorrow's evidence.
record_terminated() {
    [ -f "$LEDGER_PY" ] && command -v python3 >/dev/null 2>&1 || return 0
    python3 "$LEDGER_PY" --ledger "$WT_LEDGER" record terminated --once \
        --agent-id "$1" --worktree "$2" --reason "$3" --witness "$4" >/dev/null 2>&1 || true
}

# --- SHELL LABELING — reporting only, wired to nothing that decides --------
# See the header. A native worktree is a SHELL when the ledger joins it to a
# workspace of the SAME agent in ANOTHER repository, or when it carries the
# sparse-checkout that lib/shell-worktree-sparse.py applies only to shells. A
# native worktree the ledger has no registration for cannot be classified
# either way; it is reported as plain `native` (the conservative reading) and
# the count of such trees is DECLARED in `blind:` rather than implied away.
REMOVER_SH="${REAP_REMOVER:-$SCRIPT_DIR/remove-agent-worktree.sh}"
if [ "$EXECUTE" -eq 1 ] && [ ! -x "$REMOVER_SH" ]; then
    blind "removal: the sanctioned remover is missing or not executable at $REMOVER_SH — NOTHING will be removed in this --execute run; every selected worktree is reported as an ERROR rather than deleted by an unsanctioned route"
fi

SHELL_PATHS=""
if [ -f "$LEDGER_PY" ] && [ -f "$WT_LEDGER" ] && command -v python3 >/dev/null 2>&1; then
    SHELL_PATHS="$(python3 "$LEDGER_PY" --ledger "$WT_LEDGER" shells 2>/dev/null || true)"
fi

is_shell() { # <worktree-path> -> 0 when this native worktree is a cross-repo shell
    if [ -n "$SHELL_PATHS" ] && printf '%s\n' "$SHELL_PATHS" | grep -Fxq -- "$1"; then
        return 0
    fi
    [ "$(git -C "$1" config --get core.sparseCheckout 2>/dev/null)" = "true" ] && return 0
    return 1
}

# unmerged_subjects <repo> <target-ref> <branch> — up to three `<sha> <subject>`
# lines, joined, so an `unmerged` skip says WHAT is unlanded. Two teammates'
# committed escalations sat unread for three days under a bare `unmerged(+1)`.
unmerged_subjects() {
    local out
    # THE JOIN IS awk, NOT sed. The first version used `tr '\n' '\a'` and
    # `sed 's/\a/ | /g'`; BSD sed reads `\a` as the LETTER a, so every `a` in
    # every commit subject became ` | ` and the line was unreadable — a
    # reporting fix that broke its own report. awk interprets no escapes here.
    out="$(git -C "$1" log --no-decorate --format='%h %s' -n 3 "$2..refs/heads/$3" 2>/dev/null \
           | cut -c1-160 \
           | awk 'NR==1 {printf "%s", $0; next} {printf " | %s", $0}')"
    [ -n "$out" ] || out="(no commit subject could be read — inspect the branch by hand)"
    printf '%s' "$out"
}

# ===========================================================================
# THE SWEEP
# ===========================================================================
echo "=== reap-stale-worktrees: $MODE_LABEL — primary: $REPO_ROOT — entity: $ENTITY_ROOT ==="
if [ "$EXECUTE" -eq 0 ]; then
    echo "=== DRY-RUN: no worktree/branch will be removed, no lock broken, no prune run. Pass --execute to perform. ==="
fi

REAP_COUNT=0
# WOULD_COUNT is DRY-RUN's counter and it is deliberately a different variable
# from REAP_COUNT. Sharing one and renaming the label at print time is what
# produced `reaped=11` over a run that removed nothing: one number cannot
# honestly answer both "how many did you remove" and "how many could be".
WOULD_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0
SKIP_LOCKED=0
SKIP_LOCKED_LIVE=0
SKIP_QUARANTINED=0
SKIP_UNMERGED=0
SKIP_DIRTY=0
SKIP_LIVE_PROCESS=0
SKIP_MISSING_DIR=0
SKIP_NO_BRANCH=0
SKIP_OWNER_ALIVE=0
SKIP_OWNER_INDETERMINATE=0
SKIP_OWNER_UNRESOLVED=0
SKIP_OPERATOR=0
SKIP_REPORT_ONLY=0
SKIP_DUPLICATE=0
N_SHELLS=0
N_UNCLASSIFIED_NATIVE=0
CLAIMED_PATHS=""

BR_SWEPT=0
BR_SKIPPED=0
N_NATIVE=0
N_HANDROLLED=0

skip() { # <id> <reason>
    echo "SKIP $1 $2"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

repo_index_of() { # <repo-path> -> index on stdout, or empty
    local r="$1" i
    if [ "${#REPOS[@]}" -gt 0 ]; then
        for i in $(seq 0 $(( ${#REPOS[@]} - 1 ))); do
            [ "${REPOS[$i]}" = "$r" ] && { printf '%s' "$i"; return 0; }
        done
    fi
    return 0
}

repo_eligible_at() { # <repo-path> -> 0 if reap-eligible
    local idx
    idx="$(repo_index_of "$1")"
    [ -n "$idx" ] || return 1
    [ "${REPO_ELIGIBLE[$idx]}" = "1" ] && return 0
    return 1
}

_last_repo=""
if [ "${#WT_PATH[@]}" -gt 0 ]; then
    for i in $(seq 0 $(( ${#WT_PATH[@]} - 1 ))); do
        repo="${WT_REPO[$i]}"
        path="${WT_PATH[$i]}"
        locked="${WT_LOCKED[$i]}"
        branch_name="${WT_BRANCH[$i]}"
        class="${WT_CLASS[$i]}"
        id="$(basename "$path")"

        if [ "$repo" != "$_last_repo" ]; then
            _idx="$(repo_index_of "$repo")"
            _elig="report-only"
            repo_eligible_at "$repo" && _elig="reap-eligible"
            echo "--- repo: $repo (source: ${REPO_SRCS[${_idx:-0}]}, $_elig) ---"
            _last_repo="$repo"
        fi

        disp_class="$class"
        if [ "$class" = "native" ]; then
            N_NATIVE=$((N_NATIVE + 1))
            if is_shell "$path"; then
                disp_class="native-shell"
                N_SHELLS=$((N_SHELLS + 1))
            elif ! is_registered_path "$path"; then
                N_UNCLASSIFIED_NATIVE=$((N_UNCLASSIFIED_NATIVE + 1))
            fi
        else
            N_HANDROLLED=$((N_HANDROLLED + 1))
        fi

        # --- Gate 0: repository reap-eligibility ---
        if ! repo_eligible_at "$repo"; then
            skip "$id" "report-only-repo($disp_class) — '$repo' is known only from the neighborhood scan and holds no worktree owned by a teammate this machine recorded spawning; inventoried, never mutated"
            SKIP_REPORT_ONLY=$((SKIP_REPORT_ONLY + 1))
            continue
        fi

        # --- Gate 0c: ONE DIRECTORY, ONE CLAIMANT ---
        # Two repositories can register the same worktree path — a copied .git
        # does it, and /Users/alex/ab/richos-alex does it today for four of
        # richos's trees. Without this the same directory is inventoried twice
        # (would-remove=11 over 7 real directories) and, under --execute, the
        # second repository runs `git worktree remove` on a path the first has
        # already deleted, failing an otherwise clean run. First reap-eligible
        # claimant wins; the rest are named and never acted on.
        case "$CLAIMED_PATHS" in
        *"|$path|"*)
            skip "$id" "duplicate-registration($disp_class) — this exact directory is already registered by an earlier reap-eligible repository in this run; two repositories claim one directory (a copied .git does this). Only the first claimant may act on it; inventoried here, never mutated"
            SKIP_DUPLICATE=$((SKIP_DUPLICATE + 1))
            continue
            ;;
        esac
        CLAIMED_PATHS="$CLAIMED_PATHS|$path|"

        # --- Gate 0b: a QUARANTINE belongs to the reconciler, not to this ---
        # `<path>.richos-terminal-<session8>-<agentid>` is the name a terminal
        # ingress gives a worktree it has claimed (lib/worktree-transactions.py
        # quarantine_name). Only a terminal ingress creates it, and only
        # reconcile-terminal-worktrees.py ever removes it.
        #
        # WHY IT GETS ITS OWN LINE INSTEAD OF `locked(native)`. On 2026-09-04
        # thirty of these stood in femcboost, and this inventory reported
        # `reaped=2 skipped=34 errors=0` with `verdict: CLEAN — every candidate
        # was decided`. Every word of that was true by the reaper's own
        # definitions and it described the exact pile the CEO had opened his
        # IDE to find. A quarantine is not a routine skip: it is a worktree the
        # system has already decided to destroy and has not finished
        # destroying, so it is counted by itself and it is not allowed to sit
        # inside a CLEAN verdict.
        case "$(basename "$path")" in
            *.richos-terminal-*)
                skip "$id" "quarantined($disp_class) — claimed by a terminal transaction; reconcile-terminal-worktrees.py owns its removal and this inventory never touches it. Its state (and whether it is BLOCKED) is that tool's --status, not this line"
                SKIP_QUARANTINED=$((SKIP_QUARANTINED + 1))
                continue
                ;;
        esac

        # Directory gone but still registered -> report + let `worktree prune`
        # (execute-only, end of run) clear the registration. No further gate.
        if [ ! -d "$path" ]; then
            skip "$id" "missing-dir($disp_class)"
            SKIP_MISSING_DIR=$((SKIP_MISSING_DIR + 1))
            continue
        fi

        # --- Gate 1: lock ---
        if [ "$locked" -eq 0 ] && [ "$class" = "native" ]; then
            # A registered, UNLOCKED native isolation worktree is the positive
            # termination signal the resolver already accepts. It is about to
            # be destroyed by this very sweep (or by a land), so it is copied to
            # the ledger NOW — that is the evidence that lets a hand-rolled
            # worktree in another repository be judged after this one is gone.
            record_terminated "${id#agent-}" "$path" "native isolation worktree registered and unlocked" "reaper-observation"
        fi
        if [ "$locked" -eq 1 ]; then
            if [ "$UNLOCK_STALE" -eq 0 ]; then
                skip "$id" "locked($disp_class)"
                SKIP_LOCKED=$((SKIP_LOCKED + 1))
                continue
            fi

            admin_dir="$(git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
            lock_file="$admin_dir/locked"
            if [ -z "$admin_dir" ] || [ ! -f "$lock_file" ]; then
                skip "$id" "locked-possibly-live($disp_class)"
                SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
                continue
            fi

            lock_mtime="$(mtime_of "$lock_file" || true)"
            now="$(date +%s)"
            pids="$(live_pids_for "$path")"

            if [ -z "$lock_mtime" ]; then
                skip "$id" "locked-possibly-live($disp_class)"
                SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
                continue
            fi
            age=$((now - lock_mtime))

            if [ -n "$pids" ] || [ "$age" -lt 7200 ]; then
                skip "$id" "locked-possibly-live($disp_class)"
                SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
                continue
            fi

            if [ "$EXECUTE" -eq 1 ]; then
                if ! git -C "$repo" worktree unlock "$path" >/dev/null 2>&1; then
                    echo "ERROR: failed to unlock stale lock on $id (age ${age}s, no live process) — leaving alone" >&2
                    skip "$id" "unlock-failed"
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    continue
                fi
                echo "  (unlocked stale lock on $id — age ${age}s, no live process)"
                [ "$class" = "native" ] && record_terminated "${id#agent-}" "$path" "stale lock broken: ${age}s old, no live process" "reaper-observation"
            else
                echo "  (DRY-RUN: would unlock stale lock on $id — age ${age}s, no live process — then re-evaluate)"
            fi
        fi

        # --- Gate 2: owner termination signal (hand-rolled only) ---
        # A hand-rolled worktree takes NO lock, so gate 1 proved nothing about
        # it. The verdict comes from the ownership ledger (see the header);
        # NOT-ALIVE is only ever emitted on POSITIVE evidence, so there is no
        # "observed" column to check any more — absence never reaches here as
        # NOT-ALIVE at all.
        if [ "$class" = "hand-rolled" ]; then
            owner="$branch_name"
            [ -n "$owner" ] || owner="$id"
            row="$(owner_verdict_for "$path")"
            verdict="$(printf '%s' "$row" | cut -f1)"
            reason="$(printf '%s' "$row" | cut -f3-)"
            case "$verdict" in
            ALIVE)
                skip "$id" "owner-alive($owner — $reason)"
                SKIP_OWNER_ALIVE=$((SKIP_OWNER_ALIVE + 1))
                continue
                ;;
            NOT-ALIVE)
                echo "  (owner $owner terminated — $reason)"
                ;;
            INDETERMINATE)
                skip "$id" "owner-indeterminate($owner — $reason; INDETERMINATE is never guessed into dead)"
                SKIP_OWNER_INDETERMINATE=$((SKIP_OWNER_INDETERMINATE + 1))
                continue
                ;;
            *)
                if ! is_teammate_owned "$owner" "$id"; then
                    skip "$id" "operator-worktree('$owner' is neither teammate-shaped nor a name this machine recorded spawning, and no registration names this path — not ours; inventoried, never mutated, not a hole in the record)"
                    SKIP_OPERATOR=$((SKIP_OPERATOR + 1))
                    continue
                fi
                [ -n "$reason" ] || reason="no owner verdict was produced for this path (see blind:)"
                skip "$id" "owner-unresolved($owner — $reason — a hand-rolled worktree takes no lock, so quiet is not death)"
                SKIP_OWNER_UNRESOLVED=$((SKIP_OWNER_UNRESOLVED + 1))
                continue
                ;;
            esac
        fi

        # --- Gate 3: merged ---
        if [ -z "$branch_name" ]; then
            skip "$id" "no-branch($disp_class — detached HEAD; nothing to verify against, and unverifiable is not permission)"
            SKIP_NO_BRANCH=$((SKIP_NO_BRANCH + 1))
            continue
        fi
        if ! git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch_name" >/dev/null; then
            skip "$id" "no-branch($disp_class)"
            SKIP_NO_BRANCH=$((SKIP_NO_BRANCH + 1))
            continue
        fi
        target_ref="$(git -C "$repo" symbolic-ref -q --short HEAD || true)"
        [ -n "$target_ref" ] || target_ref="$(git -C "$repo" rev-parse HEAD)"
        if ! git -C "$repo" merge-base --is-ancestor "refs/heads/$branch_name" "$target_ref" 2>/dev/null; then
            n="$(git -C "$repo" rev-list --count "$target_ref..refs/heads/$branch_name" 2>/dev/null || echo '?')"
            _why=""
            [ "$disp_class" = "native-shell" ] && _why=" — a SHELL is never written to, so a commit on one is an ANOMALY: it is almost always an escalation record"
            skip "$id" "unmerged(+$n)$_why — $(unmerged_subjects "$repo" "$target_ref" "$branch_name") — never swept; READ it before removing anything"
            SKIP_UNMERGED=$((SKIP_UNMERGED + 1))
            continue
        fi

        # --- Gate 4: clean ---
        dirty_lines="$(git -C "$path" status --porcelain 2>/dev/null || true)"
        if [ -n "$dirty_lines" ]; then
            n="$(printf '%s\n' "$dirty_lines" | grep -c . || true)"
            skip "$id" "dirty($n)"
            SKIP_DIRTY=$((SKIP_DIRTY + 1))
            continue
        fi

        # --- Gate 5: no live process ---
        pids="$(live_pids_for "$path")"
        if [ -n "$pids" ]; then
            skip "$id" "live-process($pids)"
            SKIP_LIVE_PROCESS=$((SKIP_LIVE_PROCESS + 1))
            continue
        fi

        # --- All gates passed: REAP-eligible ---
        if [ "$EXECUTE" -eq 1 ]; then
            if [ -f "$repo/scripts/collect-worktree-artifacts.sh" ]; then
                if ! bash "$repo/scripts/collect-worktree-artifacts.sh" "$path"; then
                    echo "WARN: artifact collection failed for $id — proceeding with removal anyway" >&2
                fi
            fi

            # THE GATES ARE A FILTER; THE REMOVER IS THE AUTHORITY.
            # scripts/remove-agent-worktree.sh is the ONLY sanctioned removal
            # path (its companion PreToolUse guard exists to force everything
            # through it) and it re-asks the liveness question against the
            # ENTITY's isolation lock using scripts/lib/agent-liveness.sh —
            # the one resolver the whole engine shares. This script used to
            # answer that question a second way and then delete on its own
            # answer. Two implementations of "alive" is how one of them
            # silently becomes the stale one.
            #
            # --branch is deliberately NOT passed. The remover deletes with
            # `git branch -D`; this loop keeps `-d`, which REFUSES a branch
            # holding unmerged commits and is the backstop for a gate 3 that
            # is somehow wrong. Nor is --force passed: gate 4 already proved
            # the tree clean of tracked AND untracked files, so a removal that
            # needs --force means a gate was wrong and must fail loudly.
            _owner_agent=""
            if [ "$class" = "native" ]; then
                _owner_agent="${id#agent-}"
            else
                _owner_agent="$(owner_verdict_for "$path" | cut -f2 | cut -d, -f1)"
            fi
            _rm_rc=0
            _rm_out=""
            if [ -n "$_owner_agent" ] && [ -x "$REMOVER_SH" ]; then
                _rm_out="$(REMOVE_AGENT_ENTITY_REPO="$ENTITY_ROOT" \
                    "$REMOVER_SH" --owner "$_owner_agent" --repo "$repo" \
                    --entity-repo "$ENTITY_ROOT" "$path" 2>&1)" || _rm_rc=$?
            else
                # No sanctioned remover reachable, or no owner id to check
                # against. Removing anyway would be exactly the unilateral
                # deletion this routing exists to end, so it does not happen.
                _rm_rc=90
                _rm_out="no owner agent id resolved for this path, or the sanctioned remover is not executable at $REMOVER_SH"
            fi

            if [ "$_rm_rc" -eq 0 ]; then
                [ "$class" = "native" ] && record_terminated "${id#agent-}" "$path" "native isolation worktree reaped: unlocked, merged, clean, no live process" "reaper-removal"
                if git -C "$repo" branch -d "$branch_name" >/dev/null 2>&1; then
                    echo "REAP $id"
                    REAP_COUNT=$((REAP_COUNT + 1))
                else
                    echo "ERROR: removed worktree $id but the branch deletion of $branch_name refused (unmerged commits protecting it?) — investigate manually" >&2
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                fi
            elif [ "$_rm_rc" -eq 3 ]; then
                # THE TWO AUTHORITIES DISAGREE. Every gate above said this
                # tree's owner is not alive; the sanctioned remover, reading
                # the entity lock through the shared resolver, refused. That
                # contradiction is never resolved in favor of deleting, and it
                # is never a routine skip either — it FAILS the run.
                echo "ERROR: the gates selected $id for removal but the sanctioned remover REFUSED it (owner '$_owner_agent' alive or indeterminate). Nothing was removed. The two liveness authorities disagree, which is a defect in one of them: $(printf '%s' "$_rm_out" | tr '\n' ' ' | cut -c1-400)" >&2
                ERROR_COUNT=$((ERROR_COUNT + 1))
            else
                echo "ERROR: worktree removal failed for $id (remove-agent-worktree.sh exit $_rm_rc): $(printf '%s' "$_rm_out" | tr '\n' ' ' | cut -c1-400)" >&2
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        else
            echo "DRY-RUN REAP $id"
            WOULD_COUNT=$((WOULD_COUNT + 1))
        fi
    done
fi

# ===========================================================================
# THE BRANCH SWEEP — refs/heads/ of every reap-eligible repository
# ===========================================================================
# See the header. Candidates are teammate-shaped branches only; every gate is
# named in the SKIP-BRANCH reason. Computed AFTER the worktree loop so a branch
# whose worktree was just reaped (and whose -d succeeded) is not reported
# twice, and a branch whose -d was refused is caught on the next pass.
if [ "${#REPOS[@]}" -gt 0 ]; then
    for _ri in $(seq 0 $(( ${#REPOS[@]} - 1 ))); do
        [ "${REPO_ELIGIBLE[$_ri]}" = "1" ] || continue
        [ "${REPO_REACHABLE[$_ri]}" = "1" ] || continue
        _repo="${REPOS[$_ri]}"
        _current="$(git -C "$_repo" symbolic-ref -q --short HEAD 2>/dev/null || true)"
        _attached="$(git -C "$_repo" worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p' || true)"
        _registered=""
        if [ -f "$LEDGER_PY" ] && [ -f "$WT_LEDGER" ] && command -v python3 >/dev/null 2>&1; then
            _registered="$(python3 "$LEDGER_PY" --ledger "$WT_LEDGER" branches --repo "$_repo" 2>/dev/null || true)"
        fi
        _target="$_current"
        [ -n "$_target" ] || _target="$(git -C "$_repo" rev-parse HEAD 2>/dev/null || true)"
        while IFS= read -r _b || [ -n "$_b" ]; do
            [ -n "$_b" ] || continue
            _cand=0
            is_teammate_shaped "$_b" && _cand=1
            if [ "$_cand" -eq 0 ] && [ -n "$_registered" ] && printf '%s\n' "$_registered" | grep -qxF -- "$_b"; then _cand=1; fi
            [ "$_cand" -eq 1 ] || continue
            if [ -n "$_current" ] && [ "$_b" = "$_current" ]; then
                echo "SKIP-BRANCH $_b current-branch($_repo)"
                BR_SKIPPED=$((BR_SKIPPED + 1))
                continue
            fi
            if printf '%s\n' "$_attached" | grep -qxF -- "$_b"; then
                continue   # attached to a registered worktree: the worktree loop owns it
            fi
            if [ -z "$_target" ] || ! git -C "$_repo" merge-base --is-ancestor "refs/heads/$_b" "$_target" 2>/dev/null; then
                _n="$(git -C "$_repo" rev-list --count "$_target..refs/heads/$_b" 2>/dev/null || echo '?')"
                echo "SKIP-BRANCH $_b unmerged(+$_n)"
                BR_SKIPPED=$((BR_SKIPPED + 1))
                continue
            fi
            _pids="$(live_pids_for "$_b")"
            if [ -n "$_pids" ]; then
                echo "SKIP-BRANCH $_b live-process($_pids)"
                BR_SKIPPED=$((BR_SKIPPED + 1))
                continue
            fi
            if [ "$EXECUTE" -eq 1 ]; then
                if git -C "$_repo" branch -d "$_b" >/dev/null 2>&1; then
                    echo "SWEEP-BRANCH $_b"
                    BR_SWEPT=$((BR_SWEPT + 1))
                else
                    echo "ERROR: branch deletion of $_b in $_repo refused (unmerged commits protecting it?) — investigate manually" >&2
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                fi
            else
                echo "DRY-RUN SWEEP-BRANCH $_b"
                BR_SWEPT=$((BR_SWEPT + 1))
            fi
        done <<BRANCHES_EOF
$(git -C "$_repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)
BRANCHES_EOF
    done
fi

# --- After the loop: prune ---------------------------------------------------
if [ "$EXECUTE" -eq 1 ]; then
    if [ "${#REPOS[@]}" -gt 0 ]; then
        for _i in $(seq 0 $(( ${#REPOS[@]} - 1 ))); do
            [ "${REPO_ELIGIBLE[$_i]}" = "1" ] || continue
            [ "${REPO_REACHABLE[$_i]}" = "1" ] || continue
            git -C "${REPOS[$_i]}" worktree prune || true
        done
    fi
    echo "(ran: git worktree prune in every reap-eligible repository)"
else
    echo "(DRY-RUN: would run 'git worktree prune' in every reap-eligible repository)"
fi

# --- Which containers is it honest to call a WORKTREE CONTAINER? ------------
# A linked worktree's parent directory is not automatically one. The first run
# of this rewrite proved it: a single throwaway worktree at /private/tmp/ci-base
# made /private/tmp a "container", and the residue report then named 39 launchd
# sockets and temp directories as residue, and the orphan-process scan named
# this script's own `tee`. That is the CEO's complaint in miniature — a green
# line every session while the real thing accumulates elsewhere — except the
# failure mode is the other one: a signal buried in noise is a signal ignored.
#
# So a directory qualifies only if it is CONVENTIONALLY a container
# (`.claude/worktrees/`, `.worktrees/`) or is MOSTLY worktrees — at least half
# its immediate subdirectories are registered with git. Anything else is
# DECLARED BLIND rather than silently dropped, because "I did not look there"
# and "there was nothing there" are the two things this report must never
# confuse.
QUALIFIED_CONTAINERS=""
_oldifs="$IFS"; IFS='|'
for _c in $CONTAINERS; do
    IFS="$_oldifs"
    if [ -n "$_c" ] && [ -d "$_c" ]; then
        _base="$(basename "$_c")"
        _parent_base="$(basename "$(dirname "$_c")")"
        if { [ "$_base" = "worktrees" ] && [ "$_parent_base" = ".claude" ]; } || [ "$_base" = ".worktrees" ]; then
            QUALIFIED_CONTAINERS="$QUALIFIED_CONTAINERS|$_c|"
        else
            _subdirs=0
            _registered_here=0
            for d in "$_c"/*/; do
                [ -d "$d" ] || continue
                _subdirs=$((_subdirs + 1))
                real_d="$(cd "${d%/}" 2>/dev/null && pwd -P)" || continue
                if printf '%s\n' "$REGISTERED_ALL" | grep -qxF "$real_d"; then
                    _registered_here=$((_registered_here + 1))
                fi
            done
            if [ "$_subdirs" -gt 0 ] && [ $(( _registered_here * 2 )) -ge "$_subdirs" ]; then
                QUALIFIED_CONTAINERS="$QUALIFIED_CONTAINERS|$_c|"
            else
                blind "'$_c' holds a registered worktree but only $_registered_here of its $_subdirs subdirectories are worktrees, so it is NOT treated as a worktree container — residue and orphaned processes there are NOT reported by this run"
            fi
        fi
    fi
    IFS='|'
done
IFS="$_oldifs"

# --- Residue: on disk in a worktree container, not registered with git -------
RESIDUE_COUNT=0
_oldifs="$IFS"; IFS='|'
for _c in $QUALIFIED_CONTAINERS; do
    IFS="$_oldifs"
    if [ -n "$_c" ] && [ -d "$_c" ]; then
        for d in "$_c"/*/; do
            [ -d "$d" ] || continue
            real_d="$(cd "${d%/}" 2>/dev/null && pwd -P)" || continue
            if printf '%s\n' "$REGISTERED_ALL" | grep -qxF "$real_d"; then
                continue
            fi
            echo "RESIDUE $real_d — present on disk in a worktree container but NOT a registered git worktree (git doesn't own it; investigate manually, never auto-deleted)"
            RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
        done
    fi
    IFS='|'
done
IFS="$_oldifs"

# --- Orphan processes: reap PROCESSES, not just directories ------------------
# A background child can outlive both its agent AND its worktree, then
# re-create the path and write ghost state into it. Named, never killed:
# killing someone else's process is not a decision a session-start hook gets
# to make, and a name in the report is what lets the operator make it.
ORPHAN_COUNT=0
if command -v pgrep >/dev/null 2>&1; then
    _oldifs="$IFS"; IFS='|'
    for _c in $QUALIFIED_CONTAINERS; do
        IFS="$_oldifs"
        if [ -n "$_c" ]; then
            while IFS= read -r _pl || [ -n "$_pl" ]; do
                [ -n "$_pl" ] || continue
                _pid="${_pl%% *}"
                if [ "$_pid" = "$$" ] || [ "$_pid" = "${PPID:-0}" ]; then
                    continue
                fi
                _ref="$(printf '%s' "$_pl" | tr ' ' '\n' | grep -m1 -F "$_c/" || true)"
                [ -n "$_ref" ] || continue
                _sub="${_ref#*$_c/}"
                _sub="${_sub%%/*}"
                _wt="$_c/$_sub"
                if printf '%s\n' "$REGISTERED_ALL" | grep -qxF "$_wt"; then
                    continue
                fi
                echo "ORPHAN-PROCESS pid=$_pid references '$_wt', which is NOT a registered git worktree — cmd: $(printf '%s' "$_pl" | cut -c1-160)"
                ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
            done < <(pgrep -fl "$_c/" 2>/dev/null || true)
        fi
        IFS='|'
    done
    IFS="$_oldifs"
else
    blind "orphan-process scan: pgrep is unavailable — a background child that outlived its worktree would NOT be reported by this run"
fi

# ===========================================================================
# THE REPORT — with its denominator
# ===========================================================================
N_REPOS="${#REPOS[@]}"
N_ELIGIBLE=0
N_REPORT_ONLY=0
N_UNREACHABLE=0
if [ "$N_REPOS" -gt 0 ]; then
    for _i in $(seq 0 $(( N_REPOS - 1 ))); do
        if [ "${REPO_REACHABLE[$_i]}" != "1" ]; then
            N_UNREACHABLE=$((N_UNREACHABLE + 1))
        elif [ "${REPO_ELIGIBLE[$_i]}" = "1" ]; then
            N_ELIGIBLE=$((N_ELIGIBLE + 1))
        else
            N_REPORT_ONLY=$((N_REPORT_ONLY + 1))
        fi
    done
fi
N_WORKTREES="${#WT_PATH[@]}"
# Undecidable = the owner could not be judged. Report-only repositories are a
# deliberate boundary, not a judgment failure, and are counted on their own.
N_UNDECIDABLE=$((SKIP_OWNER_INDETERMINATE + SKIP_OWNER_UNRESOLVED))

SRC_SUMMARY=""
for _s in primary engine inflight-repos event-logs ledger neighborhood; do
    _n=0
    if [ "$N_REPOS" -gt 0 ]; then
        for _i in $(seq 0 $(( N_REPOS - 1 ))); do
            case ",${REPO_SRCS[$_i]}," in *",$_s,"*) _n=$((_n + 1)) ;; esac
        done
    fi
    SRC_SUMMARY="$SRC_SUMMARY $_s=$_n"
done

# THE PAST TENSE BELONGS TO --execute ALONE. `reaped=11` was printed by a run
# that removed nothing, under a header that said so in a parenthetical nobody
# reads past a number. A DRY-RUN states its zero FIRST and then what it found.
if [ "$EXECUTE" -eq 1 ]; then
    ACTION_FIELDS="reaped=$REAP_COUNT"
else
    ACTION_FIELDS="removed=0 would-remove=$WOULD_COUNT"
fi
echo "=== summary ($MODE_LABEL): $ACTION_FIELDS skipped=$SKIP_COUNT errors=$ERROR_COUNT residue=$RESIDUE_COUNT orphan-processes=$ORPHAN_COUNT branches-swept=$BR_SWEPT branches-skipped=$BR_SKIPPED ==="
echo "=== coverage ($MODE_LABEL): repos=$N_REPOS reap-eligible=$N_ELIGIBLE report-only=$N_REPORT_ONLY unreachable=$N_UNREACHABLE worktrees=$N_WORKTREES native=$N_NATIVE shells=$N_SHELLS hand-rolled=$N_HANDROLLED undecidable=$N_UNDECIDABLE unresolved=$SKIP_OWNER_UNRESOLVED indeterminate=$SKIP_OWNER_INDETERMINATE operator=$SKIP_OPERATOR ==="
echo "=== sources:$SRC_SUMMARY ==="
echo "    skip breakdown: quarantined=$SKIP_QUARANTINED locked=$SKIP_LOCKED locked-possibly-live=$SKIP_LOCKED_LIVE unmerged=$SKIP_UNMERGED dirty=$SKIP_DIRTY live-process=$SKIP_LIVE_PROCESS missing-dir=$SKIP_MISSING_DIR no-branch=$SKIP_NO_BRANCH owner-alive=$SKIP_OWNER_ALIVE owner-indeterminate=$SKIP_OWNER_INDETERMINATE owner-unresolved=$SKIP_OWNER_UNRESOLVED operator-worktree=$SKIP_OPERATOR report-only-repo=$SKIP_REPORT_ONLY duplicate-registration=$SKIP_DUPLICATE"
if [ "$N_UNCLASSIFIED_NATIVE" -gt 0 ]; then
    blind "shell labeling: $N_UNCLASSIFIED_NATIVE native worktree(s) have no ownership registration, so this run cannot say whether they are cross-repository SHELLS (a liveness witness nobody writes to) or real workspaces. They are reported as plain 'native', the conservative reading. Absence from the shell list is NOT evidence that a worktree is a workspace"
fi
if [ "${#BLIND[@]}" -gt 0 ]; then
    for _b in "${BLIND[@]}"; do
        echo "=== blind: $_b ==="
    done
else
    echo "=== blind: none declared ==="
fi

# --- THE VERDICT — the one line that is not allowed to read as routine -------
if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "=== verdict: FAIL — errors=$ERROR_COUNT (a removal, unlock or branch deletion failed; see ERROR lines above) ==="
    exit 1
fi
if [ "$SKIP_OWNER_UNRESOLVED" -gt 0 ]; then
    echo "=== verdict: FAIL — unresolved=$SKIP_OWNER_UNRESOLVED hand-rolled worktree(s) have NO ownership record (no ledger registration, no transcript join). This tool can NEVER judge them; they accumulate until an operator clears them under an explicit amnesty. That is a hole in the record, not a routine skip. ==="
    exit 3
fi
# THE VERDICT NAMES EVERY PENDING CONDITION, NOT THE FIRST ONE IT MEETS.
# First-match-wins hid whichever condition happened to sort later, and the one
# that sorted last is the new one: a DRY-RUN that found removable worktrees
# and removed none. The clauses are accumulated in severity order and printed
# together.
PENDING_CLAUSES=()
if [ "$SKIP_OWNER_INDETERMINATE" -gt 0 ]; then
    PENDING_CLAUSES+=("indeterminate=$SKIP_OWNER_INDETERMINATE hand-rolled worktree(s) have a KNOWN owner whose session is still running (or whose identity was not recorded); each names its session pid above and becomes decidable when that session ends")
fi
# A QUARANTINE IS NOT A CLEAN RESULT. It is a worktree the system has already
# decided to destroy and has not finished destroying, and on 2026-09-04 thirty
# of them sat under a line that read `verdict: CLEAN — every candidate was
# decided`. They WERE all decided; the decision was simply not carried out,
# and CLEAN is the one word that stops a reader looking further. This run does
# not own them and cannot say why they are outstanding — the reconciler's
# --status does, and the session banner prints it — so the verdict names the
# count and points at the tool that knows.
if [ "$SKIP_QUARANTINED" -gt 0 ]; then
    PENDING_CLAUSES+=("quarantined=$SKIP_QUARANTINED worktree(s) are claimed by a terminal transaction and not yet removed. This inventory does not own them and never touches them; run 'reconcile-terminal-worktrees.py --status' for WHY (a BLOCKED count there is a condition waiting cannot clear)")
fi
# A DRY-RUN THAT FOUND REMOVABLE WORKTREES AND REMOVED NONE IS NOT CLEAN.
# These passed every gate and no transaction claims them, so the automatic
# mechanism (reconcile-terminal-worktrees.py) will never come for them: they
# sit until an operator acts, which is precisely the pile the CEO opened his
# IDE and found on 2026-09-04. The clause names the one command that removes
# them, because "why is it dry-run" deserves an answer at the point of use.
if [ "$EXECUTE" -eq 0 ] && [ "$WOULD_COUNT" -gt 0 ]; then
    PENDING_CLAUSES+=("would-remove=$WOULD_COUNT worktree(s) passed every gate and NOTHING removed them. This inventory is DRY-RUN by construction — removal belongs to reconcile-terminal-worktrees.py, which only owns worktrees a terminal transaction has CLAIMED, and these are claimed by none, so no automatic mechanism will ever take them. An operator removes them by hand with: $0 ${REPO_ROOT} --discover --execute")
fi
if [ "${#PENDING_CLAUSES[@]}" -gt 0 ]; then
    _joined="${PENDING_CLAUSES[0]}"
    if [ "${#PENDING_CLAUSES[@]}" -gt 1 ]; then
        for _ci in $(seq 1 $(( ${#PENDING_CLAUSES[@]} - 1 ))); do
            _joined="$_joined; ${PENDING_CLAUSES[$_ci]}"
        done
    fi
    echo "=== verdict: PENDING — $_joined ==="
    exit 0
fi
echo "=== verdict: CLEAN — every candidate was decided ==="
exit 0
