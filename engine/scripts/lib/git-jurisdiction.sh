#!/usr/bin/env bash
#
# scripts/lib/git-jurisdiction.sh — WHICH REPOSITORY IS THIS `git` COMMAND
#                                   ACTUALLY TALKING TO?
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# Five PreToolUse[Bash] guards in this engine judge a `git commit` / `git push`
# against a repository. Every one of them resolved that repository the same way,
# in five hand-copied blocks:
#
#     an explicit `git -C <path>`, otherwise the hook payload's cwd.
#
# guard-completeness-commits.sh even says so in a comment at its line 333:
# "An explicit -C names the repository; otherwise the session cwd does."
#
# THAT SENTENCE HAS A HOLE IN IT THE SIZE OF A SHELL BUILTIN. A worktree-
# isolated agent's session cwd is the checkout the HARNESS gave it, while the
# work is in a hand-rolled worktree somewhere else. The natural way to type a
# commit from there is:
#
#     cd /Users/alex/ab/richos-wt/<branch> && git commit -m "..."
#
# and there is no `-C`, so all five guards resolve the SESSION's repository —
# the wrong one — find no adoption declaration there, and stand down. The
# commit sails through the chokepoint that exists to stop it.
#
# MEASURED, NOT INFERRED (2026-09-01, zach-opus-n1): the identical commit was
# REFUSED through the `-C` form and ACCEPTED through the `cd` form minutes
# apart. He reset it and redid the work honestly. It is not an exploit — it is
# the ordinary way an agent in a hand-rolled worktree types a commit, so it is
# being hit BY ACCIDENT, repeatedly, by people trying to do the right thing.
#
# ===========================================================================
# WHY ONE RESOLVER AND NOT FIVE PATCHES
# ===========================================================================
# The hole was in five files because the resolution was in five files. Patching
# the guard that was caught would have left four with the same defect and no
# reason to believe the fifth was the last one — and a second guard with the
# same hole is precisely the outcome the row asked to avoid. So resolution
# moves HERE, once, and every guard asks the same question of the same code.
# scripts/lib/seat-jurisdiction.sh already owns "does this artifact belong to
# the repository I govern?"; this owns the question underneath it, "which
# repository is the artifact in?", for the one input shape a hook is handed
# most: a Bash command line.
#
# ===========================================================================
# THE INVARIANT THAT MAKES THIS SAFE TO LAND — read this before changing it
# ===========================================================================
#
#   FOR A COMMAND WITH ONE `git` INVOCATION AND NO `cd` — which is nearly every
#   command anyone types — THIS RESOLVER RETURNS EXACTLY WHAT THE FIVE
#   HAND-COPIED BLOCKS RETURNED: the `git … -C <path>`, else the payload cwd.
#
# It is not a comment, it is a case: git-jurisdiction.test.sh case (b) holds a
# corpus of those shapes and asserts new == legacy for every one.
#
# THE DIFFERENCE IS EXACTLY TWO SENTENCES WIDE, and both are stated here rather
# than discovered later:
#
#   1. A command that `cd`s into a repository is judged against THAT
#      repository. This is the row's whole point.
#
#   2. When one command carries SEVERAL git invocations, the anchor is the
#      repository of the invocation the guard is judging, not the first `-C` on
#      the line. `git -C /other add -A && git -C /here commit` anchors on
#      /here. This is not a new opinion: guard-publication-commits.sh had
#      already made that correction locally, its own suite pins it as a control
#      case ("a git add in ANOTHER repository does not widen this scan"), and
#      the four other guards were the ones out of step.
#
# Whether a guard then ENFORCES anything is still decided where it always was —
# by the target repository's own adoption declaration. A guard that suddenly
# fires on repositories it never covered is how a defense gets waived, so the
# widening here is bounded to one shape and named twice.
#
# ===========================================================================
# WHAT IT UNDERSTANDS
# ===========================================================================
#   cd <dir>            absolute, relative, `~`, `-` (the previous directory)
#   pushd <dir>         same as cd for our purposes
#   ( … )               a subshell's cd does not leak past its close paren
#   git -C <p>          named repository, resolved against the running cwd,
#                       and cumulative when repeated, as git itself defines it
#   --git-dir=<p> / --work-tree=<p>
#                       the other two ways a git invocation names a repository
#                       explicitly. Included deliberately: they are the same
#                       hole wearing a different flag, and leaving a known
#                       identical hole open after being told to close the class
#                       would be the failure this file was written about.
#   segments            ; && || | newline — the anchor is the state at the git
#                       invocation, not at the end of the line
#
# ===========================================================================
# WHAT IT CANNOT KNOW, SAID HERE RATHER THAN IN A POSTMORTEM
# ===========================================================================
#   cd "$D" && git commit          the target is a shell variable this process
#                                  never expanded and cannot. Reported as
#                                  `unresolved-cd`; the anchor falls back to the
#                                  payload cwd, i.e. to TODAY'S answer. It is
#                                  not made worse, and it is not pretended to be
#                                  solved.
#   popd                           the directory stack is not tracked; after a
#                                  popd the cwd is unknown, same fallback.
#   an unbalanced quote            shlex cannot tokenize it; the legacy answer
#                                  is returned and reported as `unparsed`.
#
# The honest summary: this closes the shape that is being hit by accident and
# names the shapes it does not close, so the next reader does not have to
# discover them the way this one was discovered.
#
# ===========================================================================
# INTERFACE
# ===========================================================================
#   richos_git_anchor <payload-json> [verbs]
#
#       verbs — optional, space-separated git subcommands the caller cares
#               about ("commit push"). The anchor is taken from the FIRST
#               matching invocation, so `git add -A && git commit` anchors on
#               the commit rather than on the add. With no verbs, the first git
#               invocation of any kind wins.
#
#       prints ONE line:   <how><TAB><anchor>
#
#         how    -C | git-dir | cd | cwd | unresolved-cd | unparsed | no-python
#         anchor an absolute path, or empty when nothing could be resolved at
#                all (the caller falls back to $PWD, as it always did)
#
# Safe to source repeatedly. Never changes the caller's cwd. Never touches git.

