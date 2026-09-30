#!/usr/bin/env python3
"""autocheck.py — the basic checks run by git itself, at commit and at merge, for everyone.

WHY THIS EXISTS (2026-09-29, CEO ruling §97). Nightly attempt 20260929T063824Z-b27b6279
failed on `lint growth: clippy::let_underscore_must_use: 782 > 777`: a branch added five
discarded send results, nobody ran the lint before it reached main, and the build found it.
His words: *"WHY THE FUCK DOES ANYONE NEED TO BE "TOLD" ANYTHING WHEN IT COMES TO PREVENTING
BASIC-LEVEL SHIT-FUCKERY OF ANY KIND????"* So nobody is told. Git runs this through the
repository's hooks (installed by `install.sh` beside this file) for every committer: an
engineer in a worktree, Codex, Rich in the main checkout.

  COMMIT, on any branch but main (pre-commit): `lint.sh --changed --strict` over what
  differs from HEAD, i.e. the lint ratchets (static, load rules, and Clippy for a Rust set
  whose inputs changed), and no count may grow whatever room a ceiling has. Then the land's
  own selector (`proof-for.sh`) over the BRANCH'S WHOLE CHANGE: whatever it refuses
  (UNCOVERED, a map that does not reconcile) refuses the commit, and the selected suites that
  measure under a second run here (see branch_selection). A merge into a branch
  (pre-merge-commit) runs `--changed` against the ceilings only. Both run on exactly the
  content being committed: unstaged edits and untracked files are set aside for the length
  of the check and put back after it (StagedOnly). The repository enforces no formatter, so
  none is run. A failure refuses the commit with the reason.

  LAND, anything that moves main (pre-merge-commit on main, pre-commit on main, and
  pre-push of main as the backstop): the suites `proof-for.sh` assigns to the change, run
  by `proof-run.py`, plus `lint.sh --all` when the selection does not already include
  `lint.test.sh`. Nobody chooses the suites. A failure refuses the merge before it exists,
  so it cannot be pushed. A pass leaves a receipt keyed by the tree it proved. A check
  proof-run reports NOT RUN is never a pass: the land accepts only a suite that needs a
  screen (a land never uses this Mac's screen), names it in its verdict and records it in
  the receipt as not run; any other NOT RUN refuses the land (README.md, "NOT RUN").

  THE ONE ESCAPE is git's own `--no-verify`. It cannot be prevented; it is recorded. After
  the fact (post-commit, post-merge) a commit whose tree this check never passed, or a main
  that moved to a tree without a land receipt, raises an escalation in the ledger the lead's
  session reads at every session start and turn end (`escalate.sh`), and is appended to
  `<git-common-dir>/richos-autocheck/bypass.log`.

Which copy of this file runs is chosen by the hook shim: the one committed at HEAD, else the
one on main, else (the land that introduces it) the one being merged. A branch's commits are
checked by its own version; a land into main is checked by main's.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

LAND_BRANCH = "main"
LINT = "richos/app/scripts/lint.sh"
LINT_DRIVER = "richos/app/scripts/lint/driver.py"
PROOF_FOR = "richos/app/scripts/proof-for.sh"
PROOF_RUN = "richos/app/scripts/proof-run.py"
ENGINE_ESCALATE = "richos/engine/scripts/escalate.sh"
ACTIVE = "RICHOS_AUTOCHECK_ACTIVE"
ZERO = "0" * 40


def say(text=""):
    print(text, file=sys.stderr, flush=True)


def banner(title, lines):
    say("")
    say(f"=== {title} ===")
    for line in lines:
        say("  " + line)
    say("")


# ---------------------------------------------------------------------------------------
# Git, with and without the hook's environment
# ---------------------------------------------------------------------------------------
# A hook runs with GIT_DIR, GIT_INDEX_FILE and friends exported. The questions about THIS
# commit (what is staged, which tree is being written) must be asked in that environment,
# because for `git commit -a` or `git commit <path>` the index being committed is a
# temporary file only that environment names. The CHECKS must not inherit it: a test suite
# that builds its own fixture repository would otherwise write into this one.

def git(*args, env=None, check=True, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True,
                            stdin=subprocess.DEVNULL)
    if check and result.returncode:
        raise RuntimeError(f"git {' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip() if check else result


def clean_env(common):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    # A land runs every suite it selected: a caller's opt-in to skip unchanged suites would
    # turn them into NOT RUN, which the land refuses (accepted_not_run).
    env.pop("RUN_TESTS_SKIP_UNCHANGED", None)
    cargo = str(Path.home() / ".cargo/bin")
    if cargo not in env.get("PATH", "").split(":"):
        env["PATH"] = env.get("PATH", "") + ":" + cargo
    env[ACTIVE] = f"{common}:{os.getpid()}"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def ancestors():
    pids, pid = set(), os.getppid()
    for _ in range(64):
        if pid <= 1 or pid in pids:
            break
        pids.add(pid)
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True)
        try:
            pid = int(out.stdout.strip())
        except ValueError:
            break
    return pids


def inside_own_check(common):
    """True only when an autocheck of THIS repository is an ancestor of this process: a check
    whose suites commit into the repository under check. A copied or invented value names a
    process that is not our ancestor and exempts nothing."""
    value = os.environ.get(ACTIVE, "")
    where, _, pid = value.rpartition(":")
    return where == common and pid.isdigit() and int(pid) in ancestors()


class Repo:
    def __init__(self):
        self.top = Path(git("rev-parse", "--show-toplevel"))
        self.git_dir = Path(git("rev-parse", "--absolute-git-dir"))
        common = Path(git("rev-parse", "--git-common-dir"))
        self.common = (common if common.is_absolute() else (Path.cwd() / common)).resolve()
        self.branch = git("symbolic-ref", "-q", "--short", "HEAD", check=False).stdout.strip()
        self.state = self.common / "richos-autocheck"
        self.env = clean_env(str(self.common))

    def run(self, argv, **kw):
        say("+ " + " ".join(shlex.quote(str(a)) for a in argv))
        return subprocess.run([str(a) for a in argv], cwd=self.top, env=self.env, stdin=subprocess.DEVNULL, **kw)

    def index_tree(self):
        return git("write-tree", cwd=self.top)

    def head_tree(self, rev="HEAD"):
        return git("rev-parse", f"{rev}^{{tree}}", cwd=self.top)

    # Receipts: a commit check leaves the tree it passed in this worktree's git dir, for the
    # post-commit hook to compare; a land check leaves one per tree, shared by every worktree.
    def marker(self):
        return self.git_dir / "richos-autocheck-verified"

    def land_receipt(self, tree):
        return self.state / "land" / tree

    def write_land_receipt(self, tree, detail):
        path = self.land_receipt(tree)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(dict(detail, tree=tree, at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
                                   sort_keys=True) + "\n")


# ---------------------------------------------------------------------------------------
# The commit check
# ---------------------------------------------------------------------------------------

def commit_check(repo, what):
    started = time.monotonic()
    # What the commit holds: the index the hook was given (for `git commit <path>` or `-a`, the
    # temporary one git names in GIT_INDEX_FILE). Unstaged edits are not in it, so they neither
    # call for a lint nor answer for one (see StagedOnly).
    staged = git("diff", "--cached", "--name-only", "--no-renames").splitlines()
    app = sorted({p for p in staged if p.startswith("richos/app/")})
    if what == "commit" and stale_pins(repo):
        return 1
    if not app:
        say(f"autocheck: {what}: nothing under richos/app changed, so no lint applies "
            f"({time.monotonic() - started:.1f}s)")
        return 0
    with StagedOnly(repo) as aside:
        if aside.summary:
            say(f"autocheck: {what}: {aside.summary} set aside for the check, so it sees only what is committed")
        rc = lint_and_select(repo, what, app)
    if rc == 0:
        say(f"autocheck: {what}: passed in {time.monotonic() - started:.1f}s")
    return rc


def lint_and_select(repo, what, app):
    if not (repo.top / LINT).is_file():
        banner(f"{what.upper()} REFUSED: the lint is missing", [f"{LINT} is not in this tree; nothing can be checked."])
        return 1
    driver = repo.top / LINT_DRIVER
    known = driver.read_text(errors="replace") if driver.is_file() else ""
    if "--changed" in known:
        # A commit may not grow any count (--strict). A merge into a branch brings main's
        # landed changes, which were held to the ceilings at their land, so it is not.
        mode = ["--changed", "--strict"] if what == "commit" and "--strict" in known else ["--changed"]
    else:
        # A branch older than the commit mode: the full static pass, and the fast set when
        # Rust changed. Slower, never looser.
        rust = any(p.endswith(".rs") or Path(p).name in ("Cargo.toml", "Cargo.lock") for p in app)
        mode = ["--fast"] if rust else ["--static"]
    say(f"autocheck: {what}: {len(app)} changed path(s) under richos/app; lint {' '.join(mode)} "
        "(the content being committed)")
    result = repo.run(["bash", LINT, *mode])
    if result.returncode:
        banner(f"{what.upper()} REFUSED: the lint failed for this change", [
            "The reason is printed just above (\"Lint refused: ...\").",
            "Fix it and commit again. Nothing needs to be run by hand; this check runs itself.",
            "git's --no-verify skips it, and every skip is recorded in the lead's escalation ledger.",
        ])
        return 1
    if what == "commit" and branch_selection(repo, what):
        return 1
    return 0


# ---------------------------------------------------------------------------------------
# The commit check sees exactly the bytes being committed
# ---------------------------------------------------------------------------------------
# Hunt part 2, finding 10 (2026-09-30). The commit check ran the lint on the WORKING TREE, so
# that changed-path lint saw unstaged edits too, and then approved the INDEX. A bad staged
# edit whose unstaged replacement passed was committed with no record, and a clean staged
# edit was refused over unstaged work the commit does not hold. The land refuses a working
# tree that differs from what it commits (land_from_index); a branch commit cannot, because
# committing part of the work in progress is how atomic commits are made.
#
# So, for the length of the check, the working tree IS what is being committed. The design is
# pre-commit's `staged_files_only` (pre-commit.com, MIT), taken as design: the unstaged
# difference is saved as a binary patch and untracked files are moved into this worktree's
# git directory; `git checkout -- .` makes the working tree equal the index the commit is
# written from; the checks run; the patch is applied back and the files moved back. Ignored
# files stay where they are: they are never committed, and a check needs its build caches and
# installed dependencies. The lint still reads the working tree, as it always has; that tree
# now holds the committed bytes and nothing else.
#
# If a check is killed while edits are set aside, or they cannot be put back, they stay in
# ASIDE, and every later commit check refuses, naming the directory and how to restore it,
# until it is gone. Nothing is ever set aside on top of them.

ASIDE = "richos-autocheck-aside"


class StagedOnly:
    def __init__(self, repo):
        self.repo = repo
        self.dir = repo.git_dir / ASIDE
        self.patch = self.dir / "unstaged.patch"
        self.held = self.dir / "untracked"
        self.moved = []
        self.patched = False
        self.summary = ""

    def how_to_restore(self):
        return [f"Your unstaged edits and untracked files are in {self.dir}.",
                f"To put them back: cd {self.repo.top} && git apply --binary {self.patch}"
                " (when that file exists),",
                f"then move everything under {self.held} back to the same path here,",
                f"then delete {self.dir} and commit again."]

    def hook_git(self, *args):
        # The hook's own environment: its GIT_INDEX_FILE is the index being committed.
        return subprocess.run(["git", *args], cwd=self.repo.top, capture_output=True, stdin=subprocess.DEVNULL)

    def __enter__(self):
        if self.dir.exists():
            raise RuntimeError("\n  ".join([
                "an earlier commit check set work aside and did not put it back "
                "(it was interrupted, or the restore failed); nothing was set aside this time.",
                *self.how_to_restore()]))
        diff = self.hook_git("diff", "--binary", "--no-color", "--no-ext-diff", "--ignore-submodules",
                             "--no-renames")
        added = self.hook_git("diff", "--name-only", "--diff-filter=A", "-z")
        untracked = self.hook_git("ls-files", "--others", "--exclude-standard", "--directory", "-z")
        for done in (diff, added, untracked):
            if done.returncode:
                raise RuntimeError("cannot read what differs from the commit: "
                                   + done.stderr.decode(errors="replace").strip())
        if added.stdout.strip(b"\0"):
            raise RuntimeError("a file added with `git add -N` is not in the commit and cannot be set aside "
                               "safely; stage it or remove it from the index (git rm --cached) and commit again")
        names = [os.fsdecode(n).rstrip("/") for n in untracked.stdout.split(b"\0") if n]
        if not diff.stdout and not names:
            return self
        self.dir.mkdir(parents=True)
        try:
            (self.dir / "README.txt").write_text("\n".join(self.how_to_restore()) + "\n")
            if diff.stdout:
                self.patch.write_bytes(diff.stdout)
                self.patched = True
            for name in names:
                target = self.held / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(self.repo.top / name), str(target))
                self.moved.append(name)
            if self.patched:
                done = self.hook_git("-c", "submodule.recurse=0", "checkout", "--", ".")
                if done.returncode:
                    raise RuntimeError("cannot make the working tree equal the commit: "
                                       + done.stderr.decode(errors="replace").strip())
            if self.hook_git("diff", "--quiet", "--ignore-submodules").returncode:
                raise RuntimeError("the working tree still differs from the commit after setting work aside")
        except BaseException:
            self.restore()
            raise
        parts = []
        if self.patched:
            parts.append("unstaged edits")
        if self.moved:
            parts.append(f"{len(self.moved)} untracked path(s)")
        self.summary = " and ".join(parts)
        return self

    def __exit__(self, *exc):
        self.restore()
        return False

    def restore(self):
        if not self.dir.exists():
            return
        problems = []
        if self.patched:
            applied = self.hook_git("apply", "--whitespace=nowarn", "--binary", str(self.patch))
            if applied.returncode:
                # A check wrote into a tracked file. The engineer's edit is kept, not the check's.
                self.hook_git("-c", "submodule.recurse=0", "checkout", "--", ".")
                applied = self.hook_git("apply", "--whitespace=nowarn", "--binary", str(self.patch))
            if applied.returncode:
                problems.append("git apply failed: " + applied.stderr.decode(errors="replace").strip())
            else:
                self.patched = False
                self.patch.unlink()
        for name in list(self.moved):
            destination = self.repo.top / name
            if os.path.lexists(destination):
                problems.append(f"{name} exists again, so the set-aside copy was not moved over it")
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(self.held / name), str(destination))
            self.moved.remove(name)
        if problems:
            raise RuntimeError("\n  ".join(["the work set aside for the check could not all be put back: "
                                            + "; ".join(problems), *self.how_to_restore()]))
        shutil.rmtree(self.dir)


# ---------------------------------------------------------------------------------------
# A changed source that a reviewed check pins
# ---------------------------------------------------------------------------------------
# 2026-09-29: three finished branches (make-release.sh, a stable-release script, run-tests.sh)
# passed every commit here and were refused at the merge, because
# proof_evidence.qualify_recipe raises UnqualifiedReader when a source a reviewed unit pins by
# SHA-256 no longer matches its pin, and only proof-run.test.sh ran that. Each cost a full merge
# run plus another engineer pass. The same comparison runs here, over the branch's changed
# paths only, and reads the qualification file only when one of them is named in it.

QUALIFICATIONS = "docs/development/verification-input-qualifications.json"


def stale_pins(repo):
    """Refuse (return 1) when a path this branch changed is a pinned source of a reviewed unit
    and the pin no longer matches the staged content."""
    import hashlib
    paths = branch_paths(repo)
    if not paths:
        return 0
    got = subprocess.run(["git", "show", f":{QUALIFICATIONS}"], cwd=repo.top, env=repo.env,
                         capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if got.returncode:
        return 0  # this tree has no qualification file, so nothing is pinned
    if not any(p in got.stdout for p in paths):
        return 0  # the common case: nothing changed is named there; no parse
    try:
        units = json.loads(got.stdout).get("units", {})
    except ValueError:
        return 0  # the merge-time test reports a malformed file; not this check's job
    changed = set(paths)
    stale = []
    for unit, body in sorted(units.items()):
        for source, pinned in sorted((body.get("sources") or {}).items()):
            if source not in changed:
                continue
            blob = subprocess.run(["git", "show", f":{source}"], cwd=repo.top, env=repo.env,
                                  capture_output=True, stdin=subprocess.DEVNULL)
            now = hashlib.sha256(blob.stdout).hexdigest() if blob.returncode == 0 else "(file removed)"
            if now != pinned:
                stale.append((source, unit, pinned, now))
    if not stale:
        return 0
    lines = []
    for source, unit, pinned, now in stale:
        lines.append(f"{source} (unit \"{unit}\"): pinned {pinned[:12]}, now {now[:12]}")
    lines += [
        "",
        f"A reviewed check reads these files, and {QUALIFICATIONS} pins each by SHA-256.",
        "The merge would refuse this branch with UnqualifiedReader (proof_evidence.qualify_recipe).",
        "Fix: renew the pin in that file's \"sources\" for the unit (the new SHA-256 is",
        "`shasum -a 256 <file>`), as commit a6bd0145 did for make-release.sh; re-check that the",
        "unit's \"review\" text still describes what the changed file reads.",
    ]
    banner("COMMIT REFUSED: a changed file is pinned by a reviewed check", lines)
    return 1


# ---------------------------------------------------------------------------------------
# What the land would refuse, refused at the commit
# ---------------------------------------------------------------------------------------
# 2026-09-29: two finished branches (isaac-opus-speckle1, andy-opus-speckle1) were refused at
# Rich's merge for UNCOVERED paths, four each, although every one of their commits had passed
# this hook: the commit ran the lint and nothing else, so the first thing that could see the
# refusal was the land. The same day a Rust test file made app/README.md's counts false and
# nothing short of the nightly ran docs-claims.js. So a commit now asks the land's own
# selector about the BRANCH'S WHOLE CHANGE (the merge-base with main to the tree being
# committed, which is what the land will diff), refuses what it refuses, and runs the selected
# suites that measure under a second in ui/tests/suite-weights.tsv. The heavier suites (Rust,
# the browser suites, the build suites) still run only at the land: minutes per commit would
# be the wrong trade for the one engineer who is waiting on it.

QUICK_WEIGHTS = "richos/app/ui/tests/suite-weights.tsv"
UI_SUITE_LINE = "cd richos/app/ui/tests && node "


def branch_paths(repo):
    """The branch's change as the land will see it: merge-base(main, HEAD) against the index
    being committed. With no main to compare to, the staged change alone."""
    base = git("merge-base", f"refs/heads/{LAND_BRANCH}", "HEAD", check=False, cwd=repo.top)
    if base.returncode == 0 and base.stdout.strip():
        return [p for p in git("diff", "--cached", "--name-only", "--no-renames", base.stdout.strip()).splitlines() if p]
    return [p for p in git("diff", "--cached", "--name-only", "--no-renames").splitlines() if p]


def quick_suites(repo, commands):
    """The selected UI suites whose measured weight is 0, i.e. under a second (the file's
    own convention). A suite with no row is not assumed quick; it runs at the land."""
    weights = repo.top / QUICK_WEIGHTS
    if not weights.is_file():
        return []
    quick = set()
    for line in weights.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and not line.startswith("#") and parts[1].strip() == "0":
            quick.add(parts[0].strip())
    return [c[len(UI_SUITE_LINE):].strip() for c in commands
            if c.startswith(UI_SUITE_LINE) and c[len(UI_SUITE_LINE):].strip() in quick]


def branch_selection(repo, what):
    started = time.monotonic()
    if not (repo.top / PROOF_FOR).is_file():
        banner(f"{what.upper()} REFUSED: cannot select the checks", [f"{PROOF_FOR} is not in this tree."])
        return 1
    paths = branch_paths(repo)
    if not paths:
        return 0
    commands, rc = select(repo, ["--paths", ",".join(paths)])
    if commands is None:
        refuse_selection(what, rc)
        say("  The land runs this same selection over the same change and would refuse it there.")
        return 1
    quick = quick_suites(repo, commands)
    for suite in quick:
        say(f"+ (cd richos/app/ui/tests && node {suite})")
        try:
            result = subprocess.run(["node", suite], cwd=repo.top / "richos/app/ui/tests", env=repo.env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            banner(f"{what.upper()} REFUSED: {suite} did not finish in 120 s",
                   [f"It measures under a second ({QUICK_WEIGHTS}); a hang is a failure, not a pass."])
            return 1
        if result.returncode:
            sys.stderr.write((result.stdout + result.stderr)[-4000:])
            banner(f"{what.upper()} REFUSED: {suite} failed for this branch", [
                f"proof-for.sh selects {suite} for this change, so the land would run it and refuse.",
                "Its output is just above. Fix the branch and commit again.",
            ])
            return 1
    later = len(commands) - len(quick)
    say(f"autocheck: {what}: the land's selection over the branch's {len(paths)} changed path(s) maps cleanly; "
        f"ran {', '.join(quick) or 'no quick suite'}; {later} heavier check command(s) run at the land "
        f"({time.monotonic() - started:.1f}s)")
    return 0


# ---------------------------------------------------------------------------------------
# The land check
# ---------------------------------------------------------------------------------------

def git_path(repo, name):
    path = Path(git("rev-parse", "--git-path", name, cwd=repo.top))
    return path if path.is_absolute() else repo.top / path


def merge_heads(repo):
    """What is being merged. A conflicted merge concluded by `git commit` has MERGE_HEAD; an
    automatic `git merge` runs pre-merge-commit BEFORE writing it (measured, git 2.5x), and
    names its heads only in GIT_REFLOG_ACTION ("merge <name> ...")."""
    try:
        heads = [line.split()[0] for line in git_path(repo, "MERGE_HEAD").read_text().splitlines() if line.strip()]
        if heads:
            return heads
    except OSError:
        pass
    action = os.environ.get("GIT_REFLOG_ACTION", "")
    if not action.startswith("merge "):
        return []
    heads = []
    for name in action.split()[1:]:
        found = git("rev-parse", "--verify", "-q", f"{name}^{{commit}}", check=False, cwd=repo.top)
        if found.returncode:
            return []
        heads.append(found.stdout.strip())
    return heads


def select(repo, argv):
    """proof-for.sh's commands for one selection, or (None, rc) when it refuses."""
    result = subprocess.run(["bash", PROOF_FOR, "--quiet", *argv], cwd=repo.top, env=repo.env,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        return None, result.returncode
    return [line.strip() for line in result.stdout.splitlines() if line.strip()], 0


def land_check(repo, what, staged, range_argv):
    """Run the suites proof-for.sh assigns plus the lint on the working tree, which the
    caller has established IS the tree being landed. Returns 0 and writes the receipt when
    they pass."""
    started = time.monotonic()
    for need in (PROOF_FOR, PROOF_RUN, LINT):
        if not (repo.top / need).is_file():
            banner(f"{what.upper()} REFUSED: cannot select the checks", [f"{need} is not in this tree."])
            return 1
    commands = []
    if range_argv:
        found, rc = select(repo, range_argv)
        if found is None:
            return refuse_selection(what, rc)
        commands += found
        covered = set(git("diff", "--name-only", "--no-renames", *range_argv, env=repo.env, cwd=repo.top).splitlines())
        extra = [p for p in staged if p not in covered]
    else:
        extra = list(staged)
    if extra:
        found, rc = select(repo, ["--paths", ",".join(extra)])
        if found is None:
            return refuse_selection(what, rc)
        commands += [c for c in found if c not in commands]
    if not any("lint.test.sh" in c for c in commands):
        commands.append("cd richos/app && bash scripts/lint.sh --all")
    say(f"autocheck: {what}: {len(commands)} check command(s) selected by proof-for.sh, run by proof-run.py:")
    for c in commands:
        say("    " + c)
    with tempfile.NamedTemporaryFile("w", prefix="autocheck-land-", suffix=".txt", delete=False) as f:
        f.write("\n".join(commands) + "\n")
        plan = f.name
    summary_path = plan[:-len(".txt")] + "-summary.json"
    try:
        result = repo.run(["python3", PROOF_RUN, "--commands", plan, "--summary-out", summary_path])
        not_run, why_not = accepted_not_run(result.returncode, summary_path)
    finally:
        os.unlink(plan)
        if os.path.exists(summary_path):
            os.unlink(summary_path)
    seconds = time.monotonic() - started
    if result.returncode and not_run is None:
        banner(f"{what.upper()} REFUSED: a check it owns did not pass", [
            "proof-run.py's summary above names the check, its state and its log.",
            *([why_not] if why_not else []),
            "Nothing was committed: fix the branch and land it again.",
            "git's --no-verify skips this, and every skip is recorded in the lead's escalation ledger.",
        ])
        return 1
    tree = repo.index_tree()
    repo.write_land_receipt(tree, dict(what=what, commands=commands, seconds=round(seconds, 1), not_run=not_run or []))
    if not_run:
        names = ", ".join(f"{row['check']} ({row['why']})" for row in not_run)
        banner(f"{what.upper()} ALLOWED WITH {len(not_run)} CHECK(S) NOT RUN, WHICH IS NOT A PASS", [
            f"NOT RUN: {names}.",
            "Every other selected check ran and passed. These need a screen, and a land never puts",
            "anything on this Mac's screen (--no-host-screen). The receipt records them as NOT RUN,",
            "never as passed, and `nightly-local.py publish` refuses a build of this commit until",
            "a gui-boot proof taken against it exists (--gui-proof). See autocheck/README.md.",
        ])
        say(f"autocheck: {what}: passed with {len(not_run)} NOT RUN (no screen): {names}; "
            f"{seconds:.1f}s; receipt for tree {tree[:12]}")
        return 0
    say(f"autocheck: {what}: every selected check passed in {seconds:.1f}s; receipt for tree {tree[:12]}")
    return 0


# The one NOT RUN a land accepts: a suite that needs a screen, under --no-host-screen with no
# test-VM guest named. Anything else that did not run (a declared host gap, a suite skipped as
# unchanged) did not answer for this change and refuses the land. Reasoning: README.md.
LAND_ACCEPTS_NOT_RUN = {"no-screen"}


def accepted_not_run(rc, summary_path):
    """([{check, why, suites}], None) when proof-run exited 3 and every check it did not pass is
    NOT RUN for a reason the land accepts; (None, reason) otherwise. Exit 0 is ([], None)."""
    if rc == 0:
        return [], None
    if rc != 3:
        return None, None
    try:
        with open(summary_path) as stream:
            checks = json.load(stream)["checks"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return None, f"proof-run.py exited 3 (NOT RUN) and its summary is unreadable ({exc})."
    idle, other = [], []
    for row in checks:
        if row.get("result") == "passed":
            continue
        info = row.get("not_run") or {}
        if row.get("result") == "not-run" and info.get("why") in LAND_ACCEPTS_NOT_RUN:
            idle.append({"check": row["check"], "why": info["why"], "suites": info.get("suites", [])})
        else:
            other.append(f"{row.get('check')} ({row.get('result')}{', ' + info['why'] if info.get('why') else ''})")
    if other or not idle:
        return None, ("NOT RUN is not a pass. A land accepts it only for a suite that needs a screen; "
                      "these did not answer for this change: " + (", ".join(other) or "none named") + ".")
    return idle, None


def refuse_selection(what, rc):
    reason = {1: "a changed code path is covered by no suite (UNCOVERED above)",
              3: "a commit touching richos/mobile/ has not answered the battery question (CEO ruling §81)"}.get(
        rc, f"proof-for.sh could not map the change (exit {rc})")
    banner(f"{what.upper()} REFUSED: {reason}", ["proof-for.sh's own explanation is printed above."])
    return 1


def land_from_index(repo, what):
    """pre-commit or pre-merge-commit on main: the index is the tree being landed."""
    dirty = git("diff", "--quiet", check=False)
    if dirty.returncode:
        banner(f"{what.upper()} REFUSED: the working tree differs from what is being committed", [
            "The land checks run the suites on the working tree, so it must be exactly the tree",
            "that main will point at. Stage or discard the difference (git diff) and try again.",
        ])
        return 1
    staged = [p for p in git("diff", "--cached", "--name-only", "--no-renames").splitlines() if p]
    heads = merge_heads(repo)
    range_argv = [f"HEAD..{heads[0]}"] if len(heads) == 1 else []
    return land_check(repo, what, staged, range_argv)


def pre_push(repo, stdin_text):
    for line in stdin_text.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        _local_ref, local_sha, remote_ref, remote_sha = parts
        if remote_ref != f"refs/heads/{LAND_BRANCH}" or local_sha == ZERO:
            continue
        tree = repo.head_tree(local_sha)
        if repo.land_receipt(tree).exists():
            continue
        say(f"autocheck: push: {LAND_BRANCH} at {local_sha[:12]} has no land receipt "
            "(a fast-forward, a cherry-pick or a --no-verify merge); running the land checks now")
        head = git("rev-parse", "HEAD", cwd=repo.top)
        status = git("status", "--porcelain", "--untracked-files=no", env=repo.env, cwd=repo.top)
        if repo.branch != LAND_BRANCH or head != local_sha or status:
            banner("PUSH REFUSED: main's tip was never checked", [
                f"{local_sha[:12]} has no land receipt, and this checkout is not at that commit",
                "with a clean tree, so the checks cannot run here. Push from the main checkout.",
            ])
            return 1
        base = remote_sha if remote_sha != ZERO else git("rev-list", "--max-parents=0", local_sha, cwd=repo.top).split()[0]
        if land_check(repo, "push", [], [f"{base}..{local_sha}"]):
            return 1
    return 0


# ---------------------------------------------------------------------------------------
# After the fact: what --no-verify skipped is recorded where the lead sees it
# ---------------------------------------------------------------------------------------

def record_skip(repo, title, question):
    repo.state.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(repo.state / "bypass.log", "a") as log:
        log.write(f"{stamp}\t{repo.top}\t{repo.branch or '(detached)'}\t{title}\n")
    local = repo.top / ENGINE_ESCALATE
    tool = local if local.is_file() else Path.home() / ".claude/richos-engine/scripts/escalate.sh"
    fields = dict(title=title, state="work-complete", question=question,
                  tried="The automatic commit and land checks (richos/app/scripts/autocheck) did not run for this change.",
                  meanwhile="The commit exists; the land check will still run if it is merged into main.")
    with tempfile.NamedTemporaryFile("w", prefix="autocheck-skip-", suffix=".json", delete=False) as f:
        json.dump(fields, f)
        path = f.name
    try:
        result = subprocess.run(["bash", str(tool), "raise", "--fields", path, "--worktree", str(repo.top), "--no-record"],
                                cwd=repo.top, env=repo.env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    finally:
        os.unlink(path)
    if result.returncode:
        banner("AUTOCHECK SKIP NOT DELIVERED to the escalation ledger", [
            title, f"{tool} exited {result.returncode}:", *(result.stdout + result.stderr).strip().splitlines()[-6:],
            f"It is in {repo.state / 'bypass.log'}.",
        ])
    else:
        banner("AUTOCHECK SKIPPED, RECORDED", [title, "Raised in the lead's escalation ledger."])


SELF = "richos/app/scripts/autocheck/autocheck.py"


def existed_before(repo, revs):
    """Did the check exist when git would have run it? The commit that introduces it (or a
    branch that has never seen it) skipped nothing and is not recorded."""
    if repo.branch != LAND_BRANCH:
        revs = [*revs, f"refs/heads/{LAND_BRANCH}"]
    return any(git("cat-file", "-e", f"{rev}:{SELF}", check=False, cwd=repo.top).returncode == 0 for rev in revs)


def post_commit(repo):
    head = git("rev-parse", "HEAD", cwd=repo.top)
    tree = repo.head_tree()
    action = os.environ.get("GIT_REFLOG_ACTION", "")
    if not existed_before(repo, ["HEAD^1"]):
        return 0
    if repo.branch == LAND_BRANCH:
        if not repo.land_receipt(tree).exists():
            how = action or "git commit --no-verify"
            record_skip(repo, f"main moved to {head[:12]} without the land checks ({how})",
                        f"Was landing {head[:12]} on main without its suites deliberate? The next push of main runs them.")
        return 0
    marker = repo.marker()
    verified = marker.read_text().strip() if marker.exists() else ""
    if marker.exists():
        marker.unlink()
    if verified == tree:
        return 0
    replaying = any(git_path(repo, name).exists() for name in
                    ("CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"))
    if replaying or (action and not action.startswith("commit")):
        return 0  # a rebase, cherry-pick, revert or am replays commits; the land check covers them
    record_skip(repo, f"commit {head[:12]} on {repo.branch or 'a detached HEAD'} skipped the automatic checks (--no-verify)",
                f"Was skipping the lint on {head[:12]} deliberate? Its land will run the full checks.")
    return 0


def made_a_merge_commit(repo, parents):
    """Did THIS merge write a new merge commit, or move HEAD to a commit that already existed?

    Two parents on the new HEAD is not the answer. On 2026-09-29 a branch fast-forwarded onto
    main's tip 5ddcce1c, which is itself a land merge with two parents; no pre-merge-commit
    ran (a fast-forward writes no commit, so there is nothing to check), and this hook
    reported that as a `--no-verify` skip that never happened. A merge commit written here
    always has the pre-merge HEAD as its first parent, and git's own reflog says
    `Fast-forward` when it moved HEAD without writing one: both must say "a new commit"."""
    if len(parents) < 2:
        return False
    orig = git("rev-parse", "-q", "--verify", "ORIG_HEAD", check=False, cwd=repo.top).stdout.strip()
    if orig and parents[0] != orig:
        return False
    subject = git("reflog", "-1", "--format=%gs", "HEAD", check=False, cwd=repo.top).stdout.strip()
    return not subject.endswith("Fast-forward")


def post_merge(repo, squash):
    if squash == "1":
        return 0
    head = git("rev-parse", "HEAD", cwd=repo.top)
    tree = repo.head_tree()
    parents = git("rev-list", "--parents", "-n", "1", "HEAD", cwd=repo.top).split()[1:]
    if not existed_before(repo, ["ORIG_HEAD", *parents]):
        return 0
    merged = made_a_merge_commit(repo, parents)
    if repo.branch == LAND_BRANCH:
        if not repo.land_receipt(tree).exists():
            how = "git merge --no-verify" if merged else "a fast-forward"
            record_skip(repo, f"main moved to {head[:12]} without the land checks ({how})",
                        f"Was landing {head[:12]} on main without its suites deliberate? The next push of main runs them.")
        return 0
    marker = repo.marker()
    verified = marker.read_text().strip() if marker.exists() else ""
    if marker.exists():
        marker.unlink()
    if merged and verified != tree:
        record_skip(repo, f"merge {head[:12]} on {repo.branch or 'a detached HEAD'} skipped the automatic checks (--no-verify)",
                    f"Was skipping the lint on {head[:12]} deliberate? Its land will run the full checks.")
    return 0


# ---------------------------------------------------------------------------------------

def main(argv):
    hook = argv[0] if argv else ""
    if hook not in ("pre-commit", "pre-merge-commit", "post-commit", "post-merge", "pre-push"):
        return 0
    stdin_text = sys.stdin.read() if hook == "pre-push" else ""
    repo = Repo()
    if inside_own_check(str(repo.common)):
        say(f"autocheck: {hook}: inside an automatic check of this repository (a suite's own commit); not re-entered")
        return 0
    if hook in ("pre-commit", "pre-merge-commit"):
        # A terminated check unwinds like an interrupted one, so StagedOnly puts set-aside work
        # back (a KeyboardInterrupt already does). Only SIGKILL leaves it in ASIDE, and the next
        # commit check then refuses and says where it is.
        for number in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        if hook == "pre-commit":
            if repo.branch == LAND_BRANCH:
                return land_from_index(repo, "commit to main")
            rc = commit_check(repo, "commit")
        elif hook == "pre-merge-commit":
            if repo.branch == LAND_BRANCH:
                return land_from_index(repo, "merge into main")
            rc = commit_check(repo, "merge")
        elif hook == "post-commit":
            return post_commit(repo)
        elif hook == "post-merge":
            return post_merge(repo, argv[1] if len(argv) > 1 else "0")
        else:
            return pre_push(repo, stdin_text)
        if rc == 0:
            repo.marker().write_text(repo.index_tree() + "\n")
        return rc
    except (RuntimeError, OSError) as exc:
        if hook.startswith("post-"):
            say(f"autocheck: {hook} could not complete its record: {exc}")
            return 0
        banner(f"{hook.upper()} REFUSED: the automatic check could not run", [str(exc)])
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
