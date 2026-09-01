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
# worktrees, while the project's own doctrine REQUIRES hand-rolled worktrees
# for cross-repository work — which is most of the work. It covered the rare
# case and missed the standard one.
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
# C. IT RUNS WHEN AN AGENT FINISHES, not only at session start.
#    scripts/hooks/agent-finished-reap-worktrees.sh is wired to TeammateIdle
#    and TaskCompleted. That timing is not a convenience — it is when the
#    evidence still EXISTS. See the liveness rule.
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
# reaped only when a positive termination signal for its OWNER exists:
#
#   owner name   the worktree's branch name, else its directory name. The
#                convention this project actually uses is that a hand-rolled
#                worktree is named for the teammate that owns it.
#   owner id     resolved from the session transcript by the ONE liveness
#                resolver (scripts/lib/agent-liveness.py), which is the only
#                place the name -> agentId join exists on disk.
#   verdict      that same resolver's verdict, taken from the owner's NATIVE
#                isolation worktree lock in the entity repository.
#
#   ALIVE .................................. SKIP owner-alive
#   INDETERMINATE .......................... SKIP owner-indeterminate
#   name does not resolve to any agent ..... SKIP owner-unresolved
#   NOT-ALIVE, native worktree ABSENT ...... SKIP owner-unresolved
#   NOT-ALIVE, native worktree OBSERVED .... positive signal; continue to the
#                                            remaining gates
#
# READ THE FOURTH LINE AGAIN. An absent native worktree is an ABSENCE, and
# absence is the exact inference doctrine forbids. It is deliberately NOT
# treated as a termination signal even though the resolver's verdict for it is
# NOT-ALIVE. That is the difference between "I watched it stop" and "it is not
# where I looked".
#
# And that is why C above matters: at the moment a teammate finishes, its
# native worktree is still registered and now unlocked — the signal is
# OBSERVABLE. An hour later the native tree has been reaped and the same
# hand-rolled tree is permanently undecidable. Sweeping at agent-finish is
# what makes the evidence available at all.
#
# INDETERMINATE IS A REAL ANSWER AND IS NEVER GUESSED INTO EITHER OTHER ONE.
# A class that cannot be judged safely is REPORTED, not reaped, and it is
# counted in the summary as `undecidable=N` so the number is visible rather
# than absent.
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
#   === summary (MODE): reaped=N skipped=N errors=N residue=N
#       orphan-processes=N ===
#   === coverage (MODE): repos=N reap-eligible=N report-only=N unreachable=N
#       worktrees=N native=N hand-rolled=N undecidable=N ===
#   === sources: <label>=<count> ... ===
#   === blind: <what this run could NOT see>  (or: none declared) ===
#
# A number that is not known is printed as not known. `blind:` is where a
# future version of this defect has to declare itself.
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
#     --transcript <p>   A session transcript, for the name -> agentId join.
#                        Auto-detected from ~/.claude/projects/<slug>/ when
#                        absent; its absence is DECLARED in `blind:`.
#
#   Environment (test affordances; never set in a real session):
#     REAP_DISCOVERY_SOURCES   comma list restricting the sources above
#     REAP_TEAM_DIR            stands in for ~/.claude/teams
#     REAP_LEDGER              stands in for the known-repositories ledger
#     REAP_ENGINE_ROOT         stands in for the engine checkout
#     REAP_PROJECTS_DIR        stands in for ~/.claude/projects
#     REAP_NEIGHBORHOOD_MAX    max entries in a parent dir before the
#                              neighborhood scan declares itself blind (200)
#
# Before each real removal, scripts/collect-worktree-artifacts.sh is run
# against the tree if the swept repository has one — mirrors land-time
# practice. Never run in DRY-RUN (it writes artifact dirs).
#
# Wired by scripts/hooks/session-start-reap-worktrees.sh (SessionStart) and
# scripts/hooks/agent-finished-reap-worktrees.sh (TeammateIdle, TaskCompleted),
# and covered by the integrity probe's Layer Q.
#
# Exit codes:
#   0  clean run (a SKIP is not an error)
#   1  unexpected error (missing/invalid repo, a removal failed, etc.)

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
  --transcript <p>   Session transcript for the teammate-name -> agentId join.
  -h, --help         Show this help.
EOF
}

