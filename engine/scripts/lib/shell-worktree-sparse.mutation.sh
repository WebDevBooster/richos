#!/usr/bin/env bash
#
# shell-worktree-sparse.mutation.sh — PROVES shell-worktree-sparse.test.sh CAN
# FAIL, one property at a time. Invoked by that suite; see
# scripts/lib/mutation-harness.sh for the loop. Case ids (S04 etc.) are the
# ones the suite prints on both its PASS and FAIL lines.
#
# The property under test in every one of these is the same sentence from the
# CEO's ruling: make the marker cheap, and change NOTHING about what keeps
# work safe. Each mutant removes one of the things that keep it safe.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "shell-worktree-sparse (the never-read native shell)" "scripts/lib/shell-worktree-sparse.test.sh"

F="scripts/lib/shell-worktree-sparse.py"

mutant dirty-shell-sparsified "S04" "$F" \
    '    if out.strip():{NL}        n = len(out.strip().splitlines())' \
    '    if False:{NL}        n = len(out.strip().splitlines())' \
    "a shell somebody had written into would be rewritten under them — sparse would become the data-loss path the design exists to avoid."

mutant kind-unchecked "S02" "$F" \
    '    if tx.get("kind") != "native+external":{NL}        return None, None,' \
    '    if False:{NL}        return None, None,' \
    "a plain native worker's WORKSPACE would be de-materialized — the one worktree that is not a shell."

# TWO CHECKS CARRY THIS ONE, so removing either alone is (correctly) not
# observable: a transaction that is terminal on arrival ALSO has a native
# member the terminalization already advanced past `bound`. Both go, or the
# mutant proves nothing — which is what `{AND}` is for.
mutant terminal-unchecked "S17" "$F" \
    '    if tx.get("terminal"):{NL}        return None, None, "already terminal"{AND}        if m.get("state") != "bound":{NL}            return None, None, "native member state is' \
    '    if False:{NL}        return None, None, "already terminal"{AND}        if False:{NL}            return None, None, "native member state is' \
    "a working-tree rewrite would race the quarantine and capture the lifecycle has already started."

mutant registration-unchecked "S09" "$F" \
    '    ok, why = is_registered_linked_worktree(repo, path){NL}    if not ok:{NL}        return _refused(why)' \
    '    ok, why = is_registered_linked_worktree(repo, path){NL}    if False:{NL}        return _refused(why)' \
    "any directory could be sparsified, including a MAIN CHECKOUT — the shared tree every other worktree is cut from."

mutant git-failure-reported-as-success "S10" "$F" \
    '    rc, out, set_err = git(path, "sparse-checkout", "set", "--cone", *keep_set){NL}    if rc != 0:' \
    '    rc, out, set_err = git(path, "sparse-checkout", "set", "--cone", *keep_set){NL}    if False:' \
    "a git command that failed would be reported as an applied sparsification, and the tree left however git left it."

mutant already-sparse-unchecked "S08" "$F" \
    '    if is_sparse(path):{NL}        return _refused("already sparse")' \
    '    if False:{NL}        return _refused("already sparse")' \
    "the operation would re-run on every seal attempt instead of being the recorded one-shot it claims to be."

mutant hooks-stranded "S14" "$F" \
    '    full = hp if os.path.isabs(hp) else os.path.join(path, hp)' \
    '    return []{NL}    full = hp if os.path.isabs(hp) else os.path.join(path, hp)' \
    "a repository whose core.hooksPath points inside the worktree would lose its commit-time guards in the shell."

mutant worktree-config-hazard-ignored "S15" "$F" \
    '    haz = worktree_config_hazard(path, repo){NL}    if haz:' \
    '    haz = worktree_config_hazard(path, repo){NL}    if False:' \
    "enabling extensions.worktreeConfig would silently change how the MAIN checkout reads core.bare / core.worktree."

mutant submodule-ignored "S16" "$F" \
    '    sub = initialized_submodule(path){NL}    if sub:' \
    '    sub = initialized_submodule(path){NL}    if False:' \
    "a submodule working tree — not reconstructible from this repository's object store — would be removed as though it were."

mutant policy-switch-ignored "S13" "$F" \
    '    if not enabled:{NL}        return _refused("SHELL_SPARSE is off")' \
    '    if False:{NL}        return _refused("SHELL_SPARSE is off")' \
    "the committed policy would be decoration: turning it off would change nothing, so nobody could turn it off."

mutant refusals-not-counted "S18" "scripts/lib/worktree-transactions.py" \
    '            else:{NL}                out["shells_sparse_refused"] += 1' \
    '            elif False:{NL}                out["shells_sparse_refused"] += 1' \
    "the status line would count only the shells that shrank, reporting a policy that sometimes declines as one that always applies."

mutation_end
