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
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]
REPO = "WebDevBooster/richos"
SCRIPTS = Path("richos/app/scripts")


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

    def command(self, *args, cwd=None, capture=False, timeout=None, credentials=False):
        env = {**self.env, **self.credentials} if credentials else self.env
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
        rules = json.loads(self.command("gh", "api", f"repos/{REPO}/rules/branches/nightly-channel", capture=True, timeout=60))
        if any(r["type"] in {"creation", "update"} for r in rules):
            raise ValueError("repository rules block nightly-channel; configure its narrow exception first")
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
        import re
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

    def gates(self):
        # Deliberately without `credentials=True`: a gate that can see the operator's
        # notary key answers questions the suites ask precisely because the answer
        # should be absent. See split_credentials() and package-app.test.sh section E.
        print("Running core, updater and packaging checks...", flush=True)
        self.command("cargo", "test", "--locked", "--manifest-path", "richos/app/Cargo.toml", "-p", "richos-core")
        self.command("cargo", "test", "--locked", "--manifest-path", "richos/app/crates/richos-user-update/Cargo.toml")
        self.command("bash", self.source / SCRIPTS / "run-tests.sh")
        self.command("bash", "richos/engine/scripts/named-persons.sh", "--tree", "--repo", self.source)

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
        print("engine asset build compiled its pin against; nightly-channel has not moved.", flush=True)
        print("", flush=True)
        print(f"Publish only on a READY verdict:  nightly-local.py publish --run {info['run_id']}", flush=True)

    def perform(self, command, force=False, runtime=None, run_id=None):
        if command == "candidate":
            out, info = self.load_candidate(run_id)
            self.print_candidate(info, out)
            return
        if command == "publish":
            out, info = self.load_candidate(run_id)
            if not self.source.exists():
                raise ValueError(f"{self.source} no longer exists; the dedicated worktree that "
                                 f"built run {run_id} is gone, so it cannot be published from here")
            print(f"Publishing {info['tag']} from run {run_id}...", flush=True)
            # finish() only uploads, verifies and promotes -- no signing identity or
            # notarization credential is needed here, unlike the build step below.
            self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "finish", "--out", out)
            print(f"Published https://github.com/{REPO}/releases/tag/{info['tag']}", flush=True)
            return

        source = self.checkout()
        plan_path, info = self.plan(force)
        print(f"Source: {source}", flush=True)
        if not info["build"] and command in ("release", "build"):
            print(info["reason"] + "; nothing published.", flush=True)
            return
        self.preflight()
        if command == "check":
            if runtime or (self.state / "runtime").exists():
                self.runtime(runtime)
            print("Preflight passed. No release was triggered or published.", flush=True)
            return
        if command not in ("release", "build"):
            raise ValueError("only build, release or publish may build or publish")
        self.runtime(runtime)
        self.gates()
        # Capture the UTC date at allocation, even if checks crossed midnight.
        plan_path, info = self.plan(force)
        if not info["build"]:
            print(info["reason"] + "; nothing published.", flush=True)
            return
        out = self.state / "releases" / info["tag"]
        if command == "release":
            print(f"Building and publishing {info['tag']}...", flush=True)
            # The publisher builds, signs, notarizes and signs the updater manifest; it is
            # the one step that reads these variables out of its environment
            # (make-release.sh:359 and its notarize_env at :410).
            self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "run",
                         "--plan", plan_path, "--out", out, credentials=True)
            print(f"Published https://github.com/{REPO}/releases/tag/{info['tag']}", flush=True)
            return
        # command == "build": stop at the signed, notarized, engine-pinned candidate.
        print(f"Building {info['tag']}...", flush=True)
        self.command(sys.executable, self.source / SCRIPTS / "nightly.py", "build",
                     "--plan", plan_path, "--out", out, credentials=True)
        candidate_info = json.loads((out / "candidate.json").read_text())["info"]
        self.record_run(self.env["RICHOS_NIGHTLY_RUN_ID"], out)
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
    args = parser.parse_args()
    if args.command in ("publish", "candidate") and not args.run:
        parser.error(f"{args.command} requires --run <run-id> (see the output of a prior `build`)")
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
        with log_path.open("w") as log:
            Runner(args.repo.resolve(), state, env, log, credentials).perform(
                args.command, args.force, args.runtime_dir.resolve() if args.runtime_dir else None,
                args.run)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"nightly: {error}") from error