EXECUTE=0
UNLOCK_STALE=0
DISCOVER=0
REPO_ROOT_ARG=""
ENTITY_ARG=""
TRANSCRIPT_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --execute)      EXECUTE=1; shift ;;
    --unlock-stale) UNLOCK_STALE=1; shift ;;
    --discover)     DISCOVER=1; shift ;;
    --no-discover)  DISCOVER=0; shift ;;
    --entity)       ENTITY_ARG="${2:-}"; shift 2 ;;
    --transcript)   TRANSCRIPT_ARG="${2:-}"; shift 2 ;;
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
# OWNER LIVENESS — one table, built once, from the ONE resolver
# ===========================================================================
# The table is
#     <teammate-name>  <verdict>  <native worktree OBSERVED?>
# and it is built by IMPORTING scripts/lib/agent-liveness.py and calling its
# two entry points — `names_to_ids` (the name -> agentId join, which exists
# nowhere else on disk) and `enumerate_all` (the authoritative verdict for
# every native isolation worktree REGISTERED in the entity).
#
# THE THIRD COLUMN IS THE WHOLE SAFETY RULE AND IT IS WHY THIS IMPORTS THE
# MODULE RATHER THAN SHELLING ITS `--all` CLI. Written the CLI way first, and
# a mutation test caught it: `--all` only ever describes worktrees that EXIST,
# so `registered` was true in every row it could ever emit, the third column
# was a constant, and the branch reading it was unreachable. Deleting the
# check changed nothing and every test stayed green — a guard that had already
# rotted on the day it was written.
#
# Joining the two calls makes the distinction real, because it produces a row
# for a name whose agent has NO registered worktree:
#
#   name maps to an agent with a worktree ...... its verdict, OBSERVED=1
#   name maps to an agent with NO worktree ..... NOT-ALIVE, OBSERVED=0
#                                                (an ABSENCE, not a death)
#   name maps to no agent at all ............... no row: UNRESOLVED
#
# There is deliberately no second implementation of "alive" here. Two of them
# is how one of them silently becomes the stale one, which is the sentence
# scripts/lib/agent-liveness.py was extracted to stop having to write again —
# so this borrows its functions rather than paraphrasing its logic.
OWNER_TABLE=""
LIVENESS_PY="$LIB_DIR/agent-liveness.py"
TRANSCRIPT="$TRANSCRIPT_ARG"

if [ -z "$TRANSCRIPT" ]; then
    _slug="$(printf '%s' "$ENTITY_ROOT" | sed 's|/|-|g')"
    _projdir="${REAP_PROJECTS_DIR:-$HOME/.claude/projects}/$_slug"
    if [ -d "$_projdir" ]; then
        TRANSCRIPT="$(ls -1t "$_projdir"/*.jsonl 2>/dev/null | head -1 || true)"
    fi
fi

if [ ! -f "$LIVENESS_PY" ]; then
    blind "owner liveness: the resolver is missing at $LIVENESS_PY — EVERY hand-rolled worktree is undecidable in this run and none can be reaped"
elif ! command -v python3 >/dev/null 2>&1; then
    blind "owner liveness: python3 is not on PATH — EVERY hand-rolled worktree is undecidable in this run"
