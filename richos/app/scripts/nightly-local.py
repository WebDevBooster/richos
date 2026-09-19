#!/usr/bin/env python3
"""Manually check, build, publish or release a nightly using this Mac's own signing keys.

Nothing installs a job, watches main or runs on a schedule. `release` builds and
publishes a nightly in one motion. `build` stops at a signed, notarized,
engine-pinned candidate for QA to walk; only an explicit later `publish --run
<run-id>` makes that candidate's release installable and moves the update
channel. `candidate --run <run-id>` prints what a walker needs to open it.
Only `release` and `publish` may publish. Keys remain in the local
Keychain/private files.
"""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
REPO = "WebDevBooster/richos"
SCRIPTS = Path("richos/app/scripts")

# THE ONLY DECLARED HOST GAP OF THIS BUILD. `run-tests.sh` discovers every *.test.sh beside
# it from disk and runs each with no arguments; a suite that answers "this host cannot
# answer" (exit 2) is tolerated ONLY when its caller names it here WITH a reason, is RED
# when undeclared, and is RED AGAIN on the day the suite starts answering — so this is an
# allowance that cannot outlive its reason (run-tests.sh:20-92). Exit 2 is never read as a
# skip anywhere; this is the whole of the tolerance.
#
# It is written HERE, in the file, rather than taken from the environment on purpose:
# local_environment() drops RUN_TESTS_DECLARED_GAPS out of the operator's shell (see the
# pop below) so a stray export can never declare a gap the build's own source does not.
DECLARED_GAPS = (
    "front-door.test.sh: this suite drives the SHIPPED window — it needs a built RichOS.app, "
    "which THIS build has not produced yet at the gate stage, and a person's unlocked screen to "
    "put it on (its own P1/P2 refuse a sleeping or locked one). There is no app for it to drive "
    "on a build host, so it reports the gap and launches nothing. It is run by hand, or from a "
    "walk, against a published release: scripts/front-door.test.sh --release <release dir>. "
    "Measured on this Mac, 2026-09-18: a bare invocation exits 2 in nine lines and no process."
)

# WHAT THE LAND ALREADY PROVED, and therefore the one gate a candidate build may be told to
# skip. Rich runs these at every land, from the main checkout, on the exact commit that
# then becomes `main` -- which is the commit this build fetches:
#
#     cargo test -p richos-core
#     cargo test --bin richos-tauri
#     the sharded ui suite
#
# `--checks-done-at-land <sha>` drops `gates/core-tests` when the sha it is handed is the
# sha this run actually fetched, and REFUSES when it is not. A flag that trusted its own
# argument would let a stale sha wave a different tree's tests through, which is worse than
# having no flag: the skip has to be unable to lie, not merely documented as honest.
#
# Nothing else in gates() is skippable, because nothing at the land runs it.
# `richos-user-update` is the updater's own crate; `run-tests.sh` is the packaging,
# signing, updater and release-chain suites; `named-persons.sh --tree` is the privacy sweep
# over the tree that is about to be published. Those are exactly the invariants a land does
# NOT check, so they stay on the candidate path.
#
# The default is unchanged. When the skip is taken it is written into the run log and into
# `build-info.json` (through the plan, which nightly.py copies into the candidate's
# provenance), so a candidate can never quietly claim a gate it did not run.
LAND_PROVEN_GATE = "gates/core-tests"

# WHAT `--no-host-screen` IS FOR, in the CEO's words, 2026-09-19:
#
#     "So, every engineer will keep opening the app making me unable to do anything here
#      or WHAT???"
#
# `gui-boot.test.sh` boots the real app on the real screen for ~162 s of every build
# (measured, run 20260919T180454Z-ac11d13e), and on a Mac somebody is working on that is
# not a test, it is an interruption. `--no-host-screen` hands `run-tests.sh` the flag that
# holds back every suite that boots the shipped binary, and the candidate is built,
# notarized and walkable without one pixel reaching this machine.
#
# THE COST IS REAL AND IT IS NOT HIDDEN. Such a candidate carries no gui-boot result, so
# `publish` REFUSES it until `--gui-proof <path>` names one taken against the same commit
# (`scripts/gui-proof-in-vm.sh` produces that file from the candidate's own bundle, inside
# a guest, with nothing on this screen). A mode that quietly published an unproven boot
# would be worse than the interruption it saves.
#
# IT IS ACCEPTED FOR `build` AND NOT FOR `release`. `release` is build-and-publish in one
# motion with no `publish` step to refuse anything, so the one command that can make a
# build installable always runs the whole gate. The screenless path is build -> walk ->
# publish --gui-proof, which is the documented flow anyway.
NO_HOST_SCREEN_COMMANDS = ("build",)

# `run-tests.sh` writes this beside the plan; its contents travel into the candidate's
# `build-info.json`, so a candidate can never quietly claim a suite it did not run.
SUITE_RESULTS = "script-suites.json"

