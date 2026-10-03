#!/usr/bin/env python3
"""shipgate.py — no RichConnect build reaches users without passing the phone speed test.

THE CEO, 2026-10-03 (richos-hq/wiki/ceo-decisions.md §106): "The important part is to make sure that
we NEVER publish (or push to App Stores etc) any mobile apps if the speed is above the limit. I know we
haven't put anything into App Stores yet, but when we do, nothing can get to the actual users without
passing the speed tests. Make sure of that."

Every path that makes a RichConnect build users can get calls this first and stops when it refuses:
  Android  `randroid bundle`                  the signed .aab for Google Play
  iPhone   `node Release/testflight.ts upload`   the App Store Connect export and upload
           `node Release/testflight.ts publish`  putting an uploaded build in a TestFlight group

It passes only when the phone speed watch (watch.py) has a §104 PASS, cold AND warm, for that exact app
code on that platform's test phone:
  - measured.json, the watch's LAST judged measurement of that phone, says "good";
  - the record it names is on disk, was measured on a committed build, and its cold and warm series
    pass the CURRENT limits in perfcore.py when judged again here (a limit tightened since the
    measurement refuses a build that only passed the old one);
  - the commit that record measured has the same app code as the build being shipped: no path that
    builds into that phone's app (watch.is_app_code) differs between the two commits;
  - and, for a build made from a checkout's working tree, that tree has no uncommitted app code.

It fails closed: a missing, unreadable or malformed verdict file, a missing record, a commit this
repository does not have, or anything it cannot read refuses, naming the platform, the commit and
what is missing or failing. There is no skip flag and no environment switch; the verdicts are read
from the watch's fixed state directory.

  shipgate.py check --platform android|ios --checkout DIR      the build is DIR's working tree (HEAD)
  shipgate.py check --platform android|ios --repo DIR --commit SHA   the build is that commit
Exit 0 and one PASS line on stdout, or exit 1 and one REFUSED line on stderr.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perfcore  # noqa: E402
import watch  # noqa: E402

LABEL = {"android": "Android", "ios": "iPhone"}


class Refused(Exception):
    """The build may not reach users; the sentence says why."""


def _git(repo, *args):
    p = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                       env=watch.plain_env(), stdin=subprocess.DEVNULL)
    if p.returncode:
        raise Refused(f"git {' '.join(args)} failed in {repo}: {p.stderr.strip()[:200]}")
    return p.stdout


def _commit(repo, ref):
    """The full commit `ref` names in `repo`, or "" when it names none."""
    p = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                       capture_output=True, text=True, env=watch.plain_env(), stdin=subprocess.DEVNULL)
    return p.stdout.strip() if p.returncode == 0 else ""


def uncommitted_app_code(platform, repo):
    """Paths of `platform`'s app code with uncommitted changes (staged, unstaged or untracked)."""
    out = _git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
               "--", watch.APP_DIR[platform])
    return [entry[3:] for entry in out.split("\0") if entry and watch.is_app_code(platform, entry[3:])]


def app_code_differences(platform, repo, a, b):
    out = _git(repo, "diff", "--name-only", "--no-renames", a, b, "--", watch.APP_DIR[platform])
    return [p for p in out.split() if watch.is_app_code(platform, p)]


def _verdict_entry(platform, home):
    path = Path(home) / "measured.json"
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        raise Refused(f"no speed verdict file: {path} does not exist") from None
    except (OSError, ValueError) as exc:
        raise Refused(f"the speed verdict file {path} is unreadable ({exc})") from None
    entry = data.get(platform) if isinstance(data, dict) else None
    if not isinstance(entry, dict):
        raise Refused(f"no {LABEL[platform]} speed verdict in {path}")
    return path, entry


def _record(platform, entry, verdicts):
    name = entry.get("record")
    if not isinstance(name, str) or not name:
        raise Refused(f"the {LABEL[platform]} verdict in {verdicts} names no measurement record")
    try:
        data = json.loads(Path(name).read_text())
    except (OSError, ValueError) as exc:
        raise Refused(f"the {LABEL[platform]} measurement record {name} is missing or unreadable ({exc})") from None
    build = data.get("build") if isinstance(data, dict) else None
    if not isinstance(build, dict) or not isinstance(build.get("commit"), str) or not build["commit"]:
        raise Refused(f"the {LABEL[platform]} measurement record {name} does not say which commit it measured")
    if build.get("dirty") is not False:
        raise Refused(f"the {LABEL[platform]} measurement record {name} measured uncommitted code")
    return name, data, build["commit"]


