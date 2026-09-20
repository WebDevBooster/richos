#!/usr/bin/env python3
"""Allocate immutable nightly releases and advance their verified update channel.

Python 3.11+, git and gh are required. Remote writes happen only in prepare/run.
The manual local runner serializes runs; Git ref creation/CAS rejects competing writers.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import functools
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
# The channel is a ROLLING RELEASE TAG, never a branch. CEO ruling 2026-09-13
# (ceo-decisions 38): the public repository shows `main` and release tags and nothing
# else. `nightly` is a release tag carrying a permanent prerelease whose `latest.json`
# asset is what every installed nightly fetches; `refs/tags/nightly` carries the channel
# commit itself, which is what still gives `promote` a compare-and-swap lease. Both
# halves matter: the asset is what the world reads, the ref is what decides who may
# write. Until 2026-09-17 this was `refs/heads/nightly-channel`, and the branch it
# created is exactly what the ruling exists to prevent.
CHANNEL_TAG = "nightly"
CHANNEL_REF = f"refs/tags/{CHANNEL_TAG}"
ENDPOINT = f"https://github.com/{REPO}/releases/download/{CHANNEL_TAG}/latest.json"
# Stable's endpoint is GitHub's own "latest release" pointer, which is why stable needs no
# rolling tag of its own: marking a release `--latest` IS the channel move. This is the
# same URL `make-release.sh:156` compiles in for a non-nightly version, and the same one
# checked into `src-tauri/tauri.conf.json`; `release_files` refuses if those three ever
# disagree, rather than letting a build compile in a URL nobody publishes to.
STABLE_ENDPOINT = f"https://github.com/{REPO}/releases/latest/download/latest.json"
CHANNEL_ENDPOINTS = {"nightly": ENDPOINT, "stable": STABLE_ENDPOINT}
RULESET = "main-only"
# Exactly one branch may be exempt from the branch ruleset, and it is `main`.
ALLOWED_RULESET_EXCLUSIONS = ["refs/heads/main"]
BASE_RE = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
NIGHTLY_RE = re.compile(BASE_RE + r"-nightly\.([0-9]{8})\.([1-9][0-9]*)")


# =======================================================================================
# RELEASE-ONLY STEPS, AND THE REGISTRY THAT KEEPS THEM EXERCISED
# =======================================================================================
#
# A release-only step is one that runs ONLY when something is released: the version
# written into the manifest, the endpoint compiled into the binary, the candidate's
# recorded digests, the updater metadata. Nothing an ordinary day exercises touches any
# of them, so they rot silently and are discovered by the release that needed them.
#
# T3 Code answered this with a `release_smoke` job on every pull request
# (`t3code:.github/workflows/ci.yml:326-349`). WE TAKE THE IDEA AND NOT THE SHAPE, because
# the shape has a defect their own repository is currently carrying: their smoke
# DUPLICATES the release workflow's inline bash instead of sharing it, and the two have
# drifted. `t3code:.github/workflows/release.yml:795` invokes the Windows manifest merge as
# `--platform win "$x64_manifest" "$arm64_manifest" "$merged"`; `release-smoke.ts:328-331`
# invokes it as `--platform win "$arm64_manifest" "$x64_manifest" "$output"` -- the two
# positional arguments are SWAPPED, so their smoke does not execute the text their release
# executes. A smoke that has drifted from the release is worse than no smoke, because it
# reports green about something nobody runs.
#
# So the rule here is stronger than "the steps are tested":
#
#   1. Every release-only step is ONE function, called by the real release path and by
#      the smoke. Not two copies of one procedure -- one function, two callers.
#   2. Every such function is decorated `@release_step`, which registers it BY THE NAME IT
#      ACTUALLY HAS. Rename it and the registry renames with it; there is no second list
#      to keep in step.
#   3. The smoke refuses unless EVERY registered step was actually called during it. Add a
#      release-only step and forget to smoke it, and the gate fails naming your function.
#
# Point 3 is the one that does the work. A smoke that merely runs some steps decays into
# T3's position one commit at a time, and nobody notices, because nothing is red. This one
# cannot: the completeness check is itself what turns red.
RELEASE_STEPS = {}
RELEASE_STEP_CALLS = {}


def release_step(function):
    """Register `function` as a release-only step and count its calls.

    The counter is what the smoke's completeness check reads. It counts calls from the
    real release path too, which costs nothing and is deliberate: the count answers "was
    this executed", and the smoke asks that question only about its own pass by zeroing
    the counters before it starts.
    """
    RELEASE_STEPS[function.__name__] = function
    RELEASE_STEP_CALLS.setdefault(function.__name__, 0)

    @functools.wraps(function)
    def counted(*args, **kwargs):
        RELEASE_STEP_CALLS[function.__name__] += 1
        return function(*args, **kwargs)

    return counted


def run(*args, cwd=None, input=None, env=None):
    return subprocess.check_output(args, cwd=cwd or ROOT, input=input, text=True,
                                   env=env).strip()


def git(*args, **kwargs):
    return run("git", *args, **kwargs)


def execute(*args, cwd=None):
    subprocess.run(args, cwd=cwd or ROOT, check=True)


def succeeds(*args, cwd=None):
    """Whether `args` exits 0. Never raises on a non-zero exit, and stays quiet."""
    return subprocess.run(args, cwd=cwd or ROOT, capture_output=True,
                          text=True).returncode == 0


def verify_repository_rules():
    """Refuse to publish while any branch but `main` is exempt from the branch ruleset.

    The recurrence this exists to stop, in full, because the shape of it is the point.
    The `main-only` ruleset (id 23194738, created 2026-09-13) restricts `creation` and
    `update` on `~ALL` refs except `refs/heads/main`, with no bypass actors. On
    2026-09-16 at 21:57Z a Codex run, authenticated as the repository owner, added
    `refs/heads/nightly-channel` to that exclusion list so this publisher could push a
    channel branch. At 02:53Z the next morning the first nightly created the branch and
    the public repository page read "2 Branches". **The ruleset never failed; it was
    told to stand aside, and nothing read it back.** A guard nobody re-reads is a guard
    that can be switched off silently, which is why this runs on every publish rather
    than living in a document.

    Read back, not assumed: the five conditions below are each a way to make the branch
    ban a no-op while the exclusion list still looks right -- a disabled ruleset, an
    `evaluate`-only one, a bypass actor, a missing rule, or a widened exclusion.
    """
    rulesets = json.loads(run("gh", "api", f"repos/{REPO}/rulesets"))
    named = [r for r in rulesets if r["name"] == RULESET and r["target"] == "branch"]
    if len(named) != 1:
        raise ValueError(
            f"expected exactly one branch ruleset named {RULESET!r} on {REPO}; found "
            f"{len(named)}. The rule that keeps every branch but main off the public "
            "repository is missing or duplicated -- restore it before publishing")
    ruleset = json.loads(run("gh", "api", f"repos/{REPO}/rulesets/{named[0]['id']}"))
    problems = []
    if ruleset["enforcement"] != "active":
        problems.append(f"enforcement is {ruleset['enforcement']!r}, not 'active'")
    if ruleset["bypass_actors"]:
        problems.append(f"{len(ruleset['bypass_actors'])} bypass actor(s) can ignore it")
    conditions = ruleset["conditions"]["ref_name"]
    if conditions["include"] != ["~ALL"]:
        problems.append(f"it covers {conditions['include']}, not ['~ALL']")
    if conditions["exclude"] != ALLOWED_RULESET_EXCLUSIONS:
        problems.append(f"its exempt branches are {conditions['exclude']}, not "
                        f"{ALLOWED_RULESET_EXCLUSIONS}")
    missing = {"creation", "update"} - {rule["type"] for rule in ruleset["rules"]}
    if missing:
        problems.append(f"it does not restrict {', '.join(sorted(missing))}")
    if problems:
        raise ValueError(
            f"the {RULESET!r} ruleset on {REPO} no longer keeps branches off the public "
            "repository:\n  " + "\n  ".join(problems) + "\n"
            "Nothing is published until that is put back. The nightly channel is a "
            f"release tag ({CHANNEL_REF}) and needs no branch exception of any kind.")


def utc_now():
    return datetime.now(timezone.utc)


@release_step
def release_files(info, manifest, lock, config_text):
    """The exact contents of every file a release commit carries. Text in, text out.

    THIS IS THE STEP THE SMOKE EXISTS FOR. It decides the version an installed copy
    reports and the endpoint it will fetch updates from for the rest of its life, it runs
    on no other occasion, and until it was pulled out of `prepare()` it was inseparable
    from a remote tag push -- which is to say it could only be exercised by releasing
    something. `prepare()` now reads the three files and calls this; the smoke passes the
    same three files from a throwaway directory and checks what comes back.

    Pure by construction: no ROOT, no network, no clock, no filesystem. That is not
    tidiness, it is what makes the second caller possible at all.

    The two channels differ in exactly two ways, and both are here rather than spread
    across the file:

      * A NIGHTLY carries a version the tree does not: `1.2.0` in Cargo.toml becomes
        `1.2.0-nightly.20260920.1` in the release commit, in the manifest and the lockfile
        together. A STABLE release carries the version the tree already holds -- Cargo.toml
        is the single copy of it (`make-release.sh` says so at its `plan` output) and a
        stable release of commit X is a build of X's own version. So the manifest and the
        lockfile are returned untouched, and that is the whole difference.
      * The endpoint compiled into the binary is the CHANNEL's endpoint. It cannot be
        changed later by an update, because the copy carrying the wrong one can no longer
        fetch anything (NIGHTLY.md states this consequence in its own words), so it is
        written from `CHANNEL_ENDPOINTS` rather than inherited from whatever the file held.

    The stable assertion below is the one that would have caught the shape Sage's review
    rejected on 2026-09-20: re-tagging a nightly's BYTES as stable leaves the nightly
    endpoint and the nightly version compiled in, so every stable user silently becomes a
    permanent nightly user running a prerelease that the real 1.2.0 supersedes.
    """
    version = info["version"]
    base = version.split("-", 1)[0]
    channel = info["channel"]
    if channel not in CHANNEL_ENDPOINTS:
        raise ValueError(f"unknown release channel {channel!r}; "
                         f"known channels are {sorted(CHANNEL_ENDPOINTS)}")
    if info["tag"] != f"v{version}":
        raise ValueError("tag/version mismatch")
    if tomllib.loads(manifest)["package"]["version"] != base:
        raise ValueError("base version changed after planning")
    if channel == "nightly":
        nightly_key(version)  # Refuses any version that is not a well-formed nightly.
        manifest, n = re.subn(r'^version = "' + re.escape(base) + r'"$',
                              f'version = "{version}"', manifest, count=1, flags=re.M)
        if n != 1:
            raise ValueError("cannot set app package version")
        lock, n = re.subn(r'(\[\[package\]\]\nname = "richos-tauri"\nversion = ")[^"]+("\n)',
                          lambda m: m[1] + version + m[2], lock)
        if n != 1:
            raise ValueError("cannot set locked app package version")
    elif version != base:
        raise ValueError(f"a {channel} release carries the tree's own version; "
                         f"{version!r} is a prerelease")
    config = json.loads(config_text)
    if "version" in config:
        raise ValueError("tauri.conf.json must inherit the Cargo version")
    endpoint = CHANNEL_ENDPOINTS[channel]
    # THE CHECKED-IN CONFIG IS STABLE'S CONFIG, and `make-release.sh:187-192` refuses a
    # build whose compiled endpoint is not the one its version publishes to. Asserting it
    # here means a change to tauri.conf.json is caught by the smoke in milliseconds rather
    # than by a stable release forty minutes in.
    configured = config["plugins"]["updater"]["endpoints"]
    if channel == "stable" and configured != [endpoint]:
        raise ValueError(
            f"tauri.conf.json's updater endpoint is\n    {configured}\n  and a stable "
            f"release publishes its manifest to\n    {endpoint}\n  One of the two is "
            "wrong, and an installed copy would fetch the first.")
    config["plugins"]["updater"]["endpoints"] = [endpoint]
    return {str(MANIFEST): manifest, str(LOCK): lock, str(CONFIG): json_text(config),
            str(PROVENANCE): json_text(info)}


def nightly_key(version):
    match = NIGHTLY_RE.fullmatch(version)
    if not match:
        raise ValueError(f"invalid nightly version: {version}")
    datetime.strptime(match[4], "%Y%m%d")
    return tuple(map(int, match.groups()))


@release_step
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
    """The channel tag's commit and the `build-info.json` recorded in it.

    Unlike the branch this replaced, a tag ref can be listed TWICE -- once as
    `refs/tags/nightly` and once peeled as `refs/tags/nightly^{}` -- and taking the
    first field of the whole output, as the branch version did, would read whichever
    line git happened to print first. The channel tag is lightweight and points
    straight at the channel commit; an annotated tag under this name is somebody
    else's object and is refused rather than guessed at.
    """
    refs = git("ls-remote", "origin", CHANNEL_REF)
    lines = [line.split() for line in refs.splitlines() if line]
    if not lines:
        return None, None
    if len(lines) != 1 or lines[0][1] != CHANNEL_REF:
        raise ValueError(f"{CHANNEL_REF} is not a lightweight tag on a channel commit: "
                         f"{refs}")
    oid = lines[0][0]
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


# The record of the CEO's own decision to promote a nightly. CEO ruling 2026-09-20
# (ceo-decisions §69), his words: *"Stable can ONLY EVER be build from a nightly if I have
# extensively tested that nightly and deemed it good enough to be promoted to stable."*
PROMOTIONS = APP / "stable-promotions.json"


@release_step
def promotion_decision(nightly_tag, record_text):
    """The CEO's own promotion decision for THIS nightly, or a refusal. Nothing else.

    WHAT THIS DELIBERATELY DOES NOT ACCEPT, because it is the whole point of §69: a READY
    verdict, a gui-boot proof, a green gate, an Urban signoff, a QA walk. Every one of
    those is a precondition for PUBLISHING A NIGHTLY and none of them promotes anything.
    Sage's review §1.6 proposed exactly that substitution -- refuse "unless that nightly
    was published on a READY verdict with a gui-proof naming that commit" -- and the CEO
    corrected it before this was built: *"nobody else's test counts toward it."*
    "Extensively tested" is his own use of that nightly, on his own Mac, for as long as he
    chooses. So the only thing this reads is a record of HIS decision, and the only thing
    that writes that record is Rich, from his words.

    No environment variable opens this door and there is no override flag. A promotion is
    a decision, and a decision that a stray export could make is not his.
    """
    try:
        entries = json.loads(record_text)
    except ValueError as error:
        raise ValueError(f"{PROMOTIONS} is not readable JSON: {error}") from error
    if not isinstance(entries, list):
        raise ValueError(f"{PROMOTIONS} must be a list of promotion decisions")
    matching = [e for e in entries if isinstance(e, dict) and e.get("tag") == nightly_tag]
    if not matching:
        raise ValueError(
            f"{PROMOTIONS} records no promotion decision for {nightly_tag}.\n"
            "  A stable release is built ONLY from a nightly the CEO has himself tested "
            "extensively and deemed good enough (ceo-decisions §69). No verdict, proof or "
            "green gate substitutes for that, and nothing here can be overridden.\n"
            "  If he has decided: Rich records his words, the tag and the date in that "
            "file first.")
    if len(matching) > 1:
        raise ValueError(f"{PROMOTIONS} records {len(matching)} decisions for "
                         f"{nightly_tag}; exactly one is expected")
    entry = matching[0]
    missing = [field for field in ("tag", "decided_on", "words")
               if not str(entry.get(field, "")).strip()]
    if missing:
        raise ValueError(f"the promotion decision for {nightly_tag} is missing "
                         f"{', '.join(missing)}; it records what he said, when, about which "
                         "nightly")
    # A date, not a mood. `decided_on` is parsed rather than trusted, so a malformed
    # record is refused here instead of reaching a release's provenance.
    datetime.strptime(entry["decided_on"], "%Y-%m-%d")
    return entry


def stable_plan(nightly_tag, record_text, now=None):
    """Plan a STABLE release as a REBUILD of the commit a published nightly was built from.

    T3 Code's sentence, verbatim (`t3code:.github/workflows/release.yml:44-47`): *"Manual
    stable releases build the commit of the latest published nightly, so stable only ever
    ships a build that nightly users have already run."* BUILD THE COMMIT. That is what is
    copied here, and the distinction is not pedantry -- promoting a nightly's BYTES was the
    form Sage's review rejected on three counts, of which two are properties of the bytes
    themselves and cannot be fixed by re-tagging them: the nightly endpoint is compiled
    into the binary, so a promoted copy would fetch nightly updates forever, and the
    version string is a prerelease that the real 1.2.0 supersedes.
    The guarantee worth having is *no stable ships a commit nobody ran*, and that is a
    property of the COMMIT.

    The source commit is read from the nightly's own tagged provenance
    (`richos/app/nightly-build.json` inside the tag), not from a directory on this Mac and
    not from a name someone typed. That file is what the nightly was built with.
    """
    now = now or utc_now()
    # HIS DECISION FIRST, before the network and before anything is resolved. It is the
    # refusal that costs nothing and the one most likely to fire.
    decision = promotion_decision(nightly_tag, record_text)
    git("fetch", "--no-tags", "origin", f"refs/tags/{nightly_tag}")
    try:
        built = json.loads(git("show", f"FETCH_HEAD:{PROVENANCE}"))
    except subprocess.CalledProcessError as error:
        raise ValueError(f"{nightly_tag} carries no {PROVENANCE}; it is not a nightly this "
                         "publisher built") from error
    if built.get("tag") != nightly_tag or built.get("channel") != "nightly":
        raise ValueError(f"{nightly_tag}'s provenance describes {built.get('tag')!r} on the "
                         f"{built.get('channel')!r} channel; refusing to build from it")
    nightly_key(built["version"])
    source = built["source_commit"]
    # The nightly must still be on main. Someone can force-push or rebase between the
    # night he tested it and the morning he promotes it, and a stable release of a commit
    # main no longer contains is a stable release of something nobody can look at.
    verify_source_is_current(source)
    # THE VERSION COMES FROM THE COMMIT BEING BUILT, not from today's main. Cargo.toml is
    # the single copy of the application version (`make-release.sh` plan output says so),
    # and a stable release of commit X ships X's own version -- if main has since bumped
    # to 1.3.0, that is 1.3.0's business and not this release's.
    base = tomllib.loads(git("show", f"{source}:{MANIFEST}"))["package"]["version"]
    if not re.fullmatch(BASE_RE, base):
        raise ValueError(f"{source[:12]} carries version {base!r}, which is not a stable "
                         "version; Cargo.toml must hold the next unreleased stable version")
    if f"v{base}" in remote_tags():
        raise ValueError(f"v{base} already exists; {nightly_tag} was built from a commit "
                         f"whose version has already shipped. Bump the version on main and "
                         "promote a nightly built after the bump.")
    # THE COMMIT IS REBUILT BY ITS OWN RELEASE TOOLING, which is what makes it a rebuild
    # of that commit rather than a build of something adjacent to it. `nightly-local.py`
    # moves the dedicated worktree to `source` and runs the `nightly.py` it finds THERE,
    # so a commit predating the stable channel cannot build a stable release: its
    # `release_files` has never heard of one. Refused here, by reading that commit's own
    # copy, rather than discovered as an AttributeError forty minutes into a build.
    try:
        tooling = git("show", f"{source}:{APP / 'scripts/nightly.py'}")
    except subprocess.CalledProcessError as error:
        raise ValueError(f"{source[:12]} carries no {APP / 'scripts/nightly.py'}, so it has "
                         "no release tooling to rebuild itself with") from error
    if "CHANNEL_ENDPOINTS" not in tooling:
        raise ValueError(
            f"{nightly_tag} was built from {source[:12]}, whose release tooling predates the "
            "stable channel, so that commit cannot build a stable release of itself.\n"
            "  Promote a nightly built from a commit that carries the stable channel; the "
            "first of those is the first nightly published after this landed.")
    identity()
    return {"build": True, "version": base, "tag": f"v{base}", "source_commit": source,
            "created_at": now.isoformat(),
            "run_id": os.environ.get("RICHOS_NIGHTLY_RUN_ID", "manual"), "run_attempt": "1",
            "channel": "stable", "platform": built["platform"],
            # Carried rather than respelled by the caller. `make-release.sh:173` reads the
            # nightly endpoint out of this module for the same reason: a second spelling of
            # one URL is a second thing to forget, and a check comparing a file against its
            # own copy of a value checks nothing.
            "endpoint": CHANNEL_ENDPOINTS["stable"],
            # The provenance of the promotion itself, carried into the release's own
            # `nightly-build.json` and its committed provenance: which nightly this is a
            # rebuild of, and the record of the decision that allowed it.
            "promoted_from": nightly_tag, "promoted_from_version": built["version"],
            "promotion_decided_on": decision["decided_on"],
            "promotion_words": decision["words"]}


def promote_stable(info):
    """Make the already-uploaded release the one `releases/latest` serves.

    ATOMIC PUBLISH-THEN-FLIP, and the order is the whole design. Every asset, including
    `latest.json`, is uploaded while the release is still a PRERELEASE -- and a prerelease
    is not `latest`, so nothing installed can see any of it however long the upload takes
    or however badly it fails. This one call is the flip. There is no window in which half
    a release is being served, and a crash before it leaves an invisible prerelease that
    can simply be re-run.

    Stable therefore needs no rolling channel tag and no compare-and-swap: GitHub's own
    `latest` pointer IS the channel, which is why `STABLE_ENDPOINT` is a `/releases/latest/`
    URL while the nightly endpoint has to name a tag.
    """
    verify_repository_rules()
    execute("gh", "release", "edit", info["tag"], "--repo", REPO,
            "--prerelease=false", "--latest", "--title", f"RichOS {info['version']}")


@release_step
def commit_files(files, parent, message, repo=None):
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
        git("read-tree", parent if parent else "--empty", cwd=repo, env=env)
        for name, contents in files.items():
            blob = git("hash-object", "-w", "--stdin", cwd=repo, input=contents)
            git("update-index", "--add", "--cacheinfo", f"100644,{blob},{name}",
                cwd=repo, env=env)
        tree = git("write-tree", cwd=repo, env=env)
        return git(*CONFIGURED_IDENTITY, "commit-tree", tree,
                   *(["-p", parent] if parent else []), cwd=repo, input=message + "\n",
                   env=env)


def prepare(info):
    version = info["version"]
    if git("rev-parse", "HEAD") != info["source_commit"] or git("status", "--porcelain"):
        raise ValueError("source changed after planning")
    tags = remote_tags()
    base = version.split("-", 1)[0]
    if info["tag"] in tags:
        raise ValueError("version is already reserved or its stable release exists")
    # A nightly must not outlive its base: `v1.2.0` existing means 1.2.0 shipped and the
    # tree should have moved on. A STABLE release IS `v{base}`, so the same check would
    # refuse every stable release there is; for stable the collision that matters is
    # `info["tag"] in tags` above, which is the same tag.
    if info["channel"] == "nightly" and f"v{base}" in tags:
        raise ValueError("version is already reserved or its stable release exists")
    # ONE ENTRY POINT, TWO CALLERS. The smoke calls this same function with the same three
    # files; see `release_step`'s note on why it is not two copies of one procedure.
    files = release_files(info, (ROOT / MANIFEST).read_text(), (ROOT / LOCK).read_text(),
                          (ROOT / CONFIG).read_text())
    commit = commit_files(files, info["source_commit"], f"Build {info['tag']}")
    # Creating a remote tag reserves the number even if the build later fails.
    # A competing writer cannot overwrite an existing tag. Never force a tag push.
    git("push", "origin", f"{commit}:refs/tags/{info['tag']}")
    git("fetch", "origin", f"refs/tags/{info['tag']}:refs/tags/{info['tag']}")
    git("checkout", "--detach", commit)
    return {**info, "build_commit": commit}


@release_step
def verify_manifest(info, manifest):
    """The updater metadata, checked against the build it claims to describe.

    Pulled out of `promote()` for the same reason `release_files` was pulled out of
    `prepare()`: these three checks are the last thing standing between a wrong
    `latest.json` and every installed copy fetching it, and they used to be reachable
    only by publishing. Now the smoke reaches them, in both directions -- a good manifest
    passes, and each of the three ways to be wrong is refused by name.
    """
    if manifest["version"] != info["version"]:
        raise ValueError("manifest version does not match the build")
    expected = f"https://github.com/{REPO}/releases/download/{info['tag']}/RichOS.app.tar.gz"
    if set(manifest["platforms"]) != {info["platform"]}:
        raise ValueError("manifest platforms do not match the built artifact")
    if manifest["platforms"][info["platform"]]["url"] != expected:
        raise ValueError("manifest must reference this immutable release")


def promote(info, manifest):
    verify_manifest(info, manifest)
    verify_repository_rules()
    old, previous = channel()
    if previous == info:
        # The channel already records exactly this candidate: a previous `finish` took
        # the lease and then failed at or after the asset upload. Re-running must REPAIR
        # the asset, not refuse this as a rollback -- so the lease is not re-taken and
        # the ordering checks below, which would (correctly) call this a move backwards,
        # are not reached. This is the only reason `finish` is safe to run twice.
        serve_channel_manifest(manifest)
        return old
    if previous:
        if nightly_key(info["version"]) <= nightly_key(previous["version"]):
            raise ValueError("refusing to replace an equal or newer nightly")
        git("merge-base", "--is-ancestor", previous["source_commit"], info["source_commit"])
    commit = commit_files({"latest.json": json_text(manifest), "build-info.json": json_text(info)},
                          old, f"Publish {info['tag']}")
    # The lease protects the read/check/write interval, including first publication.
    git("push", f"--force-with-lease={CHANNEL_REF}:{old or ''}",
        "origin", f"{commit}:{CHANNEL_REF}")
    serve_channel_manifest(manifest)
    return commit


def channel_release_notes():
    return (f"The RichOS nightly update channel.\n\n"
            f"`latest.json` on this release is the manifest every installed nightly "
            f"fetches. It is replaced on each publish and always names the newest "
            f"nightly build.\n\nThe nightly builds themselves are the `v*-nightly.*` "
            f"prereleases; this release deliberately carries no application archive, "
            f"and its tag moves.\n")


def serve_channel_manifest(manifest):
    """Put the manifest where installed nightlies fetch it: the rolling release's asset.

    The compare-and-swap in `promote` decides who may publish; this makes that decision
    visible to the world, and the two are not one atomic act. The order is chosen so
    that the failure which can actually happen is the recoverable one. Lease first,
    asset second: a crash in between leaves the channel tag naming a version whose
    asset was not replaced, `finish` exits non-zero, and re-running it reaches
    `promote`'s repair arm and re-uploads. The other order -- asset first -- would
    publish to the world a version no lease was ever taken for.

    `--verify-tag` on the create is why this runs AFTER the push: the rolling tag must
    already exist, and it exists because `promote` just moved it.
    """
    if not succeeds("gh", "release", "view", CHANNEL_TAG, "--repo", REPO):
        execute("gh", "release", "create", CHANNEL_TAG, "--repo", REPO, "--verify-tag",
                "--prerelease", "--latest=false", "--title", "RichOS nightly channel",
                "--notes", channel_release_notes())
    with tempfile.TemporaryDirectory(prefix="richos-channel-asset-") as tmp:
        path = Path(tmp) / "latest.json"
        path.write_text(json_text(manifest))
        execute("gh", "release", "upload", CHANNEL_TAG, "--repo", REPO, "--clobber",
                str(path))


def _candidate_files(out):
    """Every file under `out`, `candidate.json` itself excepted, as {relative path: sha256}."""
    return {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(out.rglob("*")) if p.is_file() and p.name != CANDIDATE_MANIFEST}


@release_step
def write_candidate_manifest(info, out):
    (out / CANDIDATE_MANIFEST).write_text(json_text({"info": info, "files": _candidate_files(out)}))


@release_step
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
    the update channel -- nobody can install what this produces until `finish` runs.
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
    if info["channel"] == "stable":
        verify_manifest(info, manifest)
        promote_stable(info)
        print(f"Published {info['tag']}, a rebuild of {info['promoted_from']}'s commit "
              f"{info['source_commit'][:12]}; it is now the latest release, serving\n"
              f"  {STABLE_ENDPOINT}", flush=True)
        return
    channel_commit = promote(info, manifest)
    print(f"Published {info['tag']}; {CHANNEL_REF} at {channel_commit}, serving\n"
          f"  {ENDPOINT}", flush=True)


def publish(info, out):
    """`build` then `finish`, in one motion -- what `release` still does."""
    build(info, out)
    finish(info, out)


# =======================================================================================
# THE SMOKE
# =======================================================================================

@contextlib.contextmanager
def hermetic_git(repo):
    """A git that answers from `repo` alone, with no operator identity reaching it.

    `commit_files` resolves its identity from git config, so a smoke run from a terminal
    that exports GIT_AUTHOR_EMAIL would build a fixture commit carrying a real person's
    address. Inside a build this cannot happen -- `nightly-local.py`'s gate environment is
    an allowlist and none of these names is on it -- but the smoke is also run by hand,
    and a gate whose answer depends on whose terminal started it is the exact defect the
    allowlist exists to prevent. So the smoke does for itself what the build does for it.
    """
    fixture = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
               "GIT_CONFIG_NOSYSTEM": "1"}
    removed = {name: os.environ.pop(name) for name in
               ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME",
                "GIT_COMMITTER_EMAIL", "EMAIL", "GIT_INDEX_FILE") if name in os.environ}
    os.environ.update(fixture)
    try:
        git("init", "-q", "-b", "main", str(repo), cwd=repo.parent)
        git("config", "user.name", "Release Smoke", cwd=repo)
        git("config", "user.email", "smoke@example.invalid", cwd=repo)
        yield
    finally:
        for name in fixture:
            os.environ.pop(name, None)
        os.environ.update(removed)


def release_smoke(out):
    """Run every release-only step against a throwaway release directory, and prove it.

    WHAT THIS IS FOR. A release-only step runs on no ordinary day, so it rots unseen and
    is found by the release that needed it. Running them here, on every build, means the
    release path is exercised roughly a hundred times before anybody releases anything.

    WHAT IS DELIBERATELY NOT IN IT, with the measurement, because a budget whose contents
    are not named is fiction:

      * ENGINE-ASSET PACKAGING. `make-engine-asset.test.sh` is 112 s in this same build's
        `gates/script-suites` (measured, run 20260920T022734Z-a21a8311), and the real
        `build` phase runs `make-release.sh engine` for every candidate regardless. It is
        neither release-only nor unexercised, and re-running it here would add ~112 s to
        buy a second copy of an answer this build already has.
      * SIGNING, NOTARIZATION AND UPLOAD. They need credentials and the network. A gate
        gets neither, by construction (see `split_credentials`).

    What IS in it is every step that decides the CONTENTS of a release and can be decided
    from text: the version resolved, the files the release commit carries, the commit
    itself, the candidate's recorded digests and the tamper check over them, the updater
    metadata, and the CEO's promotion decision. Each runs in both directions -- the good
    case AND each way to be wrong -- because a step that only ever sees valid input proves
    the refusals compile, not that they refuse.
    """
    out.mkdir(parents=True, exist_ok=True)
    # EVERY BYTE THIS WRITES IS REMOVED, however this ends (CEO ruling §54: garbage is
    # always cleaned up, and a mechanism rather than a habit). `TemporaryDirectory` does
    # that on the exception path too, which is the path that matters -- a gate that
    # refuses is a gate that left fixtures behind if it cleans up only on success. `out`
    # itself is a parent this never removes, so no caller can point it at something
    # precious and lose it.
    with tempfile.TemporaryDirectory(prefix="release-smoke-", dir=out) as tmp:
        return _release_smoke(Path(tmp))


def _release_smoke(work):
    for name in RELEASE_STEP_CALLS:
        RELEASE_STEP_CALLS[name] = 0
    checked = []

    def refuses(what, call):
        """A refusal is only evidence if it is the refusal we meant to provoke."""
        try:
            call()
        except (ValueError, KeyError):
            checked.append(f"refused: {what}")
            return
        raise ValueError(f"release-smoke: {what} was accepted, and must not be")

    # THE REAL FILES ARE THE FIXTURE'S INPUT. Their shapes are what the release rewrites,
    # so a change to Cargo.toml's version line or tauri.conf.json's updater block is
    # caught here in milliseconds rather than by a release.
    manifest_text = (ROOT / MANIFEST).read_text()
    lock_text = (ROOT / LOCK).read_text()
    config_text = (ROOT / CONFIG).read_text()
    base = tomllib.loads(manifest_text)["package"]["version"]

    # --- version resolution ---------------------------------------------------------
    day = "20260920"
    first = next_version(base, day, tags=set())
    third = next_version(base, day, tags={f"v{base}-nightly.{day}.1", f"v{base}-nightly.{day}.2"})
    if (first, third) != (f"{base}-nightly.{day}.1", f"{base}-nightly.{day}.3"):
        raise ValueError(f"release-smoke: version resolution produced {first} and {third}")
    if nightly_key(third) <= nightly_key(first):
        raise ValueError("release-smoke: nightly ordering is not monotonic")
    refuses("a version on a day that does not exist", lambda: next_version(base, "20260231", set()))
    refuses("a base version that is itself a prerelease",
            lambda: next_version(f"{base}-nightly.{day}.1", day, set()))
    checked.append(f"version resolution: {first}, then {third}")

    # --- the files a release commit carries, on both channels -------------------------
    nightly_info = {"build": True, "version": third, "tag": f"v{third}",
                    "source_commit": "0" * 40, "created_at": "2026-09-20T00:00:00+00:00",
                    "run_id": "smoke", "run_attempt": "1", "channel": "nightly",
                    "platform": "darwin-aarch64"}
    stable_info = {**nightly_info, "version": base, "tag": f"v{base}", "channel": "stable",
                   "promoted_from": f"v{third}"}

    nightly_files = release_files(nightly_info, manifest_text, lock_text, config_text)
    if f'version = "{third}"' not in nightly_files[str(MANIFEST)]:
        raise ValueError("release-smoke: the nightly version did not reach Cargo.toml")
    if f'version = "{third}"' not in nightly_files[str(LOCK)]:
        raise ValueError("release-smoke: the nightly version did not reach Cargo.lock")
    compiled = json.loads(nightly_files[str(CONFIG)])["plugins"]["updater"]["endpoints"]
    if compiled != [ENDPOINT]:
        raise ValueError(f"release-smoke: a nightly would compile in {compiled}")

    stable_files = release_files(stable_info, manifest_text, lock_text, config_text)
    if stable_files[str(MANIFEST)] != manifest_text or stable_files[str(LOCK)] != lock_text:
        raise ValueError("release-smoke: a stable release must carry the tree's own version")
    compiled = json.loads(stable_files[str(CONFIG)])["plugins"]["updater"]["endpoints"]
    if compiled != [STABLE_ENDPOINT]:
        raise ValueError(f"release-smoke: a stable release would compile in {compiled}")
    # The three spellings of the stable endpoint agree: this constant, the file checked
    # into the tree, and `make-release.sh:156`. `release_files` refuses on the second;
    # this asserts the first has not drifted from the third.
    if json.loads(config_text)["plugins"]["updater"]["endpoints"] != [STABLE_ENDPOINT]:
        raise ValueError("release-smoke: tauri.conf.json's endpoint is not STABLE_ENDPOINT")
    checked.append(f"compiled endpoints: nightly -> {ENDPOINT}")
    checked.append(f"compiled endpoints: stable  -> {STABLE_ENDPOINT}")

    refuses("a channel nobody defined",
            lambda: release_files({**nightly_info, "channel": "preview"},
                                  manifest_text, lock_text, config_text))
    refuses("a stable release carrying a prerelease version",
            lambda: release_files({**stable_info, "version": third, "tag": f"v{third}"},
                                  manifest_text, lock_text, config_text))
    refuses("a nightly whose tag and version disagree",
            lambda: release_files({**nightly_info, "tag": "v9.9.9"},
                                  manifest_text, lock_text, config_text))
    refuses("a tauri.conf.json that pins its own version",
            lambda: release_files(nightly_info, manifest_text, lock_text,
                                  json_text({**json.loads(config_text), "version": base})))
    refuses("a stable release whose compiled endpoint is not the stable channel",
            lambda: release_files(stable_info, manifest_text, lock_text, json_text(
                {**json.loads(config_text), "plugins": {"updater": {"endpoints": [ENDPOINT]}}})))

    # --- the release commit itself ----------------------------------------------------
    repo = work / "fixture-repo"
    repo.mkdir()
    with hermetic_git(repo):
        (repo / "seed").write_text("fixture\n")
        git("add", "seed", cwd=repo)
        git("commit", "-q", "-m", "seed", cwd=repo)
        parent = git("rev-parse", "HEAD", cwd=repo)
        commit = commit_files(nightly_files, parent, f"Build {nightly_info['tag']}", repo=repo)
        for name, contents in nightly_files.items():
            if git("show", f"{commit}:{name}", cwd=repo) != contents.rstrip("\n"):
                raise ValueError(f"release-smoke: {name} is not what the commit carries")
        # The release commit adds files and destroys nothing: the parent's tree survives.
        if git("show", f"{commit}:seed", cwd=repo) != "fixture":
            raise ValueError("release-smoke: the release commit lost the parent's tree")
    checked.append(f"release commit carries {len(nightly_files)} files over its parent")

    # --- the candidate's recorded bytes, and the tamper check over them ---------------
    candidate = work / "candidate"
    candidate.mkdir()
    (candidate / "RichOS.app.tar.gz").write_bytes(b"fixture artifact")
    (candidate / "RichOS.app.tar.gz.sig").write_bytes(b"fixture signature")
    (candidate / "latest.json").write_text(json_text({"version": third}))
    write_candidate_manifest(nightly_info, candidate)
    verify_candidate_manifest(nightly_info, candidate)
    refuses("a candidate built for a different plan",
            lambda: verify_candidate_manifest({**nightly_info, "version": first}, candidate))
    (candidate / "RichOS.app.tar.gz").write_bytes(b"fixture artifact, tampered")
    refuses("a candidate whose bytes changed after it was recorded",
            lambda: verify_candidate_manifest(nightly_info, candidate))
    (candidate / "RichOS.app.tar.gz").unlink()
    refuses("a candidate missing a file it recorded",
            lambda: verify_candidate_manifest(nightly_info, candidate))
    refuses("a directory that was never built here",
            lambda: verify_candidate_manifest(nightly_info, work / "never-built"))
    checked.append("candidate digests: recorded, verified, and every tamper refused")

    # --- the updater metadata every installed copy fetches ----------------------------
    good = {"version": third, "platforms": {"darwin-aarch64": {"url": (
        f"https://github.com/{REPO}/releases/download/v{third}/RichOS.app.tar.gz")}}}
    verify_manifest(nightly_info, good)
    refuses("a manifest naming another version",
            lambda: verify_manifest(nightly_info, {**good, "version": first}))
    refuses("a manifest naming another platform", lambda: verify_manifest(
        nightly_info, {**good, "platforms": {"windows-x86_64": good["platforms"]["darwin-aarch64"]}}))
    refuses("a manifest pointing at a mutable URL", lambda: verify_manifest(
        nightly_info, {**good, "platforms": {"darwin-aarch64": {"url": STABLE_ENDPOINT}}}))
    checked.append("updater manifest: verified, and every mismatch refused")

    # --- the CEO's promotion decision (ceo-decisions §69) -----------------------------
    tag = f"v{third}"
    decided = json_text([{"tag": tag, "decided_on": "2026-09-20",
                          "words": "a fixture standing in for his sentence"}])
    if promotion_decision(tag, decided)["tag"] != tag:
        raise ValueError("release-smoke: a recorded decision was not returned")
    refuses("a stable build of a nightly he has not promoted",
            lambda: promotion_decision("v1.2.0-nightly.20260101.1", decided))
    refuses("an empty promotion record", lambda: promotion_decision(tag, "[]"))
    refuses("a promotion record that is not JSON", lambda: promotion_decision(tag, "yes"))
    refuses("a promotion record that is not a list", lambda: promotion_decision(tag, "{}"))
    refuses("a decision recording no words of his", lambda: promotion_decision(
        tag, json_text([{"tag": tag, "decided_on": "2026-09-20", "words": "  "}])))
    refuses("a decision with no date", lambda: promotion_decision(
        tag, json_text([{"tag": tag, "decided_on": "", "words": "x"}])))
    refuses("a decision dated impossibly", lambda: promotion_decision(
        tag, json_text([{"tag": tag, "decided_on": "2026-02-31", "words": "x"}])))
    refuses("two decisions for one nightly", lambda: promotion_decision(
        tag, json_text([{"tag": tag, "decided_on": "2026-09-20", "words": "x"},
                        {"tag": tag, "decided_on": "2026-09-21", "words": "y"}])))
    checked.append("promotion decision: his record honored, every substitute refused")

    # --- COMPLETENESS: the check that keeps this from becoming T3's smoke -------------
    #
    # Everything above can be correct and still decay, one commit at a time, into a smoke
    # that exercises less than the release does -- which is the position T3's own smoke is
    # in today. This is what makes that impossible: not "did the steps pass" but "was
    # every registered step reached at all". Add a `@release_step` and forget it here, and
    # the build fails naming your function.
    unreached = sorted(name for name, calls in RELEASE_STEP_CALLS.items() if not calls)
    if unreached:
        raise ValueError(
            "release-smoke: these release-only steps were never reached, so this smoke no "
            "longer exercises what a release runs:\n  " + "\n  ".join(unreached) +
            "\nAdd each to release_smoke() -- with its refusals, not only its happy path.")
    print(f"release-smoke: {len(RELEASE_STEPS)} release-only steps, all reached")
    for line in checked:
        print(f"  {line}")


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
    sub.add_parser("check-rules")
    p = sub.add_parser("release-smoke")
    p.add_argument("--out", type=Path, required=True,
                   help="a throwaway directory; everything written under it is fixture")
    p = sub.add_parser("stable-plan")
    p.add_argument("--from-nightly", required=True, metavar="TAG")
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("run")
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "release-smoke":
        release_smoke(args.out.resolve())
    elif args.command == "stable-plan":
        info = stable_plan(args.from_nightly, (ROOT / PROMOTIONS).read_text()
                           if (ROOT / PROMOTIONS).exists() else "[]")
        args.output.write_text(json_text(info))
        print(json_text(info))
    elif args.command == "check-rules":
        # The runner calls this in preflight so a widened ruleset costs seconds rather
        # than forty minutes of gates; `promote` calls it again immediately before the
        # channel moves, because preflight's answer can go stale in between.
        verify_repository_rules()
        print(f"{RULESET}: every branch but main is refused creation and update.")
    elif args.command == "plan":
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
