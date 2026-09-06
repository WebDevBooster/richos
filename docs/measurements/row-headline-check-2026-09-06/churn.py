#!/usr/bin/env python3
"""How often would CHECK 3 fire on an ordinary day, over the record's real life?

replay.py answers "would it have caught the defect". This answers the question
that actually decides whether a check survives: what does it cost when nothing
is wrong. A check nobody can satisfy without hand-writing prose at every land
is waived into uselessness inside a week, and this project has three recorded
instances of exactly that in a single day.

For every commit that ever touched wiki/open-items.md, every governed
non-terminal row whose normalized body changed is one firing. Each is then
classified:

  SUBSTANCE  the prose changed. Nobody argues about these.
  PIN-ONLY   the only thing that changed is an object id inside a warrant.
             This is the arguable class, and it is INCLUDED on purpose: a
             person re-stamping a pin has just been told the work moved, which
             is the best moment there will ever be to ask whether the headline
             about that work is still true. Re-stamping is not re-reading.

Reproduce:

    python3 docs/measurements/row-headline-check-2026-09-06/churn.py

Output as recorded on 2026-09-06 is in results/churn.txt.
"""
import importlib.util
import pathlib
import re
import subprocess

HQ = "/Users/alex/ab/richos-hq"
# Resolved from this file, never typed: run inside a worktree it must
# measure THAT tree's predicate, or the number is about code nobody has.
PREDICATE = str(pathlib.Path(__file__).resolve().parents[3]
                / "engine" / "scripts" / "lib" / "row-currency.py")
REC = "wiki/open-items.md"

spec = importlib.util.spec_from_file_location("rc", PREDICATE)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

OID = re.compile(r"@`[0-9a-f]{6,40}`")


def at(rev):
    p = subprocess.run(["git", "-C", HQ, "show", "%s:%s" % (rev, REC)],
                       capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


revs = subprocess.run(
    ["git", "-C", HQ, "log", "--format=%h %s", "--reverse", "--", REC],
    capture_output=True, text=True, check=True).stdout.strip().split("\n")

prev = None
lands = fires = pin_only = substance = 0
per_land = []
for entry in revs:
    rev, subject = entry.split(" ", 1)
    text = at(rev)
    if text is None:
        continue
    items, _, _ = rc.parse_record(text, ["3"], (), ["3"])
    now = {}
    for it in items:
        if not it.get("headlined"):
            continue
        sm = rc.STATUS_RE.match(rc.warrant_of(it) or "")
        if sm and sm.group("tok") == "CLOSED":
            continue
        now[it["id"]] = rc.span_text(it)
    if prev is not None:
        changed = [i for i in now if i in prev
                   and rc.headline_digest({"span": now[i].split("\n")})
                   != rc.headline_digest({"span": prev[i].split("\n")})]
        if changed:
            lands += 1
            fires += len(changed)
            po = [i for i in changed
                  if OID.sub("@`X`", now[i]).replace(" ", "")
                  == OID.sub("@`X`", prev[i]).replace(" ", "")]
            pin_only += len(po)
            substance += len(changed) - len(po)
            per_land.append((rev, len(changed), len(po), subject[:58]))
    prev = now

per = sorted(x[1] for x in per_land)
print("commits touching %s          : %d" % (REC, len(revs)))
print("landings that would have fired : %d" % lands)
print("row-firings in total           : %d" % fires)
print("  of which SUBSTANCE           : %d" % substance)
print("  of which PIN-ONLY            : %d" % pin_only)
print("median rows per firing landing : %d" % (per[len(per) // 2] if per else 0))
print("largest single landing         : %d" % (per[-1] if per else 0))
print("")
for rev, n, po, subject in per_land:
    print("  %s  %2d row(s) (%d pin-only)  %s" % (rev, n, po, subject))
