#!/usr/bin/env python3
"""DID A STALE ROW REACH main THROUGH THE g8 GAP?

Replays the row-currency predicate over every commit on richos-hq's main since
the .row-currency declaration was committed, using the SAME parser the guard
uses (scripts/lib/row-currency.py, imported, not reimplemented).

Scope, stated so the number is not read as more than it is: only warrants that
pin a path in richos-hq ITSELF (`richos-hq/...`) can be replayed exactly — the
record and the artifact are then in one tree at one commit. Warrants pinning
`richos/...` or `femcboost/...` would need a contemporaneous checkout of
another repository and are NOT replayed here.
"""
import importlib.util
import os
import subprocess
import sys

LIB = os.environ.get("RICHOS_ROW_CURRENCY_PY",
                    os.path.expanduser("~/.claude/richos-engine/scripts/lib/row-currency.py"))
REPO = "/Users/alex/ab/richos-hq"
RECORD = "wiki/open-items.md"
SINCE = "2026-08-30"

spec = importlib.util.spec_from_file_location("rc", LIB)
rc = importlib.util.module_from_spec(spec)
sys.modules["rc"] = rc
spec.loader.exec_module(rc)


def git(args):
    p = subprocess.run(["git", "-C", REPO] + args, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


revs = git(["log", "--first-parent", "--since=" + SINCE, "--format=%H %cI", "main"])
rows = [l.split(" ", 1) for l in revs.strip().split("\n") if l.strip()]
rows.reverse()
print("commits on richos-hq main since", SINCE, ":", len(rows))

stale_commits = []
checked = 0
for sha, when in rows:
    text = git(["show", "%s:%s" % (sha, RECORD)])
    if text is None:
        continue
    items, violations, seen = rc.parse_record(text, ["3"])
    bad = []
    for it in items:
        if not it.get("governed"):
            continue
        w = rc.warrant_of(it)
        if not w:
            continue
        body = w
        tokm = rc.STATUS_RE.match(body)
        tok = tokm.group("tok") if tokm else ""
        if tok in ("CLOSED",):
            continue
        for m in rc.STAMP_RE.finditer(body):
            path, oid = m.group("path"), m.group("oid")
            if not path.startswith("richos-hq/"):
                continue
            rel = path[len("richos-hq/"):]
            actual = rc.identity(REPO, sha, rel)
            if actual is None:
                continue
            if oid == rc.ABSENT:
                if actual != rc.ABSENT:
                    bad.append((it["id"], path, oid, actual[:12]))
                continue
            if actual == rc.ABSENT:
                bad.append((it["id"], path, oid, "ABSENT"))
            elif not actual.startswith(oid):
                bad.append((it["id"], path, oid, actual[:12]))
    checked += 1
    if bad:
        stale_commits.append((sha, when, bad))

print("commits whose tree carried a readable record:", checked)
print("commits that LANDED WITH A STALE richos-hq-internal ROW:", len(stale_commits))
print()
for sha, when, bad in stale_commits:
    subj = (git(["log", "-1", "--format=%s", sha]) or "").strip()
    print("%s  %s  %s" % (sha[:12], when, subj[:80]))
    for iid, path, oid, actual in bad:
        print("      row %-6s %s  stamped @%s  actually %s" % (iid, path, oid, actual))
