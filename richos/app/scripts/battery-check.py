#!/usr/bin/env python3
"""battery-check.py — every commit that touches richos/mobile/ answers the battery question.

    battery-check.py                  the commits since the merge-base with origin/main (or main)
    battery-check.py <sha>            that one commit
    battery-check.py <base>..<head>   every commit in that range (a land: main..<branch>)

Exit: 0 every mobile commit answered NO with evidence (or none needed to); 1 at least one did
not, each named in one sentence; 2 usage, or a history that could not be read.

THE RULE (CEO ruling §81, 2026-09-24; the text lives in richos/mobile/AGENTS.md). Before a
change to the mobile folder is committed or declared finished, its author answers: would this
get iOS or Android to call RichOS a "power-intensive app" that is "draining battery by
frequently refreshing in the background", or anything similar? Anything but a clear NO means
the change is revised until it is one. The answer is recorded as a commit trailer:

    Battery-check: NO — <what was checked: background work, wakeups, idle redraws, polling ...>

WHAT THIS PROVES AND WHAT IT DOES NOT. It proves the question was answered on every commit
that touched the folder, with NO and non-empty evidence. It cannot prove the answer is true;
that is the author's evidence and the reviewer's reading of it.

  * Scope: a commit whose own diff touches richos/mobile/ (added, changed, deleted or renamed
    away). Merge commits are not checked: they carry no change of their own unless a conflict
    was resolved, and a merge of main into a branch would otherwise be charged with main's work.
  * Grandfathering is by ancestry, never by date: every commit reachable from GRANDFATHER_BASE
    (richos main when this check was wired) predates the rule and is exempt. Nothing else is.
  * The key is matched without regard to case, as Git matches trailer keys. The value must
    begin with the word NO, in capitals, then a dash (— – - or --), then evidence. "YES",
    "MAYBE", "No", "N/A", a bare "NO" and a "<placeholder>" are all refused. Every
    Battery-check trailer on the commit must pass; one good one does not excuse a bad one.

WHERE IT RUNS. proof-for.sh runs it for a commit or a range and for its default working-tree
mode (the committed half), and exits 3 on a refusal; the land runner (proof-run.py
main..<branch>) prints the sentence and refuses the land before any suite starts, whoever
wrote the commit. richos
has no committed pre-commit or commit-msg hook mechanism (core.hooksPath on this Mac is a
user-global directory that belongs to no repository), so the land is the enforcement point;
an author can run this script before handing off.
"""
import os
import re
import subprocess
import sys

# richos main at d17008c9 ("Record installed CPU enforcement and real recovery verification"),
# 2026-09-24, the tip when §81 was wired into the land path. Moving it grandfathers more history,
# so it is a reviewed one-line change with its reason in the commit, never a convenience.
GRANDFATHER_BASE = "d17008c911125d553243f860e705f543244b5078"
MOBILE = "richos/mobile"
KEY = "Battery-check"
ANSWER = re.compile(r"^NO\s*(?:—|–|--|-)\s*(\S.*)$", re.S)
PLACEHOLDER = re.compile(r"^<[^>]*>\.?$")
HERE = os.path.dirname(os.path.abspath(__file__))


class Unreadable(Exception):
    pass


def git(root, *args):
    r = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise Unreadable("git %s: %s" % (" ".join(args), (r.stderr or r.stdout).strip()))
    return r.stdout


def verdict(values):
    """None when the trailers answer NO with evidence; otherwise why not, as a phrase."""
    if not values:
        return "has no `%s:` trailer" % KEY
    for value in values:
        v = " ".join(value.split())
        m = ANSWER.match(v)
        if not m:
            return "answers `%s: %s`, and only NO with evidence passes" % (KEY, v or "(empty)")
        if PLACEHOLDER.match(m.group(1).strip()):
            return "answers NO with a placeholder instead of evidence (`%s`)" % m.group(1).strip()
    return None


def revisions(ref):
    """A range is used as given; a single commit is that commit alone (`<sha>^!`)."""
    return [ref] if ".." in ref else [ref + "^!"]


def check(root, revs, base=GRANDFATHER_BASE):
    """(checked, refused): how many non-merge commits in revs, outside base's history, touch the
    mobile folder, and [(sha, subject, reason)] for each of them that does not answer."""
    git(root, "rev-parse", "--verify", "--quiet", base + "^{commit}")
    fmt = "%H%x00%s%x00%(trailers:key=" + KEY + ",valueonly=true,unfold=true,separator=%x01)%x1e"
    out = git(root, "log", "--no-merges", "--format=" + fmt, *revs, "^" + base, "--", MOBILE + "/")
    checked, refused = 0, []
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, subject, trailers = record.split("\x00", 2)
        checked += 1
        values = [t for t in trailers.split("\x01") if t.strip()]
        reason = verdict(values)
        if reason:
            refused.append((sha, subject, reason))
    return checked, refused


def default_range(root):
    for upstream in ("origin/main", "main"):
        r = subprocess.run(["git", "-C", root, "merge-base", "HEAD", upstream], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip() + "..HEAD"
    raise Unreadable("no merge-base with origin/main or main; name a commit or a range")


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.split("THE RULE")[0].rstrip())
        return 0
    if len(argv) > 1 or any(a.startswith("-") for a in argv):
        sys.stderr.write("battery-check: one commit or one range, e.g. main..cc/branch — see --help\n")
        return 2
    try:
        root = git(HERE, "rev-parse", "--show-toplevel").strip()
        ref = argv[0] if argv else default_range(root)
        checked, refused = check(root, revisions(ref), GRANDFATHER_BASE)
    except Unreadable as exc:
        sys.stderr.write("battery-check: cannot read the history, so nothing is passed: %s\n" % exc)
        return 2
    if not refused:
        print("battery-check: %d commit(s) in %s touch %s/ outside %s's history; %s." % (
            checked, ref, MOBILE, GRANDFATHER_BASE[:8],
            "every one answers the battery question NO" if checked else "nothing to answer"))
        return 0
    for sha, subject, reason in refused:
        sys.stderr.write("REFUSED: %s \"%s\" touches %s/ and %s.\n" % (sha[:12], subject, MOBILE, reason))
    sys.stderr.write(
        "  CEO ruling §81 (richos/mobile/AGENTS.md): would this change get iOS or Android to call RichOS\n"
        "  a power-intensive app that drains battery by refreshing in the background? Revise the change\n"
        "  until the answer is a clear NO, then record it on that commit (reword it; the branch is not on\n"
        "  main yet):\n"
        "      %s: NO — <the background work, wakeups, idle redraws and polling you checked>\n" % KEY)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
