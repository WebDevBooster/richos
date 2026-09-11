#!/usr/bin/env bash
#
# land-completeness.sh — G1. ONE COMMAND, THE FOUR QUESTIONS, AND AN HONEST
#                        COLUMN FOR WHAT IT COULD NOT DECIDE.
#
# ===========================================================================
# WHAT IT ANSWERS
# ===========================================================================
# `docs/plans/land-completeness-2026-09-10.md` §5 requires a reporting surface
# that answers, in one command:
#
#     which lands are incomplete
#     which worktrees are registered without a live owner
#     which branches are merged and unreclaimed
#     AND WHICH OF THOSE IT COULD NOT DECIDE
#
# The fourth is the one that makes the other three worth reading, and it is R5:
# ABSENCE MUST NEVER READ AS SUCCESS. That is the defect that made a dead boot
# suite look healthy for nine days, and let a test suite ask 45 of 67
# registered hooks while saying nothing about the other 22. So this command has
# an UNKNOWN section that is printed even when it is empty, and a NOT EXAMINED
# section that names every repository, ledger or ref list it could not read.
#
#   land-completeness.sh                      every governed repository it finds
#   land-completeness.sh --repo <path>        one, repeatable
#   land-completeness.sh --json               the machine form
#   land-completeness.sh --quiet              print nothing; the exit code is
#                                             the answer (for a hook)
#
# ===========================================================================
# EXIT CODES — THE VERDICT IS IN THE CODE, NOT ONLY IN THE PROSE
# ===========================================================================
#   0   no incomplete land found
#   3   at least one incomplete land: a merged branch whose worktree is still
#       registered and whose owner does not hold a running lock
#   4   nothing could be examined at all — no repository resolved, no ledger.
#       DELIBERATELY NOT 0. A checker that could not look has found nothing and
#       proved nothing, and the two must not share an exit code.
#
# The UNKNOWN count never changes the exit code. This command refuses only on a
# fact it established; unknowns are printed, loudly, and decided by a person.
#
# ===========================================================================
# WHY IT DOES NOT REMOVE ANYTHING
# ===========================================================================
# Because the workspace spec (docs/plans/worktree-spec-2026-09-11.md) allows
# exactly two deleters — land and discard, scripts/workspaces.sh — and this is
# neither. It REPORTS.
#
# Self-test:  scripts/land-completeness.sh --self-test

set -eo pipefail

if [ "${1:-}" = "--self-test" ]; then
    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$_SELF_DIR/land-completeness.test.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/lib/land-completeness.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "land-completeness: python3 is not on PATH — NOTHING WAS EXAMINED." >&2
    exit 4
fi
if [ ! -f "$ANALYZER" ]; then
    echo "land-completeness: the analyzer is missing at $ANALYZER — NOTHING WAS EXAMINED." >&2
    exit 4
fi