elif [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    blind "owner liveness: no session transcript found for entity '$ENTITY_ROOT' — the teammate-name -> agentId join is unavailable, so EVERY hand-rolled worktree is undecidable in this run"
else
    OWNER_TABLE="$(REAP_LIVENESS_PY="$LIVENESS_PY" \
                   REAP_ENTITY="$ENTITY_ROOT" \
                   REAP_TRANSCRIPT_PATH="$TRANSCRIPT" \
                   python3 - <<'PY' 2>/dev/null || true
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location(
    "richos_agent_liveness", os.environ["REAP_LIVENESS_PY"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

names = mod.names_to_ids(os.environ["REAP_TRANSCRIPT_PATH"])
if not names:
    sys.exit(0)

by_id = {}
for rec in mod.enumerate_all(os.environ["REAP_ENTITY"]):
    aid = rec.get("agent_id")
    if aid:
        by_id[aid] = rec

for name in sorted(names):
    rec = by_id.get(names[name])
    if rec is None:
        # The name resolves to a real agent whose isolation worktree is not
        # registered in the entity at all. The resolver would call that
        # NOT-ALIVE; this row records that the verdict rests on an ABSENCE,
        # and the caller refuses it for exactly that reason.
        print("%s\tNOT-ALIVE\t0" % name)
        continue
    observed = "1" if (rec.get("evidence") or {}).get("registered") else "0"
    print("%s\t%s\t%s" % (name, rec.get("verdict") or "INDETERMINATE", observed))
PY
                   )"
    if [ -z "$OWNER_TABLE" ]; then
        blind "owner liveness: the resolver produced no name->verdict rows for entity '$ENTITY_ROOT' (transcript: $TRANSCRIPT) — every hand-rolled worktree is undecidable in this run"
    fi
fi

owner_row() { # <name> -> "<verdict><TAB><observed>" or empty
    [ -n "$OWNER_TABLE" ] || return 0
    printf '%s\n' "$OWNER_TABLE" | awk -F'\t' -v n="$1" '$1==n {print $2"\t"$3; exit}'
}

# --- Teammate names this machine has a record of spawning -------------------
# Used ONLY to decide whether a neighborhood-discovered repository is
# reap-eligible or report-only. It is evidence that a session touched that
# repository; it is never evidence that anyone is dead.
SPAWNED_NAMES=""
if [ -d "$TEAM_DIR_BASE" ]; then
    for _f in "$TEAM_DIR_BASE"/*/spawned-names.log; do
        [ -f "$_f" ] || continue
        SPAWNED_NAMES="$SPAWNED_NAMES
$(cat "$_f" 2>/dev/null || true)"
    done
fi
is_spawned_name() { # <name>
    [ -n "${1:-}" ] || return 1
    [ -n "$SPAWNED_NAMES" ] || return 1
    printf '%s\n' "$SPAWNED_NAMES" | grep -qx -- "$1"
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
    if is_spawned_name "$_cur_branch" || is_spawned_name "$(basename "$_cur_path")"; then
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

# ===========================================================================
# THE SWEEP
# ===========================================================================
echo "=== reap-stale-worktrees: $MODE_LABEL — primary: $REPO_ROOT — entity: $ENTITY_ROOT ==="
if [ "$EXECUTE" -eq 0 ]; then
    echo "=== DRY-RUN: no worktree/branch will be removed, no lock broken, no prune run. Pass --execute to perform. ==="
fi

REAP_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0
SKIP_LOCKED=0
SKIP_LOCKED_LIVE=0
SKIP_UNMERGED=0
SKIP_DIRTY=0
SKIP_LIVE_PROCESS=0
SKIP_MISSING_DIR=0
SKIP_NO_BRANCH=0
SKIP_OWNER_ALIVE=0
SKIP_OWNER_UNDECIDABLE=0
SKIP_REPORT_ONLY=0
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

        if [ "$class" = "native" ]; then
            N_NATIVE=$((N_NATIVE + 1))
        else
            N_HANDROLLED=$((N_HANDROLLED + 1))
        fi

        # --- Gate 0: repository reap-eligibility ---
        if ! repo_eligible_at "$repo"; then
            skip "$id" "report-only-repo($class) — '$repo' is known only from the neighborhood scan and holds no worktree owned by a teammate this machine recorded spawning; inventoried, never mutated"
            SKIP_REPORT_ONLY=$((SKIP_REPORT_ONLY + 1))
            continue
        fi

        # Directory gone but still registered -> report + let `worktree prune`
        # (execute-only, end of run) clear the registration. No further gate.
        if [ ! -d "$path" ]; then
            skip "$id" "missing-dir($class)"
            SKIP_MISSING_DIR=$((SKIP_MISSING_DIR + 1))
            continue
        fi

        # --- Gate 1: lock ---
        if [ "$locked" -eq 1 ]; then
            if [ "$UNLOCK_STALE" -eq 0 ]; then
                skip "$id" "locked($class)"
                SKIP_LOCKED=$((SKIP_LOCKED + 1))
                continue
            fi

            admin_dir="$(git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
            lock_file="$admin_dir/locked"
            if [ -z "$admin_dir" ] || [ ! -f "$lock_file" ]; then
                skip "$id" "locked-possibly-live($class)"
                SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
                continue
            fi

            lock_mtime="$(mtime_of "$lock_file" || true)"
            now="$(date +%s)"
            pids="$(live_pids_for "$path")"

            if [ -z "$lock_mtime" ]; then
                skip "$id" "locked-possibly-live($class)"
                SKIP_LOCKED_LIVE=$((SKIP_LOCKED_LIVE + 1))
                continue
            fi
            age=$((now - lock_mtime))

            if [ -n "$pids" ] || [ "$age" -lt 7200 ]; then
                skip "$id" "locked-possibly-live($class)"
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
            else
                echo "  (DRY-RUN: would unlock stale lock on $id — age ${age}s, no live process — then re-evaluate)"
            fi
        fi

        # --- Gate 2: owner termination signal (hand-rolled only) ---
        # A hand-rolled worktree takes NO lock, so gate 1 proved nothing about
        # it. See the header: an ABSENT native worktree is an absence, and
        # absence is not death.
        if [ "$class" = "hand-rolled" ]; then
            owner="$branch_name"
            [ -n "$owner" ] || owner="$id"
            row="$(owner_row "$owner")"
            [ -n "$row" ] || row="$(owner_row "$id")"
            if [ -z "$row" ]; then
                skip "$id" "owner-unresolved(no agent matches '$owner' — a hand-rolled worktree takes no lock, so quiet is not death)"
                SKIP_OWNER_UNDECIDABLE=$((SKIP_OWNER_UNDECIDABLE + 1))
                continue
            fi
            verdict="$(printf '%s' "$row" | cut -f1)"
            observed="$(printf '%s' "$row" | cut -f2)"
            case "$verdict" in
            ALIVE)
                skip "$id" "owner-alive($owner — its isolation worktree is LOCKED by a running pid)"
                SKIP_OWNER_ALIVE=$((SKIP_OWNER_ALIVE + 1))
                continue
                ;;
            NOT-ALIVE)
                if [ "$observed" != "1" ]; then
                    skip "$id" "owner-unresolved($owner — verdict NOT-ALIVE only because its isolation worktree is ABSENT; absence is not a termination signal)"
                    SKIP_OWNER_UNDECIDABLE=$((SKIP_OWNER_UNDECIDABLE + 1))
                    continue
                fi
                ;;
            *)
                skip "$id" "owner-indeterminate($owner — liveness could not be resolved; INDETERMINATE is never guessed into dead)"
                SKIP_OWNER_UNDECIDABLE=$((SKIP_OWNER_UNDECIDABLE + 1))
                continue
                ;;
            esac
        fi

        # --- Gate 3: merged ---
        if [ -z "$branch_name" ]; then
            skip "$id" "no-branch($class — detached HEAD; nothing to verify against, and unverifiable is not permission)"
            SKIP_NO_BRANCH=$((SKIP_NO_BRANCH + 1))
            continue
        fi
        if ! git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch_name" >/dev/null; then
            skip "$id" "no-branch($class)"
            SKIP_NO_BRANCH=$((SKIP_NO_BRANCH + 1))
            continue
        fi
        target_ref="$(git -C "$repo" symbolic-ref -q --short HEAD || true)"
        [ -n "$target_ref" ] || target_ref="$(git -C "$repo" rev-parse HEAD)"
        if ! git -C "$repo" merge-base --is-ancestor "refs/heads/$branch_name" "$target_ref" 2>/dev/null; then
            n="$(git -C "$repo" rev-list --count "$target_ref..refs/heads/$branch_name" 2>/dev/null || echo '?')"
            skip "$id" "unmerged(+$n)"
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
            if git -C "$repo" worktree remove "$path"; then
                if git -C "$repo" branch -d "$branch_name" >/dev/null 2>&1; then
                    echo "REAP $id"
                    REAP_COUNT=$((REAP_COUNT + 1))
                else
                    echo "ERROR: removed worktree $id but the branch deletion of $branch_name refused (unmerged commits protecting it?) — investigate manually" >&2
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                fi
            else
                echo "ERROR: worktree removal failed for $id" >&2
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        else
            echo "DRY-RUN REAP $id"
            REAP_COUNT=$((REAP_COUNT + 1))
        fi
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
N_UNDECIDABLE=$((SKIP_OWNER_UNDECIDABLE + SKIP_REPORT_ONLY))

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

echo "=== summary ($MODE_LABEL): reaped=$REAP_COUNT skipped=$SKIP_COUNT errors=$ERROR_COUNT residue=$RESIDUE_COUNT orphan-processes=$ORPHAN_COUNT ==="
echo "=== coverage ($MODE_LABEL): repos=$N_REPOS reap-eligible=$N_ELIGIBLE report-only=$N_REPORT_ONLY unreachable=$N_UNREACHABLE worktrees=$N_WORKTREES native=$N_NATIVE hand-rolled=$N_HANDROLLED undecidable=$N_UNDECIDABLE ==="
echo "=== sources:$SRC_SUMMARY ==="
echo "    skip breakdown: locked=$SKIP_LOCKED locked-possibly-live=$SKIP_LOCKED_LIVE unmerged=$SKIP_UNMERGED dirty=$SKIP_DIRTY live-process=$SKIP_LIVE_PROCESS missing-dir=$SKIP_MISSING_DIR no-branch=$SKIP_NO_BRANCH owner-alive=$SKIP_OWNER_ALIVE owner-undecidable=$SKIP_OWNER_UNDECIDABLE report-only-repo=$SKIP_REPORT_ONLY"
if [ "${#BLIND[@]}" -gt 0 ]; then
    for _b in "${BLIND[@]}"; do
        echo "=== blind: $_b ==="
    done
else
    echo "=== blind: none declared ==="
fi

if [ "$ERROR_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