# The inside of the one long `nightly.py build` step, matched IN ORDER against the lines
# its children stream past TimestampedLog, so the split is readable without coupling this
# script to a child's internals beyond these strings.
#
# IN ORDER is the protection that does the work: the first marker gates every later one,
# so a pattern cannot fire early unless the one ahead of it already has. Measured against
# the real 3,158-line log of run 20260919T180454Z-ac11d13e, NONE of the eleven patterns
# matches any of the 2,727 lines before the build step -- so arming the matcher for the
# duration of that step (phase(), below) changes nothing today, and this comment used to
# claim a collision it does not have. It is kept as the second condition because the
# suites' whole job is to drive the scripts these markers come from:
# `make-engine-asset.test.sh` and `make-release.test.sh` run `make-engine-asset.sh` and
# `make-release.sh`. The day one of them stops shimming a banner, the first marker fires a
# thousand lines early and every segment after it is wrong. It costs one boolean.
#
# A marker that never appears is reported as "not observed" rather than folded into the
# segment beside it, because a silently merged boundary makes one phase look expensive and
# hides another entirely.
BUILD_MILESTONES = (
    ("build/engine-asset", r"^building the engine asset for "),
    ("build/engine-asset-recheck", r"^=== --check: building a second time"),
    ("build/engine-member-audit", r"^=== every member accounted for"),
    ("build/engine-release-create", r"^https://github\.com/\S+/releases/tag/"),
    ("build/engine-verify-download", r"^fetching the PUBLISHED asset"),
    ("build/app-preflight", r"^building RichOS \S+ for "),
    ("build/app-compile", r"^building \(release\) with RICHOS_REQUIRE_REAL_ICONS"),
    ("build/app-bundle-and-sign", r"^\s*Finished `release` profile"),
    ("build/app-notarize", r"^\s*submitting to Apple's notary service"),
    ("build/app-staple-and-verify", r'^\s*\{"status":"Accepted"'),
    ("build/app-archive", r"^OK: RichOS\.app is bundled,"),
)


def stamp(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("[%Y-%m-%dT%H:%M:%S.") \
        + f"{int(epoch % 1 * 1000):03d}Z]"


class TimestampedLog:
    """The run log, every line of it stamped with UTC wall clock as it is written.

    A log that says WHAT happened but never WHEN cannot answer where a build's twenty
    minutes went. On 2026-09-19 the only available answer was the mtimes of the staging
    directory, which stop at four coarse boundaries and say nothing at all about the eight
    and a half minutes of gates that run before the first of those files is written.

    Children are handed the write end of a pipe (via `fileno()`, so no call site changes)
    rather than the file itself, and one reader thread stamps each line and writes it
    through. Nothing any child prints has to change, now or ever, for its phase to become
    timeable -- which is the whole point of putting this here instead of threading a timer
    through nightly.py, make-release.sh and package-app.sh, none of which this script even
    supplies (they are read from the FETCHED tree, not from this checkout).

    Undecodable bytes are replaced rather than raised: a reader thread that dies takes the
    log with it and leaves the build writing into a full pipe until it blocks forever.
    """

    SENTINEL = "richos-nightly-log-sync-"

    def __init__(self, path, milestones=()):
        self.file = path.open("w")
        read_fd, self._write_fd = os.pipe()
        self._reader = os.fdopen(read_fd, "rb")
        self._milestones = list(milestones)
        self._next = 0
        self._armed = False
        self._awaited = None
        self._lock = threading.Lock()
        self._synced = threading.Event()
        self.seen = []
        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()

    def _pump(self):
        for raw in self._reader:
            now = time.time()
            line = raw.decode("utf-8", "replace").rstrip("\n")
            with self._lock:
                if line == self._awaited:
                    self._synced.set()
                    continue
                if self._armed and self._next < len(self._milestones):
                    name, pattern = self._milestones[self._next]
                    if re.search(pattern, line):
                        self.seen.append((name, now))
                        self._next += 1
            self.file.write(f"{stamp(now)} {line}\n")
        self.file.flush()

    def fileno(self):
        """Every existing `stdout=self.log` / `stderr=self.log` call site keeps working."""
        return self._write_fd

    def sync(self):
        """Block until everything written so far has been read by the pump thread.

        The pipe is asynchronous, so flipping the matcher off the instant a child exits
        would race that child's last lines: they are already in the pipe and not yet
        matched, and the milestone they carry would be lost. A sentinel pushed through the
        same pipe is the only ordering guarantee available, because the pump reads in
        order -- when the sentinel comes back, everything ahead of it has been seen.
        """
        token = self.SENTINEL + uuid.uuid4().hex
        with self._lock:
            self._awaited = token
            self._synced.clear()
        os.write(self._write_fd, (token + "\n").encode())
        self._synced.wait(timeout=30)
        with self._lock:
            self._awaited = None

    def arm(self, armed):
        self.sync()
        with self._lock:
            self._armed = armed

    def write(self, text):
        """This script's own lines go down the same pipe, so ordering is one thread's.

        Only ever called at a phase boundary, when no child holds the write end, so a line
        longer than PIPE_BUF cannot interleave with a child's output.
        """
        os.write(self._write_fd, text.encode("utf-8", "replace"))

    def close(self):
        os.close(self._write_fd)
        self._thread.join(timeout=30)
        self._reader.close()
        self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
        return False


def private_file(path):
    path = Path(path).expanduser().resolve(strict=True)
    mode = path.stat()
    if not path.is_file() or mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) & 0o077:
        raise ValueError(f"expected an owner-private file: {path}")
    return path


def notary_environment(path):
    """Parse assignments as data. Never source a shell file or execute its values."""
    allowed = {"RICHOS_NOTARY_KEY", "RICHOS_NOTARY_KEY_ID", "RICHOS_NOTARY_ISSUER",
               "RICHOS_NOTARY_PROFILE"}
    result = {}
    for line in private_file(path).read_text().splitlines():
        tokens = shlex.split(line, comments=True)
        if tokens[:1] == ["export"]:
            tokens = tokens[1:]
        if not tokens:
            continue
        if len(tokens) != 1 or "=" not in tokens[0]:
            raise ValueError("notary.env must contain plain NAME=value assignments")
        name, value = tokens[0].split("=", 1)
        if name not in allowed or any(c in value for c in ('`', '$(', '\n', '\r')):
            raise ValueError("unsupported notary.env assignment")
        if name == "RICHOS_NOTARY_KEY":
            value = value.replace("${HOME}", str(Path.home())).replace("$HOME", str(Path.home()))
            value = str(private_file(value))
        elif "$" in value:
            raise ValueError("variable expansion is not supported for notary credentials")
        result[name] = value
    if not result.get("RICHOS_NOTARY_PROFILE") and not all(result.get(k) for k in
            ("RICHOS_NOTARY_KEY", "RICHOS_NOTARY_KEY_ID", "RICHOS_NOTARY_ISSUER")):
        raise ValueError("notarization credentials are incomplete")
    return result


