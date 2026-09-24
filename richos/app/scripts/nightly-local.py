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
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

# Gate ceilings include rebuilds, not just reuse of successful receipts. Cargo
# uses fivefold cold/warm headroom rounded up to a minute. The script envelope
# adds cold Cargo runs and the generated-command integration to a full no-reuse
# reference before doubling it. Script/UI ceilings round up to five minutes.
# Measurements and model assumptions are recorded in the private handoff.
# Gates skipped by a land proof do not spawn a command or spend a deadline.
GATE_BUDGETS = {
    "gates/release-smoke": 60,   # One-minute startup floor for fixture-only Python work.
    "gates/core-tests": 300,    # At least 5x the worst cold/warm Cargo sample.
    "gates/updater-tests": 360, # At least 5x its separate workspace's cold/warm sample.
    "gates/script-suites": 1800, # At least 2x the full-execution envelope, without reuse.
    "gates/lint-tauri": 300,    # At least 10x the full-lint sample; headroom beyond the 180s inner cap.
    "gates/workspace-mutants": 1800,  # About 2x its 792 s measured on this Mac, 2026-09-23.
    "gates/ui-suite": 1200,    # At least 2x the fresh-browser four-shard reference.
    "gates/privacy-sweep": 120, # At least 4x a full scan; no receipt-reuse assumption.
}
CLEANUP_TIMEOUT = 30
TERM_GRACE = 15
KILL_GRACE = 2


class CommandCleanupError(RuntimeError):
    """A command did not surrender its owned group before the cleanup deadline."""