if [ -n "${_GIT_JURISDICTION_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_GIT_JURISDICTION_SH_SOURCED=1

# Assigned via a quoted heredoc for the bash 3.2 reason guard-worktree-removal.sh
# documents: a `)` inside a character class mis-scans as the close of a $( )
# substitution on macOS's /bin/bash.
read -r -d '' _GJ_RESOLVER <<'PYEOF' || true
import json, os, re, shlex, sys

VERBS = set((os.environ.get("GJ_VERBS") or "").split())

# --- the legacy answer, kept verbatim --------------------------------------
# This regex is a byte-for-byte copy of the one the five guards carried, and it
# is copied ON PURPOSE: the invariant this file promises is that a cd-free
# command gets the OLD answer, and the only way to promise that is to keep the
# old code and run it.
_LEGACY_C = re.compile(r"\bgit\b\s+(?:[^\n;|&]*?\s)?-C\s+(\"[^\"]+\"|'[^']+'|\S+)")

PUNCT = {"(", ")", ";", ";;", "&&", "||", "|", "|&", "&", "\n"}


def out(how, anchor):
    sys.stdout.write("%s\t%s\n" % (how, anchor or ""))
    raise SystemExit


def absjoin(base, p):
    if not p:
        return base
    if p.startswith("~"):
        p = os.path.expanduser(p)
    if os.path.isabs(p):
        return os.path.normpath(p)
    if not base:
        return ""
    return os.path.normpath(os.path.join(base, p))


def legacy(cmd, cwd):
    m = _LEGACY_C.search(cmd)
    if m:
        return "-C", absjoin(cwd, m.group(1).strip("\"'"))
    return "cwd", cwd


def unresolvable(tok):
    """A path this process cannot expand. Refusing to guess is the point:
    inventing an expansion would make the guard judge a repository the command
    was never going to touch."""
    return bool(re.search(r"[$`*?\[\]]", tok))


def tokens(cmd):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def a_join(a, b):
    if a is None:
        return b
    if os.path.isabs(b) or b.startswith("~"):
        return b
    return os.path.join(a, b)


def gitdir_to_worktree(p):
    """--git-dir names the .git directory; the worktree is its parent. Anything
    else (a bare repository, a worktree's private git dir) is used as-is —
    resolving the repository from it is git's job, not this file's."""
    base = os.path.basename(p.rstrip("/"))
    return (os.path.dirname(p.rstrip("/")) or p) if base == ".git" else p


def git_target(argv):
    """(named-repository-or-None, subcommand, how) for one git invocation."""
    repo = None
    how = "cd"
    k = 1
    sub = ""
    while k < len(argv):
        a = argv[k]
        if a == "-C" and k + 1 < len(argv):
            # git applies repeated -C cumulatively, each relative to the last.
            repo = a_join(repo, argv[k + 1])
            how = "-C"
            k += 2
            continue
        if a == "--work-tree" and k + 1 < len(argv):
            repo = a_join(repo, argv[k + 1])
            how = "git-dir"
            k += 2
            continue
        if a.startswith("--work-tree="):
            repo = a_join(repo, a.split("=", 1)[1])
            how = "git-dir"
            k += 1
            continue
        if a == "--git-dir" and k + 1 < len(argv):
            if repo is None:
                repo = gitdir_to_worktree(argv[k + 1])
                how = "git-dir"
            k += 2
            continue
        if a.startswith("--git-dir="):
            if repo is None:
                repo = gitdir_to_worktree(a.split("=", 1)[1])
                how = "git-dir"
            k += 1
            continue
        if a in ("-c", "--exec-path", "--namespace", "--super-prefix") and k + 1 < len(argv):
            k += 2
            continue
        if a.startswith("-"):
            k += 1
            continue
        sub = a
        break
    return repo, sub, how


def walk(toks, cwd):
    # `moved` is what lets an answer say whether a cd was involved at all, so
    # `cwd` and `cd` stay distinguishable in the reported `how`. Two resolutions
    # that report the same word are two resolutions nobody can tell apart in a
    # log, which is the reporting half of the defect this file fixes.
    state = {"cur": cwd, "prev": cwd, "moved": False}
    stack = []
    seg = []
    found = []          # (sub, anchor, how) in command order

    def close(seg):
        argv = list(seg)
        while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
            argv.pop(0)
        while argv and argv[0] in ("!", "time", "command", "exec", "nohup", "eval"):
            argv.pop(0)
        if not argv:
            return
        cur = state["cur"]
        base = os.path.basename(argv[0])
        if base in ("cd", "pushd"):
            state["moved"] = True
            k = 1
            while k < len(argv) and argv[k].startswith("-") and argv[k] != "-":
                k += 1
            tgt = argv[k] if k < len(argv) else "~"
            if tgt == "-":
                state["cur"], state["prev"] = state["prev"], cur
                return
            if unresolvable(tgt):
                state["prev"], state["cur"] = cur, None
                return
            rooted = os.path.isabs(tgt) or tgt.startswith("~")
            state["prev"] = cur
            state["cur"] = absjoin(cur, tgt) if (cur or rooted) else None
            return
        if base == "popd":
            state["moved"] = True
            state["prev"], state["cur"] = cur, None   # the stack is not tracked
            return
        if base == "git":
            repo, sub, how = git_target(argv)
            if repo is not None:
                rooted = os.path.isabs(repo) or repo.startswith("~")
                anchor = absjoin(cur or "", repo) if (cur or rooted) else ""
                found.append((sub, anchor, how))
            else:
                if cur is None:
                    how = "unresolved-cd"
                else:
                    how = "cd" if state["moved"] else "cwd"
                found.append((sub, cur or "", how))
        return

    for t in toks:
        if t == "(":
            close(seg); seg = []
            stack.append((state["cur"], state["prev"]))
            continue
        if t == ")":
            close(seg); seg = []
            if stack:
                state["cur"], state["prev"] = stack.pop()
            continue
        if t in PUNCT:
            close(seg); seg = []
            continue
        seg.append(t)
    close(seg)
    return found


def main():
    try:
        d = json.loads(os.environ.get("GJ_PAYLOAD") or "{}")
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
    ti = d.get("tool_input") or {}
    cmd = (ti.get("command", "") if isinstance(ti, dict) else "") or ""
    cwd = str(d.get("cwd", "") or "")

    try:
        toks = tokens(cmd)
    except Exception:
        how, anchor = legacy(cmd, cwd)
        out("unparsed", anchor)

    found = walk(toks, cwd)
    if not found:
        out(*legacy(cmd, cwd))

    picked = None
    if VERBS:
        for row in found:
            if row[0] in VERBS:
                picked = row
                break
    if picked is None and not VERBS:
        picked = found[0]
    if picked is None:
        # The caller's own classifier said this is a commit or a push and this
        # walk disagrees. Do not invent an answer from a disagreement: hand back
        # the legacy one, which is what would have been used anyway.
        out(*legacy(cmd, cwd))

    sub, anchor, how = picked
    if not anchor:
        _h, a = legacy(cmd, cwd)
        out("unresolved-cd", a)
    out(how, anchor)


main()
PYEOF

# ---------------------------------------------------------------------------
# richos_git_anchor <payload-json> [verbs]
# ---------------------------------------------------------------------------
richos_git_anchor() {
    local payload="${1:-}" verbs="${2:-}"
    if ! command -v python3 >/dev/null 2>&1; then
        # Every caller of this already refuses without python3 (fail-closed),
        # so this line exists to be honest about WHY rather than to be relied on.
        printf 'no-python\t\n'
        return 0
    fi
    GJ_PAYLOAD="$payload" GJ_VERBS="$verbs" python3 -c "$_GJ_RESOLVER" 2>/dev/null \
        || printf 'no-python\t\n'
}