REPOS=()
MAIN_BRANCH="${LAND_COMPLETENESS_BRANCH:-main}"
FORMAT="text"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   REPOS+=("${2:-}"); shift 2 ;;
        --branch) MAIN_BRANCH="${2:-main}"; shift 2 ;;
        --json)   FORMAT="json"; shift ;;
        --quiet)  QUIET=1; shift ;;
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "land-completeness: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# WHICH REPOSITORIES, WHEN NOBODY SAID
# ---------------------------------------------------------------------------
# Every repository the ownership ledger has ever registered a worktree in, plus
# the one this command was run from. Read off the durable record rather than
# guessed from a directory scan: the ledger is the thing that knows which
# repositories this orchestration actually works in, and a scan of $HOME would
# invent governance over repositories nobody asked about.
if [ ${#REPOS[@]} -eq 0 ]; then
    HERE_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$HERE_REPO" ] && REPOS+=("$HERE_REPO")
    LEDGER_REPOS="$(python3 - <<'PY' 2>/dev/null || true
import json, os
p = os.environ.get("RICHOS_WORKTREE_LEDGER") or os.path.expanduser(
    "~/.claude/state/worktree-ledger.jsonl")
seen = []
try:
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            r = d.get("repo") or ""
            if r and r not in seen and os.path.isdir(os.path.join(r, ".git")):
                seen.append(r)
except Exception:
    pass
print("\n".join(seen))
PY
)"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        already=0
        for x in "${REPOS[@]}"; do [ "$x" = "$r" ] && already=1; done
        [ "$already" = "0" ] && REPOS+=("$r")
    done <<<"$LEDGER_REPOS"
fi

if [ ${#REPOS[@]} -eq 0 ]; then
    [ "$QUIET" = "1" ] || {
        echo "=== LAND COMPLETENESS: NOTHING WAS EXAMINED ==="
        echo "  No repository was named and none could be resolved — not from this directory and"
        echo "  not from the ownership ledger. This is NOT a clean result: it is the absence of a"
        echo "  check. Name one:   land-completeness.sh --repo <path>"
    } >&2
    exit 4
fi

export RICHOS_LC_ANALYZER="$ANALYZER"

# HELD IN A VARIABLE FOR THE SAME REASON THE RENDERER BELOW IS. Under the bash
# 3.2 macOS ships, `VAR="$( ... <<'PY' ... )"` scans for the closing parenthesis
# BEFORE it processes the here-document, so a single apostrophe anywhere in the
# python body — in a word like "the agent's worktree" — ends the scan in the
# wrong place and the whole file dies with "unexpected EOF while looking for
# matching `''". That is not hypothetical: it happened to this exact block on
# 2026-09-10, one comment after it was written. `read -r -d ''` has no such scan,
# so the form is used for every embedded program in this file rather than for
# the one that has already been bitten.
IFS= read -r -d '' _LC_ANALYZE <<'PY' || true
import importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("land_completeness",
                                              os.environ["RICHOS_LC_ANALYZER"])
lc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lc)

main = sys.argv[1]
out = {"branch": main, "repos": []}
# DEDUPLICATE BY REPOSITORY IDENTITY, NOT BY THE STRING THAT NAMED IT. A linked
# worktree and its main checkout are one repository with one worktree list, so
# reading both counts everything twice — which is what a run from inside an
# agent's worktree did until this line existed.
seen, wanted = set(), []
for repo in sys.argv[2:]:
    key = lc.main_checkout(repo) if os.path.isdir(repo) else repo
    if key in seen:
        continue
    seen.add(key)
    wanted.append(repo)
for repo in wanted:
    try:
        out["repos"].append(lc.analyze(repo, main))
    except Exception as exc:
        out["repos"].append({"repo": repo, "main": main, "worktrees": [], "branches": [],
                             "not_examined": [{"what": repo,
                                               "why": "the analysis raised %s, so this repository "
                                                      "went unexamined" % exc}],
                             "counts": {"worktrees": 0, "branches": 0, "incomplete_lands": 0,
                                        "live": 0, "retained_unmerged": 0, "unknown": 0,
                                        "unreclaimed_branches": 0,
                                        "retained_unmerged_branches": 0, "not_examined": 1}})
print(json.dumps(out))
PY

REPORT="$(python3 -c "$_LC_ANALYZE" "$MAIN_BRANCH" "${REPOS[@]}")" || REPORT=""

if [ -z "$REPORT" ]; then
    [ "$QUIET" = "1" ] || {
        echo "=== LAND COMPLETENESS: NOTHING WAS EXAMINED ==="
        echo "  The analyzer produced no output. Nothing was checked and nothing is proven clean."
    } >&2
    exit 4
fi

if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$REPORT"
fi

# THE RENDERER IS HELD IN A VARIABLE, NOT FED ON STDIN. `python3 - <<'PY'` takes
# the PROGRAM from stdin, so a heredoc and a piped report cannot both be stdin —
# the report never arrives and the renderer dies on an empty read. `read -r -d ''`
# has no such conflict, and it is also the form that parses under the bash 3.2
# macOS ships (a `$( ... <<'PY' ... )` command substitution scans for the closing
# parenthesis before it processes the here-document, so an apostrophe inside the
# python body ends the scan in the wrong place).
IFS= read -r -d '' _LC_RENDER <<'PY' || true
import json, os, sys

doc = json.load(sys.stdin)
quiet = os.environ.get("RICHOS_LC_QUIET") == "1"
as_json = os.environ.get("RICHOS_LC_FORMAT") == "json"
w = sys.stderr.write

incomplete = []
unknown = []
notex = []
tot = {"worktrees": 0, "branches": 0, "live": 0, "retained_unmerged": 0, "quarantined": 0,
       "unreclaimed_branches": 0, "retained_unmerged_branches": 0}

for rep in doc["repos"]:
    c = rep.get("counts", {})
    for k in tot:
        tot[k] += c.get(k, 0)
    for wt in rep.get("worktrees", []):
        if wt["disposition"] == "incomplete-land":
            incomplete.append((rep["repo"], wt))
        elif wt["disposition"] in ("unowned", "unknown-merge", "missing-on-disk"):
            unknown.append((rep["repo"], wt["path"], wt["branch"], wt["disposition"], wt["reason"]))
    for br in rep.get("branches", []):
        if br["disposition"] == "unknown-merge":
            unknown.append((rep["repo"], "(no worktree)", br["branch"], br["disposition"],
                            br["reason"]))
    for ne in rep.get("not_examined", []):
        notex.append((rep["repo"], ne["what"], ne["why"]))

if not quiet and not as_json:
    w("=== LAND COMPLETENESS ===\n")
    w("    branch: %s    repositories: %d\n\n" % (doc["branch"], len(doc["repos"])))

    # 1. WHICH LANDS ARE INCOMPLETE
    if incomplete:
        w("  INCOMPLETE LANDS — a merged branch whose worktree is still registered (%d)\n"
          % len(incomplete))
        for repo, wt in incomplete:
            w("    %s\n" % wt["path"])
            w("        branch %s, merged into %s; owner %s\n"
              % (wt["branch"], doc["branch"], wt["owner"]))
            w("        %s\n" % wt["owner_reason"])
        w("\n")
    else:
        w("  INCOMPLETE LANDS ................................. none\n\n")

    # 2/3. THE REST OF THE REGISTERED SET, EVERY ONE WITH ITS REASON
    w("  RETAINED, WITH A REASON — never residue, never swept\n")
    w("    live (owner holds a running lock) .............. %d\n" % tot["live"])
    w("    unmerged worktrees (R3: never swept) ........... %d\n" % tot["retained_unmerged"])
    w("    unmerged branches without a worktree ........... %d\n"
      % tot["retained_unmerged_branches"])
    w("    quarantined (retired, registered by design) .... %d\n" % tot["quarantined"])
    w("\n")

    # R4: a branch and a worktree are different objects and the counts are separate.
    w("  COUNTED SEPARATELY, BECAUSE THEY ARE DIFFERENT OBJECTS\n")
    w("    worktrees registered ........................... %d\n" % tot["worktrees"])
    w("    branches with no worktree ...................... %d\n" % tot["branches"])
    w("    of those, merged and unreclaimed (benign) ...... %d\n" % tot["unreclaimed_branches"])
    w("\n")

    # 4. WHAT IT COULD NOT DECIDE — PRINTED EVEN WHEN EMPTY.
    w("  COULD NOT DECIDE (%d) — reported, never rounded to clean, never blocked on\n"
      % len(unknown))
    for repo, path, branch, disp, reason in unknown:
        w("    %-16s %s\n" % (disp, path))
        w("        branch %s — %s\n" % (branch or "(none)", reason))
    if not unknown:
        w("    (nothing undecided)\n")
    w("\n")

    w("  NOT EXAMINED (%d) — the absence of a finding is not a finding\n" % len(notex))
    for repo, what, why in notex:
        w("    %s\n        %s\n" % (what, why))
    if not notex:
        w("    (everything named above was read)\n")
    w("\n")

    if incomplete:
        w("  WHAT TO DO. Each line above is one land that pushed and stopped. The terminal steps\n")
        w("  of the land sequence are collect, remove, resolve:\n\n")
        w("      engine/scripts/collect-worktree-artifacts.sh <worktree>\n")
        w("      engine/scripts/workspaces.sh land <agent>   (or: discard <agent> --reason '...')\n")
        w("      (workspaces.sh status names the agent; land and discard are the only deleters)\n\n")
        w("  If one of them is retained ON PURPOSE, that is a first-class answer and the only\n")
        w("  thing wrong with it is leaving it unsaid — retained silently is the defect this\n")
        w("  report exists to remove.\n")

print(3 if incomplete else 0)
PY

RC="$(printf '%s' "$REPORT" | RICHOS_LC_QUIET="$QUIET" RICHOS_LC_FORMAT="$FORMAT" \
      python3 -c "$_LC_RENDER")" || RC=4

exit "${RC:-4}"
