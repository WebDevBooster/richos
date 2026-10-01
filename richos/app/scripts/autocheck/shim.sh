#!/bin/sh
# richos-autocheck-shim 1
#
# A repository hook, copied into <git-common-dir>/hooks/<name> by
# richos/app/scripts/autocheck/install.sh for pre-commit, commit-msg, pre-merge-commit, post-commit,
# post-merge and pre-push. Do not edit the installed copy: install.sh rewrites it.
#
# It runs the COMMITTED autocheck.py, read from git's object store, never a working copy:
# the one at HEAD (a branch is checked by its own version), else the one on main (a branch
# older than the check), else the one being merged (the land that introduces it). When none
# of the three has it, the check does not exist in this repository yet and this exits 0.
# Every linked worktree shares this one hooks directory, so one install covers them all.

REL=richos/app/scripts/autocheck/autocheck.py
HOOK=$(basename "$0")
SRC=
# An automatic `git merge` runs pre-merge-commit before it writes MERGE_HEAD and names what it
# merges only in GIT_REFLOG_ACTION ("merge <name>"); a single name is a candidate too.
INCOMING=
case "${GIT_REFLOG_ACTION:-}" in
    "merge "*) INCOMING=$(printf '%s\n' "${GIT_REFLOG_ACTION#merge }" | awk 'NF == 1 { print $1 }') ;;
esac
for rev in HEAD refs/heads/main MERGE_HEAD "${INCOMING:-HEAD}"; do
    if git cat-file -e "$rev:$REL" 2>/dev/null </dev/null; then
        SRC=$rev
        break
    fi
done
[ -n "$SRC" ] || exit 0

case "$HOOK" in
    post-*) REFUSE=0 ;;
    *) REFUSE=1 ;;
esac
TMP=$(mktemp "${TMPDIR:-/tmp}/richos-autocheck.XXXXXX") || {
    echo "autocheck: $HOOK could not make a scratch file; the check did not run" >&2
    exit "$REFUSE"
}
trap 'rm -f "$TMP"' HUP INT TERM
if ! git cat-file -p "$SRC:$REL" > "$TMP" 2>/dev/null </dev/null; then
    rm -f "$TMP"
    echo "autocheck: $HOOK could not read $SRC:$REL; the check did not run" >&2
    exit "$REFUSE"
fi
python3 "$TMP" "$HOOK" "$@"
rc=$?
rm -f "$TMP"
exit "$rc"