CREDENTIAL_PREFIXES = ("RICHOS_NOTARY_", "TAURI_SIGNING_", "APPLE_")
CREDENTIAL_NAMES = ("RICHOS_NOTARIZE", "RICHOS_SIGNING_IDENTITY")


def is_credential(name):
    return name.startswith(CREDENTIAL_PREFIXES) or name in CREDENTIAL_NAMES


def split_credentials(env):
    """Remove the signing and notarization variables from `env` and return them.

    Only the steps that actually sign or notarize are given them back. The gates --
    cargo test, the twelve script suites, the privacy sweep -- run without them, and
    that is a correctness rule before it is a secrecy one. On 2026-09-16 the first
    nightly attempt died on four package-app.test.sh cases that refuse when notary
    credentials are absent or half-supplied: the credentials were not absent, because
    this function's predecessor put the operator's real App Store Connect key into
    every subprocess. A suite that can see a credential can also print it into a log
    under ~/.richos-nightly/logs, which is the second reason and the smaller one.
    """
    return {name: env.pop(name) for name in list(env) if is_credential(name)}


IDENTITY_OVERRIDES = ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE",
                      "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE",
                      "EMAIL")


def strip_identity_overrides(env):
    """Remove a shell-exported commit identity from `env` and return it.

    The release commit is authored with this Mac's CONFIGURED git identity. These
    variables override every level of git config, so leaving them in place would let
    a stray `export GIT_AUTHOR_EMAIL=...` author the release as someone else with
    neither the configuration nor this file saying so -- and `git config user.email`
    would still report the configured address. richos-core does the same thing to the
    engine's environment (crates/richos-core/src/engine_profile.rs:198-200).
    """
    return {name: env.pop(name) for name in IDENTITY_OVERRIDES if name in env}


