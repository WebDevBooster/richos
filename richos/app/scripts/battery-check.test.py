#!/usr/bin/env python3
"""battery-check.test.py — a commit touching richos/mobile/ without `Battery-check: NO — <evidence>`
is refused by name; one that answers NO with evidence passes; a commit outside the folder, a merge
and everything in the grandfathered history are not asked. Throwaway Git repositories under
$TMPDIR, plus two read-only probes of this repository's own history. Nothing builds or launches.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "battery-check.py")
SPEC = importlib.util.spec_from_file_location("battery_check", SCRIPT)
bc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bc)

PASSED = FAILED = 0


def check(ok, what, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("  ok    %s" % what)
    else:
        FAILED += 1
        print("  FAIL  %s%s" % (what, ("\n        %r" % (detail,)) if detail else ""))


# The throwaway repositories must not run this Mac's user-global hooks (core.hooksPath), and
# carry their own identity so nothing about the operator's configuration is read or needed.
GIT = ["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Battery Test",
       "-c", "user.email=battery-test@example.invalid", "-c", "commit.gpgsign=false",
       "-c", "init.defaultBranch=main"]


def git(repo, *args):
    return subprocess.run(GIT + ["-C", repo, *args], capture_output=True, text=True, check=True).stdout.strip()


def commit(repo, path, message, delete=False):
    full = os.path.join(repo, path)
    if delete:
        git(repo, "rm", "-q", path)
    else:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "a") as fh:
            fh.write(message.splitlines()[0] + "\n")
        git(repo, "add", path)
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def refused_in(repo, sha, base):
    checked, refused = bc.check(repo, [sha + "^!"], base=base)
    return checked, [r for r in refused if r[0] == sha]


def main():
    tmp = tempfile.mkdtemp(prefix="battery-check-test.", dir=os.environ.get("TMPDIR"))
    try:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        git(repo, "init", "-q")
        base = commit(repo, "richos/mobile/old.txt", "an old mobile change with no answer")
        m = "richos/mobile/native-android/App.kt"

        # B1 — the refusal every other case is measured against.
        sha = commit(repo, m, "mobile change, no trailer")
        n, r = refused_in(repo, sha, base)
        check(n == 1 and len(r) == 1 and "no `Battery-check:` trailer" in r[0][2],
              "B1 a mobile commit with no Battery-check trailer is refused", (n, r))

        # B2 — the positive control: the same kind of commit, answered, passes.
        sha = commit(repo, m, "mobile change, answered\n\nBattery-check: NO — no timer, wakeup, redraw or polling is added.")
        n, r = refused_in(repo, sha, base)
        check(n == 1 and r == [], "B2 `Battery-check: NO — <evidence>` passes", (n, r))

        # B3/B4 — anything but NO is refused, and the sentence quotes the answer given.
        for label, value in (("B3", "YES — it refreshes every minute"), ("B4", "MAYBE")):
            sha = commit(repo, m, "mobile change %s\n\nBattery-check: %s" % (label, value))
            n, r = refused_in(repo, sha, base)
            check(len(r) == 1 and value in r[0][2], "%s `Battery-check: %s` is refused" % (label, value), r)

        # B5 — a non-mobile commit is not asked, even with no trailer at all.
        sha = commit(repo, "richos/app/ui/main.js", "desktop change, no trailer")
        n, r = refused_in(repo, sha, base)
        check(n == 0 and r == [], "B5 a commit outside richos/mobile/ is ignored", (n, r))

        # B6 — the answers that look like NO and are not.
        for label, value, why in (
                ("B6a", "NO", "a bare NO has no evidence"),
                ("B6b", "No — nothing new", "NO is written in capitals"),
                ("B6c", "NO — <evidence>", "a placeholder is not evidence"),
                ("B6d", "NOPE — fine", "NOPE is not NO"),
                ("B6e", "N/A", "not applicable is not an answer")):
            sha = commit(repo, m, "mobile change %s\n\nBattery-check: %s" % (label, value))
            n, r = refused_in(repo, sha, base)
            check(len(r) == 1, "%s `%s` is refused (%s)" % (label, value, why), r)

        # B7 — every trailer must pass; one good answer does not excuse a YES beside it.
        sha = commit(repo, m, "two answers\n\nBattery-check: NO — no timers added\nBattery-check: YES — polls")
        n, r = refused_in(repo, sha, base)
        check(len(r) == 1 and "YES" in r[0][2], "B7 a NO beside a YES is refused", r)

        # B8 — a trailer is only a trailer in the closing block, as Git reads it.
        sha = commit(repo, m, "buried answer\n\nBattery-check: NO — this line is not a trailer\n\nThe end of the body.")
        n, r = refused_in(repo, sha, base)
        check(len(r) == 1, "B8 a Battery-check line inside the body, not the trailer block, is refused", r)

        # B9 — the forms a real author types: key in any case, ASCII dash, wrapped evidence.
        for label, trailer in (("B9a", "battery-check: NO — lowercase key, as Git matches keys"),
                               ("B9b", "Battery-check: NO - ascii hyphen, no background work"),
                               ("B9c", "Battery-check: NO -- two hyphens, no wake lock"),
                               ("B9d", "Battery-check: NO — evidence that runs long enough to be\n folded onto a second line")):
            sha = commit(repo, m, "mobile change %s\n\n%s" % (label, trailer))
            n, r = refused_in(repo, sha, base)
            check(n == 1 and r == [], "%s `%s` passes" % (label, trailer.splitlines()[0]), r)

        # B10 — removing mobile files is touching them.
        sha = commit(repo, "richos/mobile/old.txt", "remove an old mobile file", delete=True)
        n, r = refused_in(repo, sha, base)
        check(len(r) == 1, "B10 a commit that only deletes under richos/mobile/ is still asked", r)

        # B11 — a range is read commit by commit, and names each unanswered one.
        start = git(repo, "rev-parse", "HEAD")
        a = commit(repo, m, "range one, unanswered")
        commit(repo, "docs/x.md", "range two, docs only")
        c = commit(repo, m, "range three, answered\n\nBattery-check: NO — a label change only; nothing runs.")
        n, r = bc.check(repo, [start + ".." + c], base=base)
        check(n == 2 and [x[0] for x in r] == [a], "B11 a range refuses exactly its unanswered mobile commit", (n, r))

        # B12 — grandfathering is ancestry: the same unanswered commit passes once it is in base.
        n, r = bc.check(repo, [start + ".." + c], base=a)
        check(n == 1 and r == [], "B12 a commit reachable from the grandfather base is not asked", (n, r))

        # B13 — a merge carries no change of its own, so main's work is not charged to it.
        git(repo, "checkout", "-q", "-b", "side", start)
        side = commit(repo, "richos/app/side.txt", "side work, not mobile")
        git(repo, "merge", "-q", "--no-ff", "-m", "merge main into side, no trailer", c)
        merge = git(repo, "rev-parse", "HEAD")
        n, r = bc.check(repo, [c + ".." + merge], base=base)
        check(n == 0 and r == [], "B13 a merge bringing mobile changes in is not asked; its parents are", (n, r, side))

        # B14 — an unreadable history refuses rather than passes.
        try:
            bc.check(repo, ["no-such-branch..HEAD"], base=base)
            check(False, "B14 an unreadable range raises Unreadable")
        except bc.Unreadable:
            check(True, "B14 an unreadable range raises Unreadable")
        try:
            bc.check(repo, [c + "^!"], base="0" * 40)
            check(False, "B15 a missing grandfather base raises Unreadable")
        except bc.Unreadable:
            check(True, "B15 a missing grandfather base raises Unreadable")
        # B17 — the command line names each refused commit in one sentence and exits 1.
        import contextlib
        import io
        saved = (bc.HERE, bc.GRANDFATHER_BASE)
        bc.HERE, bc.GRANDFATHER_BASE = repo, base
        err, out = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                rc = bc.main([start + ".." + c])
        finally:
            bc.HERE, bc.GRANDFATHER_BASE = saved
        check(rc == 1 and ("REFUSED: %s \"range one, unanswered\" touches richos/mobile/ and has no" % a[:12]) in err.getvalue(),
              "B17 the command line exits 1 with a sentence naming the unanswered commit", (rc, err.getvalue()))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    check(not os.path.exists(tmp), "B16 the throwaway repositories are gone (§54)", tmp)

    # This repository's own history, read only. e879df50 touched richos/mobile/ before §81 and
    # carries no answer: grandfathered through the command line, refused when the base is
    # moved behind it — the refusal is shown to be possible, so the pass means something.
    root = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    old = "e879df50"
    has = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", old + "^{commit}"],
                         capture_output=True, text=True).returncode == 0
    if not has:
        print("  NOT RUN  R1/R2 — %s is not in this clone" % old)
        return 1 if FAILED else 0
    cli = subprocess.run([sys.executable, SCRIPT, old], capture_output=True, text=True)
    check(cli.returncode == 0 and "0 commit(s)" in cli.stdout,
          "R1 an unanswered mobile commit already on main before §81 is grandfathered (exit 0)", (cli.returncode, cli.stdout, cli.stderr))
    n, r = bc.check(root, [old + "^!"], base=old + "^")
    check(n == 1 and len(r) == 1, "R2 the same commit is refused once it is outside the base's history", (n, r))
    wiring(root, old)
    return 1 if FAILED else 0


def wiring(root, old):
    """The land path: proof-for.sh runs the check for commits and ranges and turns a refusal
    into exit 3; proof-run.py passes the sentence on and refuses the land with nothing run. A stub checker
    (PROOF_FOR_BATTERY_CHECK) stands in so the refusal is observable on a real commit."""
    proof_for = os.path.join(HERE, "proof-for.sh")
    proof_run = os.path.join(HERE, "proof-run.py")
    tmp = tempfile.mkdtemp(prefix="battery-wiring-test.", dir=os.environ.get("TMPDIR"))
    try:
        seen = os.path.join(tmp, "argv")
        stubs = {}
        for rc in (0, 1, 2):
            path = os.path.join(tmp, "stub-%d.py" % rc)
            with open(path, "w") as fh:
                fh.write("import sys\nopen(%r, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
                         "print('STUB REFUSED: deadbeef touches richos/mobile/')\nsys.exit(%d)\n" % (seen, rc))
            stubs[rc] = path

        def pf(stub, *args):
            env = dict(os.environ)
            if stub is not None:
                env["PROOF_FOR_BATTERY_CHECK"] = stub
            return subprocess.run(["bash", proof_for, "--quiet", *args], cwd=root, env=env, capture_output=True, text=True)

        r = pf(stubs[1], old)
        check(r.returncode == 3 and "STUB REFUSED" in r.stderr and "battery question" in r.stderr,
              "W1 proof-for.sh <sha>: a refused battery check is exit 3, with the checker's sentence", (r.returncode, r.stderr[-400:]))
        r = pf(None, old)
        check(r.returncode == 0, "W2 (positive probe) the real checker passes that grandfathered commit through proof-for.sh",
              (r.returncode, r.stderr[-400:]))
        r = pf(stubs[2], old)
        check(r.returncode == 2, "W3 a checker that cannot read the history stops proof-for.sh (exit 2), never passes", r.returncode)
        open(seen, "w").close()
        pf(stubs[0], old)
        pf(stubs[0], old + "^.." + old)
        pf(stubs[0])
        args = open(seen).read().splitlines()
        check(len(args) == 3 and args[0] == old and args[1] == old + "^.." + old and args[2].endswith("..HEAD"),
              "W4 the checker is handed the commit, the range, and <merge-base>..HEAD for the working mode", args)
        open(seen, "w").close()
        r = pf(stubs[1], "--paths", "richos/mobile/AGENTS.md")
        r2 = pf(stubs[1], "--staged")
        check(r.returncode != 3 and r2.returncode != 3 and open(seen).read() == "",
              "W5 --paths and --staged name no commits, so the checker is not asked", (r.returncode, r2.returncode))

        env = dict(os.environ, PROOF_FOR_BATTERY_CHECK=stubs[1])
        logs = os.path.join(tmp, "run")
        r = subprocess.run([sys.executable, proof_run, "--log-dir", logs, old], cwd=root, env=env, capture_output=True, text=True)
        # proof-run.py prints proof-for.sh's refusal, then "proof-for.sh exited 3; nothing was
        # run." and exits 2: any exit but 0 refuses the land.
        check(r.returncode != 0 and "battery question" in r.stderr and "exited 3; nothing was run" in r.stderr
              and not os.path.exists(os.path.join(logs, "summary.json")),
              "W6 proof-run.py refuses the land, names the battery question and runs nothing", (r.returncode, r.stderr[-400:]))
        env["PROOF_FOR_BATTERY_CHECK"] = stubs[0]
        r = subprocess.run([sys.executable, proof_run, "--dry-run", "--log-dir", os.path.join(tmp, "dry"), old],
                           cwd=root, env=env, capture_output=True, text=True)
        check(r.returncode == 0, "W7 (positive probe) with an answered history the same land plans normally", (r.returncode, r.stderr[-400:]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    check(not os.path.exists(tmp), "W8 the stub directory is gone (§54)", tmp)


if __name__ == "__main__":
    rc = main()
    print("battery-check: %d passed, %d failed" % (PASSED, FAILED))
    sys.exit(rc or (1 if FAILED else 0))
