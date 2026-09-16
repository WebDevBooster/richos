#!/usr/bin/env python3
"""Allocate immutable nightly releases and advance their verified update channel.

Python 3.11+, git and gh are required. Remote writes happen only in prepare/run.
The workflow serializes runs; Git ref creation/CAS also rejects competing writers.
"""
import argparse
from datetime import datetime, timezone
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
REPO = "WebDevBooster/richos"
CHANNEL_REF = "refs/heads/nightly-channel"
ENDPOINT = f"https://raw.githubusercontent.com/{REPO}/nightly-channel/latest.json"
DAILY_SCHEDULE = "17 3 * * *"
BURST_SCHEDULE = "17 0,6,9,12,15,18,21 * * *"
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


def due(event, schedule, burst_until, now):
    if event == "workflow_dispatch" or schedule == DAILY_SCHEDULE:
        return True
    if event != "schedule" or schedule != BURST_SCHEDULE:
        raise ValueError("unknown nightly trigger")
    if not burst_until:
        return False
    end = datetime.fromisoformat(burst_until.replace("Z", "+00:00"))
    if end.utcoffset() is None:
        raise ValueError("NIGHTLY_BURST_UNTIL must include a timezone")
    return now < end


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


def plan(event, schedule, burst_until, force=False, now=None):
    now = now or utc_now()
    if not due(event, schedule, burst_until, now):
        return {"build": False, "reason": "three-hour window is inactive"}
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("nightly builds require a clean checkout")
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
            "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
            "channel": "nightly", "platform": "darwin-aarch64"}


def commit_files(files, parent, message):
    """Construct a commit without modifying the checkout or its real index."""
    with tempfile.TemporaryDirectory(prefix="richos-nightly-index-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index"),
               "GIT_AUTHOR_NAME": "RichOS nightly", "GIT_COMMITTER_NAME": "RichOS nightly",
               "GIT_AUTHOR_EMAIL": "nightly@users.noreply.github.com",
               "GIT_COMMITTER_EMAIL": "nightly@users.noreply.github.com"}
        git("read-tree", parent if parent else "--empty", env=env)
        for name, contents in files.items():
            blob = git("hash-object", "-w", "--stdin", input=contents)
            git("update-index", "--add", "--cacheinfo", f"100644,{blob},{name}", env=env)
        tree = git("write-tree", env=env)
        return git("commit-tree", tree, *(["-p", parent] if parent else []),
                   input=message + "\n", env=env)


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


def publish(info, out):
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
    assets = [str(p) for p in sorted(out.iterdir()) if p.name not in
              {"engine-pin.env", "engine-published.ok", "latest.json",
               f"richos-engine-{engine_version}.tar.gz"}]
    execute("gh", "release", "upload", info["tag"], "--repo", REPO, *assets)
    execute("gh", "release", "upload", info["tag"], "--repo", REPO, str(out / "latest.json"))
    # This validates published bytes and their updater signature before the pointer moves.
    execute("bash", release, "verify-assets", "--out", str(out))
    manifest = json.loads((out / "latest.json").read_text())
    channel_commit = promote(info, manifest)
    print(f"Published {info['tag']}; nightly-channel at {channel_commit}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--event", choices=["schedule", "workflow_dispatch"], default="workflow_dispatch")
    p.add_argument("--schedule", default="")
    p.add_argument("--burst-until", default="")
    p.add_argument("--force", action="store_true")
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("run")
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "plan":
        info = plan(args.event, args.schedule, args.burst_until, args.force)
        args.output.write_text(json_text(info))
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
                handle.write(f"build={str(info['build']).lower()}\n")
        print(json_text(info))
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