def finish_group(process):
    """Stop only the session/group we created, including surviving grandchildren.

    Descendants that deliberately call setsid/setpgid escape this boundary. This
    is process-group ownership, not an OS container or a claim to discover those
    descendants. No process-name lookup is used.
    """
    def exists():
        process.poll()  # Reap the leader before testing its group.
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # macOS can briefly report EPERM while orphaned group members are
            # being reaped. Treat it as present and keep the bounded wait.
            return True

    for sig, grace in ((signal.SIGTERM, TERM_GRACE), (signal.SIGKILL, KILL_GRACE)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        except PermissionError:
            # A group of exiting orphans may briefly reject signals on macOS.
            # The deadline and final presence check still apply.
            pass
        until = time.monotonic() + grace
        while exists() and time.monotonic() < until:
            time.sleep(0.02)
        if not exists():
            break
    try:
        process.wait(timeout=KILL_GRACE)
    except subprocess.TimeoutExpired:
        raise CommandCleanupError(f"owned command group {process.pid} did not exit after bounded cleanup") from None
    if exists():
        raise CommandCleanupError(f"owned command group {process.pid} did not exit after bounded cleanup")


def owned_run(args, *, timeout=None, **kwargs):
    """subprocess.run's result shape with bounded, owned-group cleanup on all exits."""
    library = Path(__file__).resolve().parents[2] / "engine/scripts/lib"
    worker = library / "worker_tokens.py"
    # The worker wrapper owns its command, but does not watch this coordinator.
    # Keep an independent supervisor tied to our identity around the entire
    # admission/worker lifetime, so even SIGKILL here cancels waiting or active work.
    supervisor = library / "proc_tree.py"
    process = subprocess.Popen([sys.executable, str(supervisor), "run", str(os.getpid()), "--",
                                sys.executable, str(worker), "machine", "--", *map(str, args)],
                               start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    finally:
        try:
            finish_group(process)
        finally:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


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
# IT ALSO DROPS `gates/ui-suite`, AND ON A STRICTER CONDITION: the sha has to match AND a
# coverage proof for that sha has to be on this machine, written by the land's own
# `run.js --coverage --proof-out` on a pass. The sha alone is enough for the core tests
# because the land always runs them; the UI suite gets a proof because "the land ran it"
# is a claim about something that may or may not have happened, and a build must not pay
# 378 s for a proof the land already made, nor accept one nobody made. No proof, no skip --
# the suite simply runs, which is the safe direction for a missing file to fail in.
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

# ── The UI suite, and why it is a build gate at all ──────────────────────────────────────
#
# UNTIL NOW IT GATED NOTHING. `app/ui/tests/run.js` holds 55 suites and 863 checks over the
# screens the CEO actually looks at, and no script in `app/scripts/` invoked it -- measured
# at bf1381e0, `grep -n run.js scripts/*.sh scripts/*.py` matched three COMMENTS and no call.
# A build could be signed, notarized and published with every one of those checks red.
#
# WHAT IT COSTS, MEASURED ON THIS MAC (M4, 4 performance cores), 2026-09-20 at bf1381e0:
# 1510 s serially, 557 s over 4 shards before the packing was fixed, 378 s after. Four is
# the shard count because four is the performance-core count; the packer reports the same
# 378 s for all four shards, which is the arithmetic floor for this inventory at this count
# (total/4), and no shard count at all gets under the heaviest single suite, contrast.js at
# 150 s.
UI_TESTS = Path("richos/app/ui/tests")
UI_SUITE_GATE = "gates/ui-suite"
WORKSPACE_MUTANTS_GATE = "gates/workspace-mutants"
UI_SHARDS = 4

# ── Quarantine: the list that keeps test rot from stopping a build ───────────────────────
#
# THE CEO'S QUESTION, 2026-09-19, and it is the right one to hold this against: "Will that
# get me back to that endless fixing of millions of bugs without doing any actual work?"
#
# A gate is worth having only if a red suite means the APP is wrong. When a suite is red
# because its own assertion, fixture or screenshot has drifted, stopping the build buys
# nothing and costs a night. So a named suite here still RUNS, is still reconciled, and is
# still printed in this build's output on every run -- it just does not hold the build.
#
# EVERY ROW CARRIES A FILE, A REASON AND A DATE, because a quarantine is a debt and an
# undated debt is a permanent one. `run.js` prints a row that is no longer needed as a NOTE
# naming the row to delete, so the list cannot rot silently, and prints a row naming a suite
# that no longer exists for the same reason.
#
# IT IS EMPTY, AND THAT IS A MEASUREMENT, NOT AN ASPIRATION. The full inventory was run at
# bf1381e0 on 2026-09-20: 55 of 55 suites ran, 863 checks observed, every suite exited 0 and
# the coverage job reconciled all four shards green. There is nothing to quarantine today.
UI_QUARANTINE = ()

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


# WHAT A GATE MAY SEE FROM THE OPERATOR'S SHELL. AN ALLOWLIST, AND THE INVERSION IS THE
# WHOLE POINT.
#
# This was `os.environ.copy()` minus four names, and four names is a GUESS about which of
# the operator's exports can break a build. The guess has to be re-made, correctly, every
# time anyone adds a variable to any script in the chain -- and on 2026-09-19 it was wrong,
# which is what broke that day's builds. A deny-list is a list of the mistakes somebody has
# already made; an allowlist is a statement of what the work needs, and a variable nobody
# thought about is excluded by construction instead of included by construction.
#
# MEASURED ON THIS MAC, 2026-09-20: a shell here exports 44 names, of which the old form
# passed 40 into every cargo test, every script suite and the privacy sweep -- among them
# CLAUDE_CODE_MESSAGING_TOKEN, CLAUDE_CODE_MESSAGING_SOCKET, ANDROID_HOME, ANDROID_SDK_ROOT,
# JAVA_HOME, AI_AGENT and CLAUDECODE. A suite's answer must not depend on whose terminal
# started it, and a gate that can see an agent's messaging token can print it into a log.
#
# EVERY NAME BELOW CARRIES THE REASON IT IS NEEDED. That is the bar for adding one: not
# "it seems harmless" -- nothing here is about harm -- but "this step cannot do its job
# without it". Values are never listed, only names; what a name holds is the machine's
# business.
GATE_PASSTHROUGH = (
    # The machine's identity and scratch space. cargo, rustup, playwright's browser cache,
    # git's own config, the login keychain and `gh`'s credential store all live under HOME.
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    # Text encoding. Without these a subprocess can decode its own output differently than
    # the run that measured it, which is a suite that fails on one terminal and not another.
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    # `origin` is git@github.com:WebDevBooster/richos.git, so `fetch` authenticates over ssh
    # through the agent. Without the socket the fetch phase prompts, and GIT_TERMINAL_PROMPT=0
    # (set below) turns that prompt into a failure whose message names none of this.
    "SSH_AUTH_SOCK",
    # macOS keychain access for codesign, which is how the security session is found. Not
    # needed by the gates; needed by the signing step that runs in the same environment.
    "SECURITYSESSIONID",
    # `gh api` in preflight and `gh release` at publish, for an operator who authenticates by
    # token or against a non-default host rather than through `gh auth login`'s store.
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_HOST",
    "GH_CONFIG_DIR",
    # A Rust toolchain that is not at ~/.cargo and ~/.rustup.
    "CARGO_HOME",
    "RUSTUP_HOME",
    # Xcode selection on a machine carrying more than one.
    "DEVELOPER_DIR",
    # The privacy deny-list for the `named-persons.sh --tree` gate. Operator-configurable by
    # design, and defaulted below when unset.
    "RICHOS_NAMED_PERSONS_FILE",
)

# WHAT THIS SCRIPT SETS FOR EVERY GATE, whatever the shell held. Declared as names here so
# that `run-tests.test.sh` case E1 -- which re-runs the whole suite under the environment a
# build hands it -- derives the list instead of keeping a copy that silently goes stale the
# next time a variable is added. `nightly-local.py gate-environment` prints it.
GATE_SET_BY_BUILD = (
    "PATH",
    "PYTHONDONTWRITEBYTECODE",
    "CARGO_PROFILE_DEV_DEBUG",
    "CARGO_PROFILE_TEST_DEBUG",
    "GIT_TERMINAL_PROMPT",
    "GIT_SSH_COMMAND",
    "RICHOS_NIGHTLY_RUN_ID",
    "RICHOS_NAMED_PERSONS_FILE",
    # Set by Runner.runtime() once the pinned runtimes are verified.
    "RICHOS_RUNTIME_DIR",
)

# WHAT THIS SCRIPT SETS FOR ONE STEP ONLY, at that step's own call site, through
# `command(env_extra=...)`. These never come from the shell -- that is the point of them --
# but a suite still has to survive seeing them, which is what E1 proves.
# The UI suite's quarantine is NOT here, and that is deliberate: it is passed to `run.js` as
# `--quarantine=` arguments, where it is visible in the command line the log records, rather
# than through an environment variable a stray export could also set.
GATE_SET_PER_STEP = (
    "RUN_TESTS_DECLARED_GAPS",
    "RUN_TESTS_SKIP_UNCHANGED",
    # native-ios-app.test.sh case A8, the middle iPhone size: off every land, on before every
    # nightly (CEO, 2026-09-23, "Only before nightlies"). Set at the script-suites call site.
    "RICHOS_NATIVE_IOS_APP_A8",
    # The workspace-spec mutation pass, the same ruling; set at the workspace-mutants gate.
    "RICHOS_FOURTEEN_MUTANTS",
)


def local_environment(run_id=None):
    """Return (environment, credentials). Nothing merges them but the signing steps.

    `run_id`, when given, becomes this process's own RICHOS_NIGHTLY_RUN_ID instead of
    a freshly generated one -- used only so `build` can be told to resume a specific
    id; `publish`/`candidate` never pass one, since they act on an EXISTING build's
    run id (given separately, as `--run`) rather than minting their own.
    """
    # THE TWO QUESTIONS ARE ANSWERED SEPARATELY, and that is why credentials are collected
    # from the FULL environment while the gate environment is built from the allowlist. A
    # signing variable the operator exported must still reach the step that signs; it must
    # simply never reach a gate. Reading them from `os.environ` rather than popping them out
    # of `env` is what lets both be true at once.
    credentials = split_credentials(os.environ.copy())
    env = {name: os.environ[name] for name in GATE_PASSTHROUGH if name in os.environ}
    # Explicit PATH also works from a fresh terminal, without an interactive shell.
    env["PATH"] = f"{Path.home()}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    # NOT NEEDED ANY MORE, AND KEPT AS A PROOF RATHER THAN A STEP. Every name these two
    # removed -- GIT_AUTHOR_*, GIT_COMMITTER_*, EMAIL, RICHOS_EXTRA_TAURI_CONFIG,
    # TAURI_CONFIG, CARGO_TARGET_DIR, RUN_TESTS_DECLARED_GAPS -- is absent from
    # GATE_PASSTHROUGH, so an allowlisted environment cannot contain one. Asserting that
    # here means the day somebody adds a name to the allowlist without thinking, this fails
    # loudly instead of quietly restoring the leak.
    leaked = [n for n in IDENTITY_OVERRIDES + ("RICHOS_EXTRA_TAURI_CONFIG", "TAURI_CONFIG",
                                               "CARGO_TARGET_DIR", "RUN_TESTS_DECLARED_GAPS")
              if n in env]
    if leaked:
        raise ValueError(
            f"GATE_PASSTHROUGH admits {', '.join(leaked)}, which a gate must never take from "
            "the operator's shell. Remove the name from the allowlist.")
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


def walk_recipe(bundle_zip, run_id, temp_root=None):
    """The shell lines that walk a candidate on a scratch home: (scratch folder, lines).

    The rule is nightly-launch.sh's, for the same reason (adoption ledger §2.5, a state
    directory per install). HOME alone is NOT a scratch home: Foundation answers
    NSHomeDirectory() from the account record, so WebKit's store and the URL cache of an
    instance started with HOME alone land in the REAL ~/Library/WebKit/com.richos.app and
    ~/Library/Caches/com.richos.app, the folders the daily driver (same bundle identifier)
    uses. Measured in a test guest on 2026-09-24 (richos-hq
    docs/verification/2026-09-24-nightly-launcher/, run 1 finding 3). So:

      * HOME and CFFIXED_USER_HOME are both the scratch home, and TMPDIR is inside it;
      * `env -i` with launchd's PATH, so nothing from the calling shell reaches the app;
      * `.noindex` folders, so Spotlight never offers this copy beside the real one;
      * the scratch folder is CANONICAL: the product refuses a home that is not its own
        realpath, and macOS's temporary folder sits behind the /var symlink.
    """
    base = Path(temp_root or tempfile.gettempdir()).resolve()
    scratch = base / f"richos-qa-{run_id}.noindex"
    home = scratch / "home.noindex"
    q = shlex.quote
    return scratch, [
        f"mkdir -p {q(str(home / 'tmp'))} && ditto -x -k {q(str(bundle_zip))} {q(str(scratch))}",
        f"/usr/bin/env -i HOME={q(str(home))} CFFIXED_USER_HOME={q(str(home))} "
        f"TMPDIR={q(str(home / 'tmp'))}/ \\",
        '    USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin RICHOS_ACTIVATION=regular \\',
        f"    {q(str(scratch / 'RichOS.app/Contents/MacOS/richos-tauri'))}",
    ]


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
        self.active_phase = None

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
        previous_phase, self.active_phase = self.active_phase, name
        try:
            yield
        finally:
            self.active_phase = previous_phase
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
            result = owned_run([str(a) for a in args], cwd=cwd or self.source,
                               env=env, stdin=subprocess.DEVNULL, text=True,
                               stdout=subprocess.PIPE if capture else self.log,
                               stderr=self.log, timeout=timeout)
        except CommandCleanupError as error:
            label = self.active_phase or Path(str(args[0])).name
            raise CommandCleanupError(f"{label} cleanup failed (command budget {timeout}s): {error}") from None
        except subprocess.TimeoutExpired:
            # TimeoutExpired's default message includes argv, potentially a password.
            label = self.active_phase or Path(str(args[0])).name
            raise RuntimeError(f"{label} timed out after {timeout}s; owned group stopped; see the run log") from None
        if result.returncode:
            # Do not echo argv: signing commands can carry a password.
            raise RuntimeError(f"{Path(str(args[0])).name} failed (exit {result.returncode}); see the run log")
        return result.stdout.strip() if capture else None

    def checkout(self, sha=None):
        """Put the dedicated worktree on `sha`, or on `origin/main` when none is given.

        `stable` is the only caller that names one: it rebuilds the commit a published
        nightly was built from, which is by definition not the tip.
        """
        self.command("git", "fetch", "origin", "main", cwd=self.repo, timeout=120)
        if sha is None:
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

    def stable_plan(self, nightly_tag):
        """Resolve a STABLE release as a rebuild of the commit `nightly_tag` was built from.

        Read at MAIN, deliberately, and before the worktree is moved to the older commit:
        the CEO's promotion record is a fact about today, written after the nightly he
        tested was published, so it does not exist in that nightly's own commit.
        """
        path = self.state / "stable-plan.json"
        self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "stable-plan",
                     "--from-nightly", nightly_tag, "--output", path, timeout=300)
        return path, json.loads(path.read_text())

    def describe_stable(self, info):
        """Exactly what `stable` would build and publish, and nothing it would not.

        A dry run whose output is a summary is a dry run nobody can check. Every value
        below is the one the real path would use, read from the plan it just resolved --
        the version from the source commit's own Cargo.toml, the endpoint from the
        channel table, his words from the promotion record.
        """
        print("")
        print(f"  Stable release        : {info['tag']}  (version {info['version']})")
        print(f"  Rebuilt from          : {info['promoted_from']} "
              f"(version {info['promoted_from_version']})")
        print(f"  Source commit         : {info['source_commit']}")
        print(f"  Compiled-in endpoint  : {info['endpoint']}")
        print("")
        print("  HIS DECISION, which is the only thing that allows this (ceo-decisions §69):")
        print(f"    decided on {info['promotion_decided_on']}")
        print(f"    \"{info['promotion_words']}\"")
        print("")
        print("  WOULD THEN:")
        print(f"    1. move the dedicated worktree to {info['source_commit'][:12]} and run "
              "every gate there")
        print(f"    2. build, sign and notarize {info['tag']} from that commit, with the "
              "stable endpoint and the stable version compiled in")
        print(f"    3. upload every asset to {info['tag']} while it is still a PRERELEASE, "
              "so nothing installed can see a partial release")
        print("    4. flip that release to `--latest --prerelease=false`, which is the "
              "whole channel move")
        print("")
        print("  Nothing above has been done. No tag was created, nothing was built, "
              "uploaded or published.")

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

    def ui_proof_path(self, sha):
        return self.state / "ui-coverage" / f"{sha}.json"

    def accept_ui_proof(self, sha):
        """The coverage proof for `sha`, or None. Never a bare boolean, and never a guess.

        `--checks-done-at-land` says a land already ran the sharded UI suite on the commit
        this build then fetched. The proof that makes that true is the file `run.js
        --coverage --proof-out` writes on a PASS, and the only thing tying it to a tree is
        the commit inside it -- so it is compared against the sha this run actually fetched,
        exactly as accept_land_proof does. A proof file named after the right sha whose
        CONTENTS name a different one proves nothing; that is why both are checked.
        """
        path = self.ui_proof_path(sha)
        if not path.exists():
            return None
        try:
            proof = json.loads(path.read_text())
        except (OSError, ValueError):
            return None
        if proof.get("proof") != "ui-suite-coverage":
            return None
        seen = proof.get("commit", "")
        if not seen or not sha.startswith(seen) and not seen.startswith(sha):
            raise ValueError(
                f"{path} is a coverage proof for {seen or '<no commit>'}, not for {sha}. "
                "A proof taken against a different tree proves nothing about this one.")
        return proof

    def ui_suite(self, checks_done_at_land=None):
        """Run the whole UI inventory, sharded, and refuse the build on a red suite.

        `run.js --shards=N` owns fan-out, receipts and the coverage verdict.
        command() owns its process group, credential split, log and deadline.
        This method never launches a second process outside that boundary.

        THE SHARDS' EXIT CODES ARE NOT THE VERDICT and this method never sees them. `run.js`
        says why in its own words -- a shard has seen a subset, and only the coverage job has
        seen every receipt, so only it can tell a failed suite from an absent one.
        """
        if checks_done_at_land:
            proof = self.accept_ui_proof(checks_done_at_land)
            if proof:
                self.skip(UI_SUITE_GATE,
                          f"the land already ran the sharded UI suite on {checks_done_at_land} "
                          f"({proof.get('ran')} suite(s), {proof.get('checks')} checks, "
                          f"proven {proof.get('at')}), which is the commit this run fetched")
                return
        tests = self.source / UI_TESTS
        receipts = self.state / "ui-receipts"
        with self.phase(UI_SUITE_GATE):
            if UI_QUARANTINE:
                self.announce(f"  ui quarantine ({len(UI_QUARANTINE)}): " + "; ".join(UI_QUARANTINE))
            else:
                self.announce("  ui quarantine: empty - every suite holds this build.")
            args = ["node", "run.js", f"--shards={UI_SHARDS}", f"--receipts={receipts}"]
            for suite in UI_QUARANTINE:
                args.append(f"--quarantine={suite}")
            try:
                self.command(*args, cwd=tests, timeout=GATE_BUDGETS[UI_SUITE_GATE])
                self.restore_source_tree("the UI suite")
            except RuntimeError as error:
                if not isinstance(error, CommandCleanupError):
                    self.restore_source_tree("the UI suite")
                # NAME THE SUITE AND ITS LOG. A gate that refuses a build and leaves the
                # reader to find out which of 55 suites did it is a gate people learn to
                # re-run rather than read.
                red = self.red_ui_suites(receipts)
                raise RuntimeError(
                    f"the UI suite refused this build: {error}"
                    + (f": {', '.join(red)}" if red else " (see the coverage output)")
                    + f". Every shard's output and the coverage verdict are in this run's log "
                    f"under the {UI_SUITE_GATE} phase; the receipts are in {receipts}.") from None

    def restore_source_tree(self, who):
        """Put the fetched source back the way it was fetched, naming anything that moved.

        THIS EXISTS BECAUSE THE UI SUITE WRITES TO ITS OWN CHECKOUT, and until this gate
        existed nothing in a build did. `lib/harness.js:publishShot` deliberately REWRITES a
        committed screenshot when the picture it takes differs, announcing "shot changed" --
        good behavior for an engineer running the suite by hand, and a trap for a build:
        `checkout()` refuses to reuse the nightly worktree when `git status --porcelain`
        says anything at all ("nightly worktree has changes; inspect it before continuing").
        So a gate that left the tree dirty would pass tonight and REFUSE TO START tomorrow,
        with a message about the worktree that names nothing about the suite that dirtied it.

        MEASURED, 2026-09-20, two full runs at bf1381e0: `shots-phone/phone-light.png` and
        `shots-contrast/phone-pairing.png` were untouched by the first and rewritten by the
        second -- 775 of 1,330,000 pixels, worst channel delta 164, in one 120x13 box. The
        two runs differed only in which shard each suite landed in, so that surface is not
        the same picture twice and is not declared in `lib/shot-stability.js`, which is the
        file that exists to declare exactly that.

        IT REPORTS BEFORE IT RESTORES, and that order is the whole point. A silent `git
        checkout -- .` would erase the evidence that a screen changed, which is the one thing
        anybody would want to know. It does not FAIL the build: an unstable screenshot is
        test-artifact drift, not a broken app, and stopping a night's build over it is the
        trade this gate is explicitly not making.
        """
        # NOTHING HERE MAY RAISE. One of the two callers is an `except` block reporting which
        # suite refused the build, and an exception thrown from inside it would replace that
        # message with a git error -- losing the only sentence that says what actually
        # happened. Tidying up is never allowed to become the reported failure.
        try:
            dirty = self.command("git", "status", "--porcelain", cwd=self.source, capture=True, timeout=CLEANUP_TIMEOUT)
        except (RuntimeError, OSError) as error:
            self.announce(f"  could not check whether {who} left its checkout dirty: {error}")
            return
        if not dirty:
            return
        self.announce(f"  {who} modified its own checkout; restoring it so the next build's "
                      f"`checkout()` is not refused. Files:")
        for line in dirty.splitlines():
            self.announce(f"    {line}")
        self.announce("  If one of these is a real visual change, it is a change to look at, "
                      "not a file to re-commit from here; if it differs run to run, it belongs "
                      "in richos/app/ui/tests/lib/shot-stability.js with its cause and bound.")
        try:
            self.command("git", "checkout", "--", ".", cwd=self.source, timeout=CLEANUP_TIMEOUT)
        except (RuntimeError, OSError) as error:
            # Say it plainly rather than swallowing it: the next build will refuse to start
            # and this line is what tells somebody why.
            self.announce(f"  RESTORE FAILED ({error}). The next build's checkout() will "
                          f"refuse this worktree until {self.source} is clean.")

    @staticmethod
    def red_ui_suites(receipts):
        """Which suites a finished sharded run recorded as red, read off the receipts.

        Read here rather than parsed out of the coverage job's prose: the receipt is the
        thing `run.js` wrote down, and a second parser for the same fact is a second thing
        to keep true.
        """
        red = []
        for path in sorted(Path(receipts).glob("*.receipt.json")):
            try:
                receipt = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            failed = sum(r.get("failed", 0) for r in receipt.get("records", [])
                         if isinstance(r.get("checks"), int))
            if receipt.get("exit") or failed:
                red.append(f"{receipt.get('suite')} (exit {receipt.get('exit')}, "
                           f"{failed} failed check(s))")
        return red

    def gates(self, checks_done_at_land=None, no_host_screen=False, skip_unchanged=False):
        # Deliberately without `credentials=True`: a gate that can see the operator's
        # notary key answers questions the suites ask precisely because the answer
        # should be absent. See split_credentials() and package-app.test.sh section E.
        self.announce("Running core, updater and packaging checks...")
        # FIRST, AND IT COSTS A QUARTER OF A SECOND. Every step a release performs and an
        # ordinary day does not -- the version written into the manifest, the endpoint
        # compiled into the binary, the candidate's digests, the updater metadata, the
        # CEO's promotion record -- exercised against a throwaway directory before a
        # single crate is compiled. See `nightly.py`'s `release_smoke` for what is in it
        # and what is deliberately not.
        #
        # AHEAD OF `cargo test` DELIBERATELY. The gates below already put the cheap
        # refusals first; this is the cheapest refusal there is, and the class it catches
        # -- a release-only step that rotted since the last release -- would otherwise be
        # found forty minutes in, by the release that needed it. It is NEVER skipped for a
        # candidate: skipping is for work whose inputs are unchanged, and this gate's
        # input is the release path itself.
        with self.phase("gates/release-smoke"):
            self.command(sys.executable, self.source / SCRIPTS / "nightly.py",
                         "release-smoke", "--out", self.state / "release-smoke",
                         timeout=GATE_BUDGETS["gates/release-smoke"])
        if checks_done_at_land:
            self.skip(LAND_PROVEN_GATE,
                      f"the land already ran `cargo test -p richos-core` on {checks_done_at_land}, "
                      "which is the commit this run fetched")
        else:
            with self.phase(LAND_PROVEN_GATE):
                self.command("cargo", "test", "--locked", "--manifest-path",
                             "richos/app/Cargo.toml", "-p", "richos-core",
                             timeout=GATE_BUDGETS[LAND_PROVEN_GATE])
        with self.phase("gates/updater-tests"):
            self.command("cargo", "test", "--locked", "--manifest-path",
                         "richos/app/crates/richos-user-update/Cargo.toml",
                         timeout=GATE_BUDGETS["gates/updater-tests"])
        results = self.state / SUITE_RESULTS
        with self.phase("gates/script-suites"):
            # Every one of these is written literally at this call site rather than taken
            # from the operator's shell, for the same reason DECLARED_GAPS is: a stray
            # export must not be able to hold back a suite or skip one.
            extra = {"RUN_TESTS_DECLARED_GAPS": DECLARED_GAPS,
                     # The iPhone UI tests on the middle screen size run HERE, before every
                     # nightly, and nowhere on a land (CEO, 2026-09-23, "Only before
                     # nightlies"). A failure fails this gate and so stops the nightly.
                     "RICHOS_NATIVE_IOS_APP_A8": "1"}
            if skip_unchanged:
                extra["RUN_TESTS_SKIP_UNCHANGED"] = "1"
            args = ["bash", self.source / SCRIPTS / "run-tests.sh",
                    "--results-out", results]
            if no_host_screen:
                args.append("--no-host-screen")
            self.command(*args, env_extra=extra, timeout=GATE_BUDGETS["gates/script-suites"])
        with self.phase("gates/lint-tauri"):
            self.command("bash", self.source / SCRIPTS / "lint.sh", "--all",
                         "--suite-results", results, timeout=GATE_BUDGETS["gates/lint-tauri"])
        # The workspace-spec mutation pass: 86 deliberately broken copies of the workspace code,
        # each of which one of the suite's checks must catch. OFF every land and ON before
        # every nightly (CEO, 2026-09-23, "Only before nightlies", esc-20260923T123440Z-b5371531);
        # the suite's fourteen checks still run on every land that touches that code. Through
        # ci-shard.sh, so the unit keeps its leak canary and its deadline; a failed or unproven
        # mutant fails this gate and stops the nightly.
        with self.phase(WORKSPACE_MUTANTS_GATE):
            self.command("bash", "richos/engine/scripts/ci-shard.sh", "--only-units",
                         "mega-lander/tests/workspace-spec-fourteen.test.sh",
                         env_extra={"RICHOS_FOURTEEN_MUTANTS": "1"},
                         timeout=GATE_BUDGETS[WORKSPACE_MUTANTS_GATE])
        # AFTER the script suites and BEFORE the privacy sweep. It is the longest gate, so
        # the cheap refusals get to refuse first: there is no sense spending 378 s of WebKit
        # to learn that `cargo test` was going to fail anyway.
        self.ui_suite(checks_done_at_land)
        with self.phase("gates/privacy-sweep"):
            self.command("bash", "richos/engine/scripts/named-persons.sh", "--tree",
                         "--repo", self.source, timeout=GATE_BUDGETS["gates/privacy-sweep"])
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
        _scratch, recipe = walk_recipe(bundle_zip, info['run_id'])
        number = info['version'].rsplit('.', 1)[-1]
        print(f"Candidate build {number}: {info['tag']}, source {info['source_commit']}", flush=True)
        print(f"  staged at : {out}", flush=True)
        print(f"  bundle zip: {bundle_zip}", flush=True)
        print("", flush=True)
        print("To walk it, in the test VM and never on this Mac's screen (CEO ruling §65): unpack", flush=True)
        print("into a scratch home so it never touches the operator's own app data (README.md's", flush=True)
        print("activation invariant D). HOME and CFFIXED_USER_HOME are both that home, because", flush=True)
        print("HOME alone leaves WebKit's store in the real ~/Library. Run it directly under", flush=True)
        print("`env -i` rather than via `open`, so a harness holds the process (invariant P) and", flush=True)
        print("nothing from this shell reaches it; RICHOS_ACTIVATION=regular shows the window:", flush=True)
        print("", flush=True)
        for line in recipe:
            print("  " + line, flush=True)
        print("", flush=True)
        if info.get("candidate_ref"):
            print("The candidate has no public version tag or release-list entry. Its digest-named", flush=True)
            print("engine is public on the existing nightly channel release. The app is not", flush=True)
            print("installed or offered as an update; the update channel has not moved.", flush=True)
        else:
            print("This legacy candidate has an engine-only prerelease. The app is not installed", flush=True)
            print("or offered as an update; the update channel has not moved.", flush=True)
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
                checks_done_at_land=None, no_host_screen=False, gui_proof=None,
                from_nightly=None, dry_run=False):
        if command == "stable":
            # THE COMMIT, NOT THE BYTES. T3 Code's sentence, which is what is being copied
            # (`t3code:.github/workflows/release.yml:44-47`): *"Manual stable releases
            # build the commit of the latest published nightly, so stable only ever ships
            # a build that nightly users have already run."*
            #
            # The worktree starts at main because that is where his promotion record and
            # this tooling live; only once the plan is resolved does it move to the older
            # commit, which is then built by its own release scripts.
            with self.phase("fetch"):
                self.checkout()
            with self.phase("stable-plan"):
                plan_path, info = self.stable_plan(from_nightly)
            if dry_run:
                print(f"DRY RUN -- {from_nightly} would be rebuilt as a stable release.",
                      flush=True)
                self.describe_stable(info)
                self.summary()
                return
            with self.phase("source"):
                self.checkout(info["source_commit"])
            with self.phase("preflight"):
                self.preflight()
            with self.phase("runtime-verify"):
                self.runtime(runtime)
            # EVERY GATE, EVERY TIME. `release` does the same and for the same reason:
            # skipping is for candidates nobody can install, and this is the command that
            # makes a build the one every stable user receives.
            self.gates(no_host_screen=no_host_screen)
            out = self.state / "releases" / info["tag"]
            self.announce(f"Building and publishing {info['tag']} from "
                          f"{info['source_commit'][:12]}...")
            with self.phase("build"):
                self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "run",
                             "--plan", plan_path, "--out", out, credentials=True)
            print(f"Published https://github.com/{REPO}/releases/tag/{info['tag']}",
                  flush=True)
            self.summary()
            return
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
            # WHAT WAS ACTUALLY SKIPPED, not what this line used to assume was. It named
            # `[LAND_PROVEN_GATE]` literally, which was true while exactly one gate could be
            # skipped; the UI suite can be skipped too now, and only when its own coverage
            # proof exists for this sha. Reading the runner's own record of its skips means
            # the candidate's provenance cannot claim a gate ran that did not, or the
            # reverse, the next time a third skippable gate appears.
            info = {**info, "checks_done_at_land": checks_done_at_land,
                    "checks_skipped": sorted(self.skipped)}
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
    parser.add_argument("command", choices=["check", "build", "publish", "candidate",
                                           "release", "stable", "gate-environment"])
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".richos-nightly")
    parser.add_argument("--runtime-dir", type=Path, help="existing verified runtime cache")
    parser.add_argument("--force", action="store_true", help="explicitly rebuild a previously released source")
    parser.add_argument("--run", help="an existing build's run id (required for publish/candidate)")
    parser.add_argument("--checks-done-at-land", metavar="SHA",
                        help="skip the gates a land already ran on this exact commit "
                             "(cargo test -p richos-core, and the sharded UI suite when a "
                             "coverage proof for SHA is on this machine); refused unless "
                             "SHA is the sha this run fetches")
    parser.add_argument("--no-host-screen", action="store_true",
                        help="hold back every suite that boots the app on this Mac's screen; "
                             "the candidate is still built and walkable, and publish will "
                             "refuse it until --gui-proof names a boot taken elsewhere")
    parser.add_argument("--from-nightly", metavar="TAG",
                        help="the published nightly whose SOURCE COMMIT `stable` rebuilds; "
                             "refused unless the CEO's own promotion decision for that exact "
                             "tag is recorded (ceo-decisions §69)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print exactly what `stable` would build and publish, and stop")
    parser.add_argument("--gui-proof", metavar="PATH",
                        help="a gui-boot proof taken against this candidate's commit, required "
                             "to publish a candidate built with --no-host-screen")
    args = parser.parse_args()
    # THE ONE COMMAND THAT BUILDS NOTHING, SIGNS NOTHING AND NEEDS NO STATE. It prints the
    # declared gate environment so a test in another language can read the list instead of
    # keeping a copy of it: `run-tests.test.sh` case E1 re-runs the whole suite under every
    # variable a build exports, and a hand-written copy of that list goes stale in silence
    # the next time one is added. It runs before the Apple-Silicon precondition on purpose --
    # it is a question about this file's source, not about this machine.
    if args.command == "gate-environment":
        for kind, names in (("passthrough", GATE_PASSTHROUGH),
                            ("set", GATE_SET_BY_BUILD),
                            ("per-step", GATE_SET_PER_STEP)):
            for name in names:
                print(f"{kind}\t{name}")
        return
    if args.command in ("publish", "candidate") and not args.run:
        parser.error(f"{args.command} requires --run <run-id> (see the output of a prior `build`)")
    if args.checks_done_at_land and args.command not in ("build", "release"):
        parser.error("--checks-done-at-land only means anything for build or release")
    if args.no_host_screen and args.command not in NO_HOST_SCREEN_COMMANDS:
        parser.error("--no-host-screen is for `build`. `release` publishes in one motion with "
                     "no publish step to refuse an unproven boot, so it always runs the whole "
                     "gate; the screenless path is build -> walk -> publish --gui-proof.")
    if args.command == "stable" and not args.from_nightly:
        parser.error("stable requires --from-nightly <tag>: a stable release is a rebuild "
                     "of the commit a published nightly was built from, and it is refused "
                     "unless the CEO has himself tested that nightly and his decision to "
                     "promote it is recorded (ceo-decisions §69)")
    if args.from_nightly and args.command != "stable":
        parser.error("--from-nightly names the nightly `stable` rebuilds; it means nothing "
                     "to any other command")
    if args.dry_run and args.command != "stable":
        parser.error("--dry-run is implemented for `stable`. For a nightly, `build` already "
                     "produces the whole train without publishing anything: nobody's "
                     "existing install can see or fetch what it makes.")
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
                args.run, args.checks_done_at_land, args.no_host_screen, args.gui_proof,
                args.from_nightly, args.dry_run)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"nightly: {error}") from error