def local_environment(run_id=None):
    """Return (environment, credentials). Nothing merges them but the signing steps.

    `run_id`, when given, becomes this process's own RICHOS_NIGHTLY_RUN_ID instead of
    a freshly generated one -- used only so `build` can be told to resume a specific
    id; `publish`/`candidate` never pass one, since they act on an EXISTING build's
    run id (given separately, as `--run`) rather than minting their own.
    """
    env = os.environ.copy()
    # Explicit PATH also works from a fresh terminal, without an interactive shell.
    env["PATH"] = f"{Path.home()}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for key in ("RICHOS_EXTRA_TAURI_CONFIG", "TAURI_CONFIG", "CARGO_TARGET_DIR",
                "RUN_TESTS_DECLARED_GAPS"):
        env.pop(key, None)
    strip_identity_overrides(env)
    # Whatever the operator's shell exported leaves the gate environment here, not
    # only what notary.env supplies below.
    credentials = split_credentials(env)
    credentials.pop("TAURI_SIGNING_PRIVATE_KEY", None)  # The key's literal bytes: the path form is used.
    credentials.update(notary_environment(Path.home() / ".richos-signing/notary.env"))
    credentials["TAURI_SIGNING_PRIVATE_KEY_PATH"] = str(private_file(
        credentials.get("TAURI_SIGNING_PRIVATE_KEY_PATH", Path.home() / ".richos-signing/richos-updater.key")))
    credentials["TAURI_SIGNING_PRIVATE_KEY_PASSWORD"] = credentials.get("TAURI_SIGNING_PRIVATE_KEY_PASSWORD", "")
    # Not a credential: the privacy deny-list that engine/scripts/lib/named-persons.py
    # reads (line 297) for the `named-persons.sh --tree` gate. It stays with the gates.
    env["RICHOS_NAMED_PERSONS_FILE"] = str(private_file(
        env.get("RICHOS_NAMED_PERSONS_FILE", Path.home() / ".richos-privacy/named-persons")))
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["CARGO_PROFILE_DEV_DEBUG"] = "0"
    env["CARGO_PROFILE_TEST_DEBUG"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
    env["RICHOS_NIGHTLY_RUN_ID"] = run_id or (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
    return env, credentials


@contextmanager
def exclusive(state):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if state.is_symlink() or state.stat().st_uid != os.getuid():
        raise ValueError("nightly state must be owned by the current user")
    state.chmod(0o700)
    with (state / "release.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("another local nightly command is running") from error
        yield


class Runner:
    def __init__(self, repo, state, env, log, credentials=None):
        self.repo, self.state, self.env, self.log = repo, state, env, log
        # Merged in only where `credentials=True` says a step signs or notarizes.
        self.credentials = dict(credentials or {})
        self.source = state / "source"
        self.timings = []
        self.skipped = {}
        self.started = time.time()

    def announce(self, text):
        """Say it on the terminal AND in the run log, so neither has to be read beside
        the other to know what this run did."""
        print(text, flush=True)
        self.log.write(text + "\n")

    def watch_child_milestones(self, armed):
        """Milestone matching belongs to the log, and only the `build` phase has any.

        A plain writable stream -- which is what the tests hand the Runner -- has no
        matcher, so there is nothing to arm and nothing to fail about.
        """
        arm = getattr(self.log, "arm", None)
        if arm:
            arm(armed)

    @contextmanager
    def phase(self, name):
        """One named, wall-clocked step. Nested phases are named `parent/child`."""
        self.log.write(f"=== phase {name} begins ===\n")
        self.watch_child_milestones(name == "build")
        start = time.time()
        try:
            yield
        finally:
            end = time.time()
            self.watch_child_milestones(False)
            self.timings.append((name, start, end))
            self.log.write(f"=== phase {name} ends: {end - start:.1f}s ===\n")

    def skip(self, name, reason):
        self.skipped[name] = reason
        self.timings.append((name, None, None))
        self.announce(f"SKIPPED {name}: {reason}")

    def segments(self):
        """Every phase as (name, seconds), with the `build` step split by its milestones.

        The build step is one opaque subprocess from this script's side, so its interior
        comes from the milestones TimestampedLog matched while it ran. The leading stretch
        before the first milestone is named rather than dropped, and a milestone that was
        never seen is reported as such -- an unobserved boundary must not quietly inflate
        the segment next to it.
        """
        rows, seen = [], list(self.log.seen) if hasattr(self.log, "seen") else []
        observed = {name for name, _ in seen}
        for name, start, end in self.timings:
            if start is None:
                rows.append((name, None))
                continue
            if name != "build" or not seen:
                rows.append((name, end - start))
                continue
            bounds = [("build/tag-and-prepare", start)] + seen + [(None, end)]
            for (label, at), (_, nxt) in zip(bounds, bounds[1:]):
                rows.append((label, nxt - at))
            for label, _ in BUILD_MILESTONES:
                if label not in observed:
                    rows.append((label, None))
        return rows

    def summary(self):
        rows = self.segments()
        width = max([len(name) for name, _ in rows] + [len("total")])
        self.announce("")
        self.announce(f"phase timings for run {self.env.get('RICHOS_NIGHTLY_RUN_ID', 'manual')}:")
        for name, seconds in rows:
            if seconds is None:
                note = self.skipped.get(name, "not observed in this run's log")
                self.announce(f"  {name.ljust(width)} : -       ({note})")
            else:
                self.announce(f"  {name.ljust(width)} : {seconds:7.1f}s")
        self.announce(f"  {'total'.ljust(width)} : {time.time() - self.started:7.1f}s")

    def command(self, *args, cwd=None, capture=False, timeout=None, credentials=False,
                env_extra=None):
        env = {**self.env, **self.credentials} if credentials else self.env
        # A value this build states about ONE step, never a channel for the operator's
        # shell: everything in `env_extra` is written literally at the call site.
        if env_extra:
            env = {**env, **env_extra}
        try:
            result = subprocess.run([str(a) for a in args], cwd=cwd or self.source,
                                    env=env, stdin=subprocess.DEVNULL, text=True,
                                    stdout=subprocess.PIPE if capture else self.log,
                                    stderr=self.log, timeout=timeout)
        except subprocess.TimeoutExpired:
            # TimeoutExpired's default message includes argv, potentially a password.
            raise RuntimeError(f"{Path(str(args[0])).name} timed out; see the run log") from None
        if result.returncode:
            # Do not echo argv: signing commands can carry a password.
            raise RuntimeError(f"{Path(str(args[0])).name} failed (exit {result.returncode}); see the run log")
        return result.stdout.strip() if capture else None

    def checkout(self):
        self.command("git", "fetch", "origin", "main", cwd=self.repo, timeout=120)
        sha = self.command("git", "rev-parse", "FETCH_HEAD", cwd=self.repo, capture=True)
        if self.source.exists():
            common = self.command("git", "rev-parse", "--path-format=absolute", "--git-common-dir", capture=True)
            expected = self.command("git", "rev-parse", "--path-format=absolute", "--git-common-dir", cwd=self.repo, capture=True)
            if common != expected or Path(self.command("git", "rev-parse", "--show-toplevel", capture=True)) != self.source:
                raise ValueError("nightly source is not the dedicated worktree for this repository")
            if self.command("git", "status", "--porcelain", capture=True):
                raise ValueError("nightly worktree has changes; inspect it before continuing")
            self.command("git", "checkout", "--detach", sha)
        else:
            self.command("git", "worktree", "add", "--detach", self.source, sha, cwd=self.repo)
        return sha

    def identity(self):
        """The identity the release commit will carry, resolved the way git resolves it.

        Not read from `git config`: GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL in the
        environment beat every config level and config cannot see them, so only
        `git var` answers what the commit will record. `user.useConfigOnly=true`
        removes git's hostname fallback, which is otherwise silent -- git 2.52.0
        happily builds a commit authored `user@host.home` and the machine's push
        guard then refuses the whole release.
        """
        idents = {}
        for var in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"):
            result = subprocess.run(["git", "-c", "user.useConfigOnly=true", "var", var],
                                    cwd=self.source, env=self.env, stdin=subprocess.DEVNULL,
                                    text=True, capture_output=True, timeout=30)
            if result.returncode or "<" not in result.stdout:
                raise ValueError(
                    "this Mac has no configured git identity, so the release commit could "
                    "not be attributed to you: set user.name and user.email (git config "
                    "--global user.name '<your name>', git config --global user.email "
                    "'<your email>') and run check again")
            idents[var] = result.stdout.strip().rsplit(" ", 2)[0]
        if idents["GIT_AUTHOR_IDENT"] != idents["GIT_COMMITTER_IDENT"]:
            raise ValueError(f"author {idents['GIT_AUTHOR_IDENT']} and committer "
                             f"{idents['GIT_COMMITTER_IDENT']} identities differ; the "
                             "release commit must carry one identity")
        return idents["GIT_AUTHOR_IDENT"]

    def preflight(self):
        # First, and before any network call: it costs milliseconds and it is what the
        # 2026-09-17 attempt discovered after passing every gate.
        print(f"Release commits will be authored as {self.identity()}.", flush=True)
        print("Checking GitHub access, local signing and notarization credentials...", flush=True)
        if self.command("gh", "api", f"repos/{REPO}", "--jq", ".permissions.push", capture=True, timeout=60) != "true":
            raise ValueError("GitHub credentials cannot publish to this repository")
        # Until 2026-09-17 this asserted the OPPOSITE: that the `main-only` ruleset had
        # been given an exception for `refs/heads/nightly-channel`, and it refused to
        # run without one. That is how a publisher came to require a hole in the rule
        # that keeps every branch but `main` off the public repository. The channel is
        # a release tag now and needs no exception, so the check is inverted: the run
        # is refused while any branch but `main` is exempt. `nightly.py` owns the rule
        # and re-checks it immediately before the channel moves; this is the fail-fast
        # copy, ahead of forty minutes of gates.
        self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "check-rules",
                     timeout=120)
        self.command("cargo", "tauri", "--version", timeout=30)
        if self.credentials.get("RICHOS_NOTARY_PROFILE") and not self.credentials.get("RICHOS_NOTARY_KEY"):
            auth = ["--keychain-profile", self.credentials["RICHOS_NOTARY_PROFILE"]]
        else:
            auth = ["--key", self.credentials["RICHOS_NOTARY_KEY"],
                    "--key-id", self.credentials["RICHOS_NOTARY_KEY_ID"],
                    "--issuer", self.credentials["RICHOS_NOTARY_ISSUER"]]
        self.command("xcrun", "notarytool", "history", *auth, "--output-format", "json",
                     capture=True, timeout=90, credentials=True)
        identities = self.command("security", "find-identity", "-v", "-p", "codesigning", capture=True)
        found = re.findall(r'\b([0-9A-F]{40}) "Developer ID Application:[^"]+"', identities)
        wanted = self.credentials.get("RICHOS_SIGNING_IDENTITY")
        if wanted:
            if wanted not in identities:
                raise ValueError("configured Developer ID identity is unavailable")
        elif len(found) == 1:
            wanted = found[0]
        else:
            raise ValueError("exactly one Developer ID signing identity is required")
        with tempfile.TemporaryDirectory(prefix="richos-nightly-signing-") as tmp:
            probe = Path(tmp) / "probe"
            # Do not copy protected system-file flags or extended attributes.
            shutil.copyfile("/usr/bin/true", probe)
            probe.chmod(0o755)
            self.command("codesign", "--force", "--sign", wanted, "--timestamp", "--options", "runtime",
                         probe, timeout=90, credentials=True)
            self.command("codesign", "--verify", "--strict", probe, timeout=30)
            self.command("cargo", "tauri", "signer", "sign",
                         "-f", self.credentials["TAURI_SIGNING_PRIVATE_KEY_PATH"],
                         "-p", self.credentials["TAURI_SIGNING_PRIVATE_KEY_PASSWORD"],
                         probe, timeout=30, credentials=True)
            # Public key configuration must match the existing local key pair. The
            # release pipeline also verifies the actual artifact signature before publishing.
            public = Path(self.credentials["TAURI_SIGNING_PRIVATE_KEY_PATH"] + ".pub").read_text().strip()
            conf = json.loads((self.source / "richos/app/src-tauri/tauri.conf.json").read_text())
            expected = conf["plugins"]["updater"]["pubkey"].strip()
            if public not in (expected, base64.b64decode(expected).decode().strip()):
                raise ValueError("local updater public key does not match the app")
        print("Local signing and Apple notarization authentication passed.", flush=True)

    def plan(self, force):
        path = self.state / "plan.json"
        self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "plan",
                     *(["--force"] if force else []), "--output", path)
        return path, json.loads(path.read_text())

    def runtime(self, override):
        path = override or self.state / "runtime"
        if not path.exists():
            if override:
                raise ValueError("specified runtime directory does not exist")
            print("Building the pinned public runtimes...", flush=True)
            self.command(sys.executable, self.source / SCRIPTS / "build-runtimes.py", path)
        self.command(sys.executable, self.source / SCRIPTS / "verify-runtime.py", path,
                     self.source / SCRIPTS / "runtime-sources.json")
        self.env["RICHOS_RUNTIME_DIR"] = str(path)

    def gates(self, checks_done_at_land=None, no_host_screen=False, skip_unchanged=False):
        # Deliberately without `credentials=True`: a gate that can see the operator's
        # notary key answers questions the suites ask precisely because the answer
        # should be absent. See split_credentials() and package-app.test.sh section E.
        self.announce("Running core, updater and packaging checks...")
        if checks_done_at_land:
            self.skip(LAND_PROVEN_GATE,
                      f"the land already ran `cargo test -p richos-core` on {checks_done_at_land}, "
                      "which is the commit this run fetched")
        else:
            with self.phase(LAND_PROVEN_GATE):
                self.command("cargo", "test", "--locked", "--manifest-path",
                             "richos/app/Cargo.toml", "-p", "richos-core")
        with self.phase("gates/updater-tests"):
            self.command("cargo", "test", "--locked", "--manifest-path",
                         "richos/app/crates/richos-user-update/Cargo.toml")
        results = self.state / SUITE_RESULTS
        with self.phase("gates/script-suites"):
            # Every one of these is written literally at this call site rather than taken
            # from the operator's shell, for the same reason DECLARED_GAPS is: a stray
            # export must not be able to hold back a suite or skip one.
            extra = {"RUN_TESTS_DECLARED_GAPS": DECLARED_GAPS}
            if skip_unchanged:
                extra["RUN_TESTS_SKIP_UNCHANGED"] = "1"
            args = ["bash", self.source / SCRIPTS / "run-tests.sh",
                    "--results-out", results]
            if no_host_screen:
                args.append("--no-host-screen")
            self.command(*args, env_extra=extra)
        with self.phase("gates/privacy-sweep"):
            self.command("bash", "richos/engine/scripts/named-persons.sh", "--tree",
                         "--repo", self.source)
        try:
            return json.loads(results.read_text())
        except (OSError, ValueError):
            # The suites are what matter and they passed; a missing report is not a reason
            # to throw away a green gate. It IS a reason for `publish` to refuse, which it
            # does: a candidate with no recorded gui-boot result is treated exactly like
            # one that recorded NOT RUN.
            return None

    def run_pointer(self, run_id):
        if not run_id or "/" in run_id or run_id in (".", ".."):
            raise ValueError("a valid --run <run-id> is required")
        return self.state / "runs" / f"{run_id}.json"

    def record_run(self, run_id, out):
        path = self.run_pointer(run_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"out": str(out)}, indent=2) + "\n")

    def load_candidate(self, run_id):
        path = self.run_pointer(run_id)
        if not path.exists():
            raise ValueError(f"no recorded build for run {run_id}; run \"build\" first")
        out = Path(json.loads(path.read_text())["out"])
        candidate = out / "candidate.json"
        if not candidate.exists():
            raise ValueError(f"{out} has no candidate.json; the build for run {run_id} "
                             "did not finish")
        return out, json.loads(candidate.read_text())["info"]

    def print_candidate(self, info, out):
        # This Mac is Apple Silicon only (see main()'s own precondition), so the
        # first-install archive's arch component is always "aarch64" --
        # make-release.sh's own ARCH mapping (arm64|aarch64 -> aarch64).
        bundle_zip = out / f"RichOS-{info['version']}-macos-aarch64.zip"
        scratch = f"/tmp/richos-qa-{info['run_id']}"
        print(f"Candidate {info['tag']} ({info['version']}), source {info['source_commit']}", flush=True)
        print(f"  staged at : {out}", flush=True)
        print(f"  bundle zip: {bundle_zip}", flush=True)
        print("", flush=True)
        print("To walk it: unpack into a scratch HOME so it never touches the operator's own", flush=True)
        print("app data (README.md's activation invariant D), and run it directly rather than", flush=True)
        print("via `open`, so a harness/terminal holds the process (invariant P). Set", flush=True)
        print("RICHOS_ACTIVATION=regular so the window is visible instead of accessory-hidden:", flush=True)
        print("", flush=True)
        print(f"  mkdir -p {scratch} && ditto -x -k '{bundle_zip}' {scratch}", flush=True)
        print(f"  HOME={scratch}/home RICHOS_ACTIVATION=regular \\", flush=True)
        print(f"      '{scratch}/RichOS.app/Contents/MacOS/richos-tauri'", flush=True)
        print("", flush=True)
        print("Nothing here is installed, published, or reachable by an existing install's", flush=True)
        print("auto-updater: the release exists on GitHub only as a prerelease carrying the", flush=True)
        print("engine asset build compiled its pin against; the update channel has not moved.", flush=True)
        print("", flush=True)
        print(f"Publish only on a READY verdict:  nightly-local.py publish --run {info['run_id']}", flush=True)

    @staticmethod
    def gui_boot_state(info):
        """What this candidate recorded for the suite that boots the app: `passed`, `gap`,
        `not-run`, or None when the build recorded nothing either way.

        NONE IS NOT THE SAME AS `not-run`, AND THE FIRST VERSION OF THIS TREATED THEM AS
        ONE. "Silence is never read as a pass" is a fine-sounding rule and it would have
        made every candidate already staged on this Mac unpublishable, because none of them
        carries a field that did not exist when they were built — `nightly-local.test.py`'s
        publish case said so within a minute of the change. Those builds DID run
        gui-boot.test.sh; it was not skippable then. So silence is read for what it is:
        a build from before the field, which ran the suite the only way there was.

        The case that must never be waved through is a build that was TOLD not to use the
        screen and then produced no report, and `no_host_screen` in the plan is what
        distinguishes it — see `require_gui_proof`.
        """
        for suite in (info.get("script_suites") or {}).get("suites", []):
            if suite.get("name") == "gui-boot.test.sh":
                return suite.get("state")
        return None

    @staticmethod
    def read_gui_proof(path):
        """Parse a `--gui-proof` file into its fields, or refuse with a reason.

        Hand-parsed rather than trusted: this file is the ONE thing standing between a
        candidate whose boot was never exercised and a published release, so a malformed
        one is refused loudly instead of being read past.
        """
        try:
            text = Path(path).expanduser().read_text(errors="replace")
        except OSError as error:
            raise ValueError(f"--gui-proof {path} cannot be read: {error}") from None
        head, _, _ = text.partition("\n--- output ---")
        if not head.startswith("richos-gui-proof 1"):
            raise ValueError(
                f"{path} is not a gui-boot proof: it does not begin with `richos-gui-proof 1`. "
                "`run-tests.sh --only gui-boot.test.sh --proof-out <path>` writes one, and "
                "`scripts/gui-proof-in-vm.sh` writes one from a candidate's own bundle.")
        fields = {}
        for line in head.splitlines()[1:]:
            name, sep, value = line.partition("=")
            if sep:
                fields[name.strip()] = value.strip()
        return fields

    def require_gui_proof(self, info, gui_proof):
        """Refuse to publish a candidate whose boot nobody has seen.

        `--no-host-screen` buys a build that never touches this Mac's screen by NOT running
        `gui-boot.test.sh`. That is a trade, and this is the other half of it: the evidence
        has to arrive before anything becomes installable, or the mode is just a way of
        skipping a gate.
        """
        state = self.gui_boot_state(info)
        if state is None and not info.get("no_host_screen"):
            # A candidate from before this field existed. `build` had no way to hold the
            # suite back, so it ran. See gui_boot_state.
            if gui_proof:
                raise ValueError(
                    "this candidate predates the gui-boot record and was built with the suite "
                    "running, so --gui-proof names evidence nothing is waiting for.")
            return None
        if state == "passed":
            if gui_proof:
                raise ValueError(
                    "this candidate ran gui-boot.test.sh during its build and it passed, so "
                    "--gui-proof names evidence nothing is waiting for. Publish without it.")
            return None
        if not gui_proof:
            recorded = state or "nothing at all, from a build that was told --no-host-screen"
            raise ValueError(
                f"this candidate recorded `{recorded}` for gui-boot.test.sh, so no one has "
                "seen the app it is about to publish actually boot.\n"
                "  Take the proof against this exact commit and pass it back:\n"
                f"    richos/app/scripts/gui-proof-in-vm.sh --run {info['run_id']}\n"
                f"    nightly-local.py publish --run {info['run_id']} --gui-proof <the file it names>\n"
                "  Nothing here opens a window on this Mac; the app boots inside a guest.")
        fields = self.read_gui_proof(gui_proof)
        # TWO KINDS OF EVIDENCE, AND THEY ARE NOT THE SAME CLAIM, so they are named
        # differently and both are accepted for what each one is:
        #
        #   gui-boot.test.sh      the suite: a debug binary built from the checkout, held
        #                         to B0-B8 and C1-C5 on a synthetic machine -- engine
        #                         resolution, the plist's shape, the company registry.
        #   shipped-bundle-boot   `gui-proof-in-vm.sh`: THE ARTIFACT THIS RELEASE WILL
        #                         PUBLISH -- signed, notarized, stapled -- started on a
        #                         clean guest with no developer environment, drawing a
        #                         real window. Fewer assertions, truer artifact.
        #
        # A proof that borrowed the other's name would be the most useful lie in the
        # release chain, so neither may.
        accepted_suites = ("gui-boot.test.sh", "shipped-bundle-boot")
        if fields.get("suite") not in accepted_suites:
            raise ValueError(f"--gui-proof names a proof for {fields.get('suite')!r}. "
                             f"Only {' or '.join(accepted_suites)} says whether the app boots.")
        if fields.get("result") != "pass":
            raise ValueError(f"--gui-proof records {fields.get('result')!r}, not a pass. "
                             "A failed boot is not evidence of a working one.")
        # THE SHA IS THE WHOLE POINT, exactly as --checks-done-at-land's is: a proof taken
        # against a different tree proves something about that tree. `build_commit` is the
        # commit the bundle was compiled from (it carries the version bump); `source_commit`
        # is its parent. Either identifies THIS candidate and nothing else.
        accepted = [s for s in (info.get("build_commit"), info.get("source_commit")) if s]
        seen = fields.get("commit", "")
        if not seen or not any(s == seen or s.startswith(seen) for s in accepted):
            raise ValueError(
                f"--gui-proof was taken against {seen or '<no commit>'}, and this candidate is "
                f"{' / '.join(accepted)}. The proof is about a different tree, so it proves "
                "nothing about this one; take it again against this candidate.")
        return fields

    def accept_land_proof(self, sha, source):
        """Return the sha to record, or refuse. Never a bare boolean.

        The flag says "a land already ran this, on THIS source". The only thing that can
        make that true is the sha, so it is compared against the sha this run actually
        fetched -- not against `main`, not against HEAD, and never taken on trust. An
        abbreviation is accepted because Rich passes one by hand, but only at git's own
        minimum unambiguous length, and only as a prefix of the fetched sha.
        """
        if not re.fullmatch(r"[0-9a-f]{7,40}", sha or ""):
            raise ValueError("--checks-done-at-land needs a hex commit sha of at least 7 characters")
        if not source.startswith(sha):
            raise ValueError(
                f"--checks-done-at-land {sha} is not the source this run fetched ({source}). "
                "The land proved a different tree, so its checks prove nothing about this one; "
                "run without the flag.")
        return source

    def perform(self, command, force=False, runtime=None, run_id=None,
                checks_done_at_land=None, no_host_screen=False, gui_proof=None):
        if command == "candidate":
            out, info = self.load_candidate(run_id)
            self.print_candidate(info, out)
            return
        if command == "publish":
            out, info = self.load_candidate(run_id)
            if not self.source.exists():
                raise ValueError(f"{self.source} no longer exists; the dedicated worktree that "
                                 f"built run {run_id} is gone, so it cannot be published from here")
            # BEFORE the network, the upload and the channel move: this is a refusal about
            # what was never checked, and it costs nothing to make it first.
            proof = self.require_gui_proof(info, gui_proof)
            if proof:
                print(f"gui-boot proof accepted: {proof.get('result')} at {proof.get('where')}, "
                      f"commit {proof.get('commit')}, taken {proof.get('at')}", flush=True)
            print(f"Publishing {info['tag']} from run {run_id}...", flush=True)
            # finish() only uploads, verifies and promotes -- no signing identity or
            # notarization credential is needed here, unlike the build step below.
            self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "finish", "--out", out)
            print(f"Published https://github.com/{REPO}/releases/tag/{info['tag']}", flush=True)
            return

        with self.phase("fetch"):
            source = self.checkout()
        with self.phase("plan"):
            plan_path, info = self.plan(force)
        self.announce(f"Source: {source}")
        if checks_done_at_land:
            checks_done_at_land = self.accept_land_proof(checks_done_at_land, source)
        if not info["build"] and command in ("release", "build"):
            print(info["reason"] + "; nothing published.", flush=True)
            return
        with self.phase("preflight"):
            self.preflight()
        if command == "check":
            if runtime or (self.state / "runtime").exists():
                with self.phase("runtime-verify"):
                    self.runtime(runtime)
            print("Preflight passed. No release was triggered or published.", flush=True)
            self.summary()
            return
        if command not in ("release", "build"):
            raise ValueError("only build, release or publish may build or publish")
        with self.phase("runtime-verify"):
            self.runtime(runtime)
        # SKIPPING IS FOR CANDIDATES, NEVER FOR THE COMMAND THAT PUBLISHES. `release` runs
        # every suite every time, whatever a proof file on this host remembers.
        suites = self.gates(checks_done_at_land, no_host_screen=no_host_screen,
                            skip_unchanged=(command == "build"))
        # Capture the UTC date at allocation, even if checks crossed midnight.
        with self.phase("plan-recheck"):
            plan_path, info = self.plan(force)
        if not info["build"]:
            print(info["reason"] + "; nothing published.", flush=True)
            return
        if no_host_screen or isinstance(suites, dict):
            # Into the plan for the same reason the land proof is: nightly.py copies the
            # plan verbatim into build-info.json and the candidate's committed provenance,
            # so which suites ran, which were skipped over unchanged inputs, and which were
            # held back from the screen travel WITH the candidate instead of living in a
            # log on this Mac.
            #
            # `no_host_screen` is recorded EVEN IF the suite report went missing, and that
            # is the whole point of recording it separately: a screenless build with no
            # report is the one shape `publish` must refuse, and it can only tell that
            # shape from an old candidate's silence by this flag.
            info = {**info, "no_host_screen": bool(no_host_screen)}
            if isinstance(suites, dict):
                info["script_suites"] = suites
            plan_path.write_text(json.dumps(info, indent=2) + "\n")
        if checks_done_at_land:
            # Into the plan, because nightly.py copies the plan verbatim into the
            # candidate's `build-info.json` and its committed provenance. A skip recorded
            # only in a log lives on this Mac; a skip recorded here travels with the
            # candidate to whoever walks it.
            info = {**info, "checks_done_at_land": checks_done_at_land,
                    "checks_skipped": [LAND_PROVEN_GATE]}
            plan_path.write_text(json.dumps(info, indent=2) + "\n")
        out = self.state / "releases" / info["tag"]
        if command == "release":
            self.announce(f"Building and publishing {info['tag']}...")
            # The publisher builds, signs, notarizes and signs the updater manifest; it is
            # the one step that reads these variables out of its environment
            # (make-release.sh:359 and its notarize_env at :410).
            with self.phase("build"):
                self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "run",
                             "--plan", plan_path, "--out", out, credentials=True)
            print(f"Published https://github.com/{REPO}/releases/tag/{info['tag']}", flush=True)
            self.summary()
            return
        # command == "build": stop at the signed, notarized, engine-pinned candidate.
        self.announce(f"Building {info['tag']}...")
        with self.phase("build"):
            # The engine asset's reproducibility re-build (~25 s, measured 2026-09-19) may
            # be remembered for a CANDIDATE when the bytes and the build script are both
            # byte-identical to a run that already proved them. Passed for `build` and
            # never for `release`, exactly like skip-when-unchanged above: a proof file on
            # this host may excuse work for a candidate, never for the command that makes
            # a build installable. See make-engine-asset.sh's CHECK_PROOF_DIR note.
            self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "build",
                         "--plan", plan_path, "--out", out, credentials=True,
                         env_extra={"RICHOS_ENGINE_CHECK_PROOF_DIR":
                                    str(self.state / "engine-repro-proofs")})
        candidate_info = json.loads((out / "candidate.json").read_text())["info"]
        self.record_run(self.env["RICHOS_NIGHTLY_RUN_ID"], out)
        self.summary()
        print("", flush=True)
        self.print_candidate(candidate_info, out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "build", "publish", "candidate", "release"])
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".richos-nightly")
    parser.add_argument("--runtime-dir", type=Path, help="existing verified runtime cache")
    parser.add_argument("--force", action="store_true", help="explicitly rebuild a previously released source")
    parser.add_argument("--run", help="an existing build's run id (required for publish/candidate)")
    parser.add_argument("--checks-done-at-land", metavar="SHA",
                        help="skip the one gate a land already ran on this exact commit "
                             "(cargo test -p richos-core); refused unless SHA is the sha "
                             "this run fetches")
    parser.add_argument("--no-host-screen", action="store_true",
                        help="hold back every suite that boots the app on this Mac's screen; "
                             "the candidate is still built and walkable, and publish will "
                             "refuse it until --gui-proof names a boot taken elsewhere")
    parser.add_argument("--gui-proof", metavar="PATH",
                        help="a gui-boot proof taken against this candidate's commit, required "
                             "to publish a candidate built with --no-host-screen")
    args = parser.parse_args()
    if args.command in ("publish", "candidate") and not args.run:
        parser.error(f"{args.command} requires --run <run-id> (see the output of a prior `build`)")
    if args.checks_done_at_land and args.command not in ("build", "release"):
        parser.error("--checks-done-at-land only means anything for build or release")
    if args.no_host_screen and args.command not in NO_HOST_SCREEN_COMMANDS:
        parser.error("--no-host-screen is for `build`. `release` publishes in one motion with "
                     "no publish step to refuse an unproven boot, so it always runs the whole "
                     "gate; the screenless path is build -> walk -> publish --gui-proof.")
    if args.gui_proof and args.command != "publish":
        parser.error("--gui-proof is evidence `publish` demands; it means nothing to any other "
                     "command")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("local nightly releases currently require an Apple Silicon Mac")
    os.umask(0o077)
    state = args.state_dir.expanduser().absolute()
    env, credentials = local_environment(args.run if args.command == "build" else None)
    with exclusive(state):
        logs = state / "logs"
        logs.mkdir(exist_ok=True)
        log_path = logs / (env["RICHOS_NIGHTLY_RUN_ID"] + ".log")
        print(f"Run log: {log_path}", flush=True)
        with TimestampedLog(log_path, BUILD_MILESTONES) as log:
            Runner(args.repo.resolve(), state, env, log, credentials).perform(
                args.command, args.force, args.runtime_dir.resolve() if args.runtime_dir else None,
                args.run, args.checks_done_at_land, args.no_host_screen, args.gui_proof)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"nightly: {error}") from error
