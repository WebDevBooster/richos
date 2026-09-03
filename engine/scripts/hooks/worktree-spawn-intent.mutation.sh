#!/usr/bin/env bash
#
# worktree-spawn-intent.mutation.sh — PROVES clause 7 of
# guard-worktree-isolation.sh (the spawn-intent) CAN FAIL, one property at a
# time. Invoked by guard-worktree-isolation.test.sh; the loop is
# scripts/lib/mutation-harness.sh. Case ids (Q01 etc.) are the ones that suite
# prints on both its PASS and FAIL lines.
#
# NOT COVERED, stated: Q15 (no tool_use_id -> refused) is carried by two
# checks in two files — the guard's own, and worktree-transactions.py's
# refusal of an empty path segment (its T02). Removing the guard's alone does
# not turn Q15 red, and a single mutant edits one file.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "guard-worktree-isolation clause 7 (spawn-intent)" "scripts/hooks/guard-worktree-isolation.test.sh"

G="scripts/hooks/guard-worktree-isolation.sh"

mutant intent-not-written "Q01" "$G" \
    '    tx.write_intent(sid, tuid, {"kind": kind, "teammate": name,' \
    '    pass and tx.write_intent(sid, tuid, {"kind": kind, "teammate": name,' \
    "every spawn would be allowed with no intent on disk; the binder would find nothing to bind and every worker would be refused at its first write."

mutant externals-dropped "Q02" "$G" \
    '    externals.append({"repo": repo_now, "path": real, "branch": branch_now,' \
    '    [].append({"repo": repo_now, "path": real, "branch": branch_now,' \
    "a cwd spawn's external member would be missing from the intent; the tree the worker writes in would never be bound or cleaned up."

mutant prepared-not-required "Q04" "$G" \
    '    if not prepared:{NL}        others = wl.prepared_records(records, worktree=real)' \
    '    if not prepared:{NL}        prepared = [{"repo": tx.main_checkout_of(real), "branch": tx.branch_of(real), "ts": ""}]{NL}    if False:{NL}        others = wl.prepared_records(records, worktree=real)' \
    "any registered tree could be spawned into by any teammate in any session — the cross-session binding the specification forbids."

mutant branch-drift-ignored "Q08" "$G" \
    '    if (rec.get("branch") or "") != branch_now:{NL}        problem(' \
    '    if False:{NL}        problem(' \
    "a tree that drifted off its prepared branch would be sealed against a record describing a different line of work."

mutant sync-spawn-allowed "Q11" "$G" \
    'if [ "$RUN_IN_BG" = "false" ]; then' \
    'if false; then' \
    "a synchronous file-writing Agent call would run and finish before its PostToolUse could bind anything it wrote."

mutant lifecycle-check-removed "Q18" "$G" \
    '  [ -f "$SCRIPT_DIR/../../$_c" ] || C7_PROBLEMS+=(' \
    '  true || C7_PROBLEMS+=(' \
    "a spawn would be allowed into an engine that cannot bind or seal it; the intent would be a record nothing could act on."

mutant refusal-does-not-refuse "Q04" "$G" \
    '    echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"{NL}  } >&2{NL}  exit 2{NL}fi{NL}{NL}exit 0' \
    '    echo "(hook: scripts/hooks/guard-worktree-isolation.sh)"{NL}  } >&2{NL}  exit 0{NL}fi{NL}{NL}exit 0' \
    "clause 7 would print every problem and let the spawn through — a warning wearing a guard's clothes."

mutation_end
