#!/usr/bin/env bash
#
# release-land-leases.sh: Stop hook. A land lease ends at its holder's turn end
# once the land is at rest (spec r3 e6, F3; Frank G5 point 3).
#
# For every land lease THIS session holds (its holder, pid and start time, is an
# ancestor of this hook):
#   * at rest (no merge, cherry-pick, revert or rebase in progress, no unmerged
#     path, `git status --porcelain --untracked-files=no` empty, and main not
#     ahead of its upstream) -> released, silently;
#   * otherwise -> kept, and one systemMessage names the repository, the holder's
#     conversation, the age and what is unfinished, including which paths are
#     dirty, so a lease held up by ANOTHER writer's dirt can be told from the
#     holder's own unfinished work.
# A lease this session does not hold is never touched. It never blocks.
#
# WITH THE SWITCH OFF no lease exists (land-lease.sh takes none) and a repository
# whose launcher is off is skipped, so this hook prints nothing.

cat >/dev/null 2>&1 || true
_rll_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_rll_py="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
"$_rll_py" "$_rll_dir/../lib/operator_fences.py" turn-end 2>/dev/null || true
exit 0
