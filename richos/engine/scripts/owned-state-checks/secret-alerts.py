#!/usr/bin/env python3
"""secret-alerts.py — IS ANY GITHUB SECRET-SCANNING ALERT OPEN ON A GOVERNED REPOSITORY?

The `secretalerts` row of owned-systems.declaration. On 2026-10-03 two alerts sat
open on the public richos repository for 14 days, visible to every visitor,
because nothing told anyone they existed.

Exit 0 none open, 1 one or more open (each printed: number, secret type, link),
2 the question could not be answered (no gh, no repository, every call failed).
2 is never 0: "nothing is open" and "nothing was read" stay different answers.

The repositories are the same ones the CI row reads (ci-surface.discover_repos).
Set GH_BIN to use another gh (the test does).
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SURFACE = os.path.join(HERE, "..", "lib", "ci-surface.py")


def repos(explicit):
    spec = importlib.util.spec_from_file_location("ci_surface", SURFACE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    blind = mod.Blind()
    anchor = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
    return [slug for _r, slug, _s in mod.discover_repos(explicit, blind, anchor)]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", action="append", default=[])
    args = ap.parse_args(argv)
    gh = os.environ.get("GH_BIN", "gh")
    slugs = repos(args.repo)
    if not slugs:
        print("secret-alerts: no governed repository was discovered, so nothing was checked")
        return 2
    open_alerts, failed = [], []
    for slug in slugs:
        try:
            # Public repositories only: a private one is not on show, and secret
            # scanning is often not enabled there (the call fails, which would
            # make this row permanently unknown).
            v = subprocess.run([gh, "api", "repos/%s" % slug], capture_output=True,
                               text=True, timeout=30)
            if v.returncode == 0 and json.loads(v.stdout).get("private") is True:
                continue
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            pass  # visibility unknown: fall through and read the alerts
        try:
            p = subprocess.run([gh, "api", "--paginate",
                                "repos/%s/secret-scanning/alerts?state=open&per_page=100" % slug],
                               capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as exc:
            failed.append("%s (%s)" % (slug, exc.__class__.__name__))
            continue
        if p.returncode != 0:
            failed.append("%s (gh exited %d)" % (slug, p.returncode))
            continue
        try:
            # --paginate may print several JSON arrays back to back.
            dec, text, i = json.JSONDecoder(), p.stdout, 0
            while i < len(text):
                if text[i].isspace():
                    i += 1
                    continue
                obj, i = dec.raw_decode(text, i)
                open_alerts += [(slug, a) for a in obj]
        except (ValueError, TypeError):
            failed.append("%s (unparseable answer)" % slug)
    for slug, a in open_alerts:
        print("OPEN SECRET ALERT  %s #%s  %s  %s" % (
            slug, a.get("number"),
            a.get("secret_type_display_name") or a.get("secret_type"), a.get("html_url")))
    for f in failed:
        print("could not read secret-scanning alerts: %s" % f)
    if open_alerts:
        return 1
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