def _judge_again(platform, data, name):
    """The §104 cold and warm verdicts of the record, judged here against the current limits."""
    try:
        cold = perfcore.cold_standard(platform, data)
        recorded = perfcore.warm_standard(data)
        warm = perfcore.warm_verdict(platform, list(recorded.get("startsMs") or []))
    except (perfcore.NoVerdict, perfcore.LimitNotSet) as exc:
        raise Refused(f"the {LABEL[platform]} measurement record {name} gives no §104 verdict: {exc}") from None
    failing = [perfcore.standard_line(k, v) for k, v in (("cold", cold), ("warm", warm)) if v["verdict"] != "PASS"]
    if failing:
        raise Refused(f"the {LABEL[platform]} start does not pass §104: {'; '.join(failing)}")
    return cold, warm


def check(platform, repo, commit=None, checkout=False, home=watch.DEFAULT_HOME):
    """Return the PASS sentence, or raise Refused. `checkout`: the build is `repo`'s working tree at HEAD."""
    if platform not in watch.APP_DIR:
        raise Refused(f"unknown platform {platform!r}")
    repo = _git(repo, "rev-parse", "--show-toplevel").strip()  # the app paths are repository-relative
    ref = "HEAD" if checkout else commit
    if not ref:
        raise Refused("no commit named for the build")
    sha = _commit(repo, ref)
    if not sha:
        raise Refused(f"{LABEL[platform]} build: {ref} is not a commit in {repo}")
    what = f"{LABEL[platform]} build of {sha[:12]}"
    try:
        if checkout:
            dirty = uncommitted_app_code(platform, repo)
            if dirty:
                raise Refused(f"uncommitted app code matches no measured commit ({len(dirty)} paths: "
                              f"{', '.join(dirty[:5])}{', ...' if len(dirty) > 5 else ''}); commit it and let the "
                              f"speed watch measure it")
        verdicts, entry = _verdict_entry(platform, home)
        if entry.get("verdict") != "good":
            raise Refused(f"the {LABEL[platform]} phone's last speed verdict ({verdicts}) is "
                          f"{entry.get('verdict')!r}, not a pass")
        name, data, measured = _record(platform, entry, verdicts)
        if not _commit(repo, measured):
            raise Refused(f"the speed verdict measured commit {measured[:12]}, which this repository does not have")
        differs = app_code_differences(platform, repo, measured, sha)
        if differs:
            raise Refused(f"the speed verdict is for different app code: it measured {measured[:12]}, and "
                          f"{len(differs)} app-code paths differ ({', '.join(differs[:5])}"
                          f"{', ...' if len(differs) > 5 else ''}); the speed watch has not measured this code")
        cold, warm = _judge_again(platform, data, name)
    except Refused as exc:
        raise Refused(f"{what}: {exc}") from None
    return (f"{what}: §104 PASS on the {LABEL[platform]} test phone, measured at {measured[:12]} (same app code); "
            f"{perfcore.standard_line('cold', cold)}; {perfcore.standard_line('warm', warm)}")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="shipgate.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--platform", required=True, choices=sorted(watch.APP_DIR))
    where = c.add_mutually_exclusive_group(required=True)
    where.add_argument("--checkout", help="the build is this checkout's working tree at HEAD")
    where.add_argument("--repo", help="a checkout holding --commit")
    c.add_argument("--commit", help="with --repo: the build's source commit")
    args = ap.parse_args(argv)
    if args.repo and not args.commit:
        ap.error("--repo needs --commit")
    try:
        line = check(args.platform, args.checkout or args.repo, commit=args.commit, checkout=bool(args.checkout))
    except Refused as exc:
        print(f"REFUSED by the speed gate (CEO §106): {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — anything unexpected refuses, never allows
        print(f"REFUSED by the speed gate (CEO §106): {args.platform}: the gate itself failed: "
              f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    print(f"speed gate: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
