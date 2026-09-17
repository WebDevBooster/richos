#!/usr/bin/env python3
"""Allocate immutable nightly releases and advance their verified update channel.

Python 3.11+, git and gh are required. Remote writes happen only in prepare/run.
The manual local runner serializes runs; Git ref creation/CAS rejects competing writers.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[3]
APP = Path("richos/app")
MANIFEST = APP / "src-tauri/Cargo.toml"
CONFIG = APP / "src-tauri/tauri.conf.json"
LOCK = APP / "src-tauri/Cargo.lock"
PROVENANCE = APP / "nightly-build.json"
CANDIDATE_MANIFEST = "candidate.json"
REPO = "WebDevBooster/richos"
CHANNEL_REF = "refs/heads/nightly-channel"
ENDPOINT = f"https://raw.githubusercontent.com/{REPO}/nightly-channel/latest.json"
BASE_RE = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
NIGHTLY_RE = re.compile(BASE_RE + r"-nightly\.([0-9]{8})\.([1-9][0-9]*)")


def run(*args, cwd=None, input=None, env=None):
    return subprocess.check_output(args, cwd=cwd or ROOT, input=input, text=True,
                                   env=env).strip()


def git(*args, **kwargs):
    return run("git", *args, **kwargs)


def execute(*args, cwd=None):
    subprocess.run(args, cwd=cwd or ROOT, check=True)


def utc_now():
    return datetime.now(timezone.utc)


def nightly_key(version):
    match = NIGHTLY_RE.fullmatch(version)
    if not match:
        raise ValueError(f"invalid nightly version: {version}")
    datetime.strptime(match[4], "%Y%m%d")
    return tuple(map(int, match.groups()))


def next_version(base, day, tags):
    if not re.fullmatch(BASE_RE, base):
        raise ValueError("Cargo.toml must contain the next unreleased stable version")
    datetime.strptime(day, "%Y%m%d")
    prefix = f"v{base}-nightly.{day}."
    numbers = [nightly_key(t[1:])[-1] for t in tags if t.startswith(prefix)]
    return f"{base}-nightly.{day}.{max(numbers, default=0) + 1}"


def remote_tags():
    refs = git("ls-remote", "--tags", "origin")
    return {line.split()[1].removeprefix("refs/tags/") for line in refs.splitlines()
            if not line.endswith("^{}")}


def channel():
    refs = git("ls-remote", "origin", CHANNEL_REF)
    if not refs:
        return None, None
    oid = refs.split()[0]
    git("fetch", "--no-tags", "origin", oid)
    return oid, json.loads(git("show", f"{oid}:build-info.json"))


def json_text(value):
    return json.dumps(value, indent=2) + "\n"


# `user.useConfigOnly=true` removes git's hostname fallback. Without it an unset
# identity is not an error: measured on git 2.52.0, `git var GIT_AUTHOR_IDENT` returns
# an auto-detected `user@host.home` and `git commit-tree` accepts it and exits 0, so
# the misconfiguration would surface only when the tag push is refused.
CONFIGURED_IDENTITY = ("-c", "user.useConfigOnly=true")


def identity():
    """Return the (author, committer) identity every commit built here will carry.

    `git config user.email` is not the probe. GIT_AUTHOR_EMAIL and GIT_COMMITTER_EMAIL
    in the environment override every level of git config and `git config` cannot see
    them; only `git var` resolves what a commit will actually record.
    """
    idents = []
    for var in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"):
        result = subprocess.run(("git", *CONFIGURED_IDENTITY, "var", var), cwd=ROOT,
                                text=True, capture_output=True)
        if result.returncode or "<" not in result.stdout:
            raise ValueError(
                f"this checkout has no configured commit identity ({var}); a nightly is "
                "released under the operator's own identity, so set user.name and "
                "user.email first (git config --global user.name '<your name>' and "
                "git config --global user.email '<your email>')")
        idents.append(result.stdout.strip().rsplit(" ", 2)[0])
    return tuple(idents)


def plan(force=False, now=None):
    now = now or utc_now()
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("nightly builds require a clean checkout")
    # Refuse here rather than at the tag push, which is forty minutes of gates later.
    identity()
    source = git("rev-parse", "HEAD")
    base = tomllib.loads((ROOT / MANIFEST).read_text())["package"]["version"]
    tags = remote_tags()
    if f"v{base}" in tags:
        raise ValueError(f"v{base} already exists; bump the next release version first")
    _, previous = channel()
    if previous and previous["source_commit"] == source and not force:
        return {"build": False, "reason": "source already has a successful nightly"}
    version = next_version(base, now.strftime("%Y%m%d"), tags)
    if previous:
        if nightly_key(version) <= nightly_key(previous["version"]):
            raise ValueError("candidate version would move the nightly channel backwards")
        git("merge-base", "--is-ancestor", previous["source_commit"], source)
    return {"build": True, "version": version, "tag": f"v{version}",
            "source_commit": source, "created_at": now.isoformat(),
            "run_id": os.environ.get("RICHOS_NIGHTLY_RUN_ID", "manual"),
            "run_attempt": "1",
            "channel": "nightly", "platform": "darwin-aarch64"}


def commit_files(files, parent, message):
    """Construct a commit without modifying the checkout or its real index.

    The identity is NOT set here: the commit carries whatever identity git resolves
    for this checkout, which is the operator's own. A hard-coded
    `RichOS nightly <nightly@users.noreply.github.com>` was written for a GitHub
    Actions runner (c8aee2fc) and survived the move to a local command (2d0f3d93);
    on the release Mac it said something false about who released the build, and the
    machine's commit-identity guard refused the tag push over it
    (femcboost/scripts/hooks/git-identity-guard.sh, DENY_GLOBS `*@users.noreply.github.com`).
    """
    with tempfile.TemporaryDirectory(prefix="richos-nightly-index-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        git("read-tree", parent if parent else "--empty", env=env)
        for name, contents in files.items():
            blob = git("hash-object", "-w", "--stdin", input=contents)
            git("update-index", "--add", "--cacheinfo", f"100644,{blob},{name}", env=env)
        tree = git("write-tree", env=env)
        return git(*CONFIGURED_IDENTITY, "commit-tree", tree,
                   *(["-p", parent] if parent else []), input=message + "\n", env=env)


def prepare(info):
    version = info["version"]
    nightly_key(version)
    if info["tag"] != f"v{version}":
        raise ValueError("tag/version mismatch")
    if git("rev-parse", "HEAD") != info["source_commit"] or git("status", "--porcelain"):
        raise ValueError("source changed after planning")
    tags = remote_tags()
    base = version.split("-", 1)[0]
    if info["tag"] in tags or f"v{base}" in tags:
        raise ValueError("version is already reserved or its stable release exists")
    manifest = (ROOT / MANIFEST).read_text()
    if tomllib.loads(manifest)["package"]["version"] != base:
        raise ValueError("base version changed after planning")
    manifest, n = re.subn(r'^version = "' + re.escape(base) + r'"$',
                          f'version = "{version}"', manifest, count=1, flags=re.M)
    if n != 1:
        raise ValueError("cannot set app package version")
    lock, n = re.subn(r'(\[\[package\]\]\nname = "richos-tauri"\nversion = ")[^"]+("\n)',
                      lambda m: m[1] + version + m[2], (ROOT / LOCK).read_text())
    if n != 1:
        raise ValueError("cannot set locked app package version")
    config = json.loads((ROOT / CONFIG).read_text())
    if "version" in config:
        raise ValueError("tauri.conf.json must inherit the Cargo version")
    config["plugins"]["updater"]["endpoints"] = [ENDPOINT]
    files = {str(MANIFEST): manifest, str(LOCK): lock, str(CONFIG): json_text(config),
             str(PROVENANCE): json_text(info)}
    commit = commit_files(files, info["source_commit"], f"Build {info['tag']}")
    # Creating a remote tag reserves the number even if the build later fails.
    # A competing writer cannot overwrite an existing tag. Never force a tag push.
    git("push", "origin", f"{commit}:refs/tags/{info['tag']}")
    git("fetch", "origin", f"refs/tags/{info['tag']}:refs/tags/{info['tag']}")
    git("checkout", "--detach", commit)
    return {**info, "build_commit": commit}


def promote(info, manifest):
    if manifest["version"] != info["version"]:
        raise ValueError("manifest version does not match the build")
    expected = f"https://github.com/{REPO}/releases/download/{info['tag']}/RichOS.app.tar.gz"
    if set(manifest["platforms"]) != {info["platform"]}:
        raise ValueError("manifest platforms do not match the built artifact")
    if manifest["platforms"][info["platform"]]["url"] != expected:
        raise ValueError("manifest must reference this immutable release")
    old, previous = channel()
    if previous:
        if nightly_key(info["version"]) <= nightly_key(previous["version"]):
            raise ValueError("refusing to replace an equal or newer nightly")
        git("merge-base", "--is-ancestor", previous["source_commit"], info["source_commit"])
    commit = commit_files({"latest.json": json_text(manifest), "build-info.json": json_text(info)},
                          old, f"Publish {info['tag']}")
    # The lease protects the read/check/write interval, including first publication.
    git("push", f"--force-with-lease={CHANNEL_REF}:{old or ''}",
        "origin", f"{commit}:{CHANNEL_REF}")
    return commit


def _candidate_files(out):
    """Every file under `out`, `candidate.json` itself excepted, as {relative path: sha256}."""
    return {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(out.rglob("*")) if p.is_file() and p.name != CANDIDATE_MANIFEST}


def write_candidate_manifest(info, out):
    (out / CANDIDATE_MANIFEST).write_text(json_text({"info": info, "files": _candidate_files(out)}))


def verify_candidate_manifest(info, out):
    """Refuse a candidate whose recorded bytes no longer match what is on disk.

    Covers the version, every asset's SHA and the updater signature file alike --
    all of them are just files under `out`, so one hash pass over the recorded set
    catches any of the three changing. A candidate that was never built here (no
    manifest) or built for a different plan is refused the same way.
    """
    path = out / CANDIDATE_MANIFEST
    if not path.exists():
        raise ValueError(f"no {CANDIDATE_MANIFEST} in {out} -- run \"nightly.py build\" first")
    recorded = json.loads(path.read_text())
    if recorded["info"] != info:
        raise ValueError("candidate was built for a different plan than the one given to publish")
    mismatched = [f"{rel}: recorded {digest}, now {_candidate_files(out).get(rel, 'MISSING')}"
                  for rel, digest in recorded["files"].items()
                  if _candidate_files(out).get(rel) != digest]
    if mismatched:
        raise ValueError("candidate has changed since it was built; refusing to publish it:\n  "
                         + "\n  ".join(mismatched))


def verify_source_is_current(source_commit):
    """Refuse a candidate built from a commit `main` no longer contains.

    `git fetch` then compare against `FETCH_HEAD`, exactly like `Runner.checkout` in
    nightly-local.py: a locally cached `origin/main` remote-tracking ref is not
    guaranteed to exist or be current, and only an explicit fetch is.
    """
    git("fetch", "--no-tags", "origin", "main")
    current_main = git("rev-parse", "FETCH_HEAD")
    git("merge-base", "--is-ancestor", source_commit, current_main)


def build(info, out):
    """Produce the signed, notarized, engine-pinned candidate under `out`, and stop.

    This is everything `publish` does up to and including compiling the app against
    a verified engine pin. It still touches the network: the app's pin is a claim
    about bytes already served from this release's tag
    (make-release.sh:15-24), and the only way to make that claim true is to create
    the (still-prerelease) release for this tag and put the engine asset there --
    `verify-engine` inside `make-release.sh` (:296-317) is what actually refuses if
    those bytes are not back on the wire; that refusal, not anything in
    make-engine-asset.sh, is what makes an unpublished pin unbuildable. What `build`
    does NOT do: upload the app itself, write `latest.json`, or move
    `nightly-channel` -- nobody can install what this produces until `finish` runs.
    """
    scripts = ROOT / APP / "scripts"
    release = str(scripts / "make-release.sh")
    out.mkdir(parents=True, exist_ok=False)
    (out / "build-info.json").write_text(json_text(info))
    notes = out / "notes.txt"
    notes.write_text(f"Nightly {info['version']}\n\nSource: {info['source_commit']}\n"
                     f"Build: {info['build_commit']}\nRun: {info['run_id']} / {info['run_attempt']}\n")
    # Publish the engine first: the app embeds its verified public URL and digest.
    execute("bash", release, "engine", "--out", str(out))
    execute("gh", "release", "create", info["tag"], "--repo", REPO, "--verify-tag",
            "--prerelease", "--latest=false", "--title", f"RichOS {info['version']}",
            "--notes-file", str(notes))
    notes.unlink()  # Release notes are not a downloadable artifact.
    engine_version = (ROOT / "richos/engine/VERSION").read_text().strip()
    execute("gh", "release", "upload", info["tag"], "--repo", REPO,
            str(out / f"richos-engine-{engine_version}.tar.gz"))
    execute("bash", release, "verify-engine", "--out", str(out))
    execute("bash", release, "app", "--out", str(out), "--notes", f"Nightly {info['version']}")
    if git("rev-parse", "HEAD") != info["build_commit"] or git("status", "--porcelain"):
        raise ValueError("build changed the tagged source tree; refusing artifact publication")
    write_candidate_manifest(info, out)


def finish(info, out):
    """Publish a candidate `build` already produced: upload, verify, promote.

    Refuses if the files `build` recorded no longer match what is on disk, or if
    `info`'s source commit is no longer an ancestor of the current `main` --
    someone could have force-pushed or rebased main while a walker was on the
    candidate. Nobody can install anything published here before this runs.
    """
    # `build` and `finish` can run as separate processes, an arbitrary time apart
    # (a QA walk in between), sharing the one dedicated worktree. If anything else
    # re-checked it out in the meantime (a `check` or another `build`), this is the
    # same guard `build` itself applies right after compiling, re-applied here
    # because that guarantee does not survive a second process using the worktree.
    if git("rev-parse", "HEAD") != info["build_commit"] or git("status", "--porcelain"):
        raise ValueError("the source worktree no longer matches this candidate's build "
                         "commit; run \"nightly-local.py build\" again before publishing")
    verify_candidate_manifest(info, out)
    verify_source_is_current(info["source_commit"])
    scripts = ROOT / APP / "scripts"
    release = str(scripts / "make-release.sh")
    engine_version = (ROOT / "richos/engine/VERSION").read_text().strip()
    assets = [str(p) for p in sorted(out.iterdir()) if p.name not in
              {"engine-pin.env", "engine-published.ok", "latest.json",
               f"richos-engine-{engine_version}.tar.gz", CANDIDATE_MANIFEST}]
    execute("gh", "release", "upload", info["tag"], "--repo", REPO, *assets)
    execute("gh", "release", "upload", info["tag"], "--repo", REPO, str(out / "latest.json"))
    # This validates published bytes and their updater signature before the pointer moves.
    execute("bash", release, "verify-assets", "--out", str(out))
    manifest = json.loads((out / "latest.json").read_text())
    channel_commit = promote(info, manifest)
    print(f"Published {info['tag']}; nightly-channel at {channel_commit}", flush=True)


def publish(info, out):
    """`build` then `finish`, in one motion -- what `release` still does."""
    build(info, out)
    finish(info, out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--force", action="store_true")
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("build")
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("finish")
    p.add_argument("--out", type=Path, required=True)
    p = sub.add_parser("run")
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "plan":
        info = plan(args.force)
        args.output.write_text(json_text(info))
        print(json_text(info))
    elif args.command == "build":
        info = json.loads(args.plan.read_text())
        if not info["build"]:
            raise ValueError("plan did not request a build")
        info = prepare(info)
        build(info, args.out.resolve())
        print(json_text(info))
    elif args.command == "finish":
        out = args.out.resolve()
        candidate = json.loads((out / CANDIDATE_MANIFEST).read_text())
        finish(candidate["info"], out)
    else:
        info = json.loads(args.plan.read_text())
        if not info["build"]:
            raise ValueError("plan did not request a build")
        info = prepare(info)
        publish(info, args.out.resolve())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"nightly: refusing: {error}") from error
