#!/usr/bin/env python3
"""Would CHECK 3 have fired at the landing that produced the finding?

On 2026-09-06 `reed-opus-rc1` re-derived all 35 rows of richos-hq's
wiki/open-items.md and found 16 overtaken. ELEVEN OF THE SIXTEEN HAD A MATCHING
BLOB PIN, so CHECK 1 — the pin — was green throughout. This replays that exact
landing against CHECK 3.

  PASS A   the record as it stands, CHECK 3 not declared: the silent case.
  PASS A'  the same record with the declaration on, nothing adopted: what
           adoption day costs.
  PASS B   THE REPLAY. Headline warrants adopted mechanically on the record as
           it stood at `0dd172a` (the commit before Reed's pass), carried
           forward onto the record at `a45aebd` (after it landed), and checked.
           Compared against ground truth from the diff.

Reproduce (paths are this machine's; adjust the two constants):

    python3 docs/measurements/row-headline-check-2026-09-06/replay.py

Output as recorded on 2026-09-06 is in results/replay.txt.
"""
import importlib.util
import pathlib
import json
import subprocess
import sys

HQ = "/Users/alex/ab/richos-hq"
# Resolved from this file, never typed: run inside a worktree it must
# measure THAT tree's predicate, or the number is about code nobody has.
PREDICATE = str(pathlib.Path(__file__).resolve().parents[3]
                / "engine" / "scripts" / "lib" / "row-currency.py")
REC = "wiki/open-items.md"
BEFORE, AFTER = "0dd172a", "a45aebd"

spec = importlib.util.spec_from_file_location("rc", PREDICATE)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)


def at(rev):
    return subprocess.run(["git", "-C", HQ, "show", "%s:%s" % (rev, REC)],
                          capture_output=True, text=True, check=True).stdout


def run_job(text, headline_sections):
    job = {
        "record_label": REC,
        "record_text": text,
        "row_sections": ["3"],
        "headline_sections": headline_sections,
        "headline_required": False,
        "premise_sections": [],
        "status_tokens": ["OPEN", "BUILT", "BOUNDED", "BLOCKED-ON-RICH", "CLOSED"],
        "terminal_tokens": ["CLOSED"],
        "artifact_roots": {},
        # CHECK 1's pins are not under test here and are declared absent rather
        # than left to fail for an unrelated reason — a measurement that goes
        # red at the wrong assertion measures nothing.
        "absent_roots": {"richos-hq": "not under test in this measurement",
                         "richos": "not under test in this measurement",
                         "femcboost": "not under test in this measurement"},
        "identity_revs": {}, "message": None, "baselines": [],
    }
    p = subprocess.run(["python3", PREDICATE, "-"], input=json.dumps(job),
                       capture_output=True, text=True)
    return p.stdout


def codes(out):
    hits = {}
    for line in out.split("\n"):
        f = line.split("\t")
        if f and f[0] == "V" and len(f) > 2 and f[2].startswith("HEADLINE-"):
            hits.setdefault(f[2], []).append(f[1])
    return hits


def census(out):
    for line in out.split("\n"):
        if line.startswith("HC\t"):
            return line.replace("\t", "  ")
    return "<no HC line>"


def stamp(text, evidence):
    """One-time adoption: every governed non-terminal row gets the warrant it
    deserves AS IT STANDS. This is the step ROW_SECTIONS itself once took; it
    is not a re-stamp command and there is deliberately none of those."""
    items, _, _ = rc.parse_record(text, ["3"], (), ["3"])
    lines = text.split("\n")
    n = 0
    for it in items:
        if not it.get("headlined") or it["shape"] != "table":
            continue
        sm = rc.STATUS_RE.match(rc.warrant_of(it) or "")
        if sm and sm.group("tok") == "CLOSED":
            continue
        line = lines[it["line0"] - 1].rstrip()
        lines[it["line0"] - 1] = line[:-1] + " **Headline:** `%s` - %s |" % (
            rc.headline_digest(it), evidence)
        n += 1
    return "\n".join(lines), n


EVID = 'unverified "adopted mechanically by this harness, not read by a person"'

print("PASS A — the record at %s, CHECK 3 NOT declared" % AFTER)
out = run_job(at(AFTER), [])
print(" ", census(out))
print("  headline violations:", codes(out) or "none")

print("\nPASS A' — the same record, declared over section 3, nothing adopted")
out = run_job(at(AFTER), ["3"])
print(" ", census(out))
print("  blocking violations:", codes(out) or "none")

print("\nPASS B — THE REPLAY: adopted at %s, carried onto %s" % (BEFORE, AFTER))
before_stamped, n = stamp(at(BEFORE), EVID)
print("  adopted on %d governed non-terminal rows" % n)

out = run_job(before_stamped, ["3"])
print("  control, the stamped record against itself:", census(out))
print("  violations:", codes(out) or "none   <- THE SILENT CASE")

b_items, _, _ = rc.parse_record(before_stamped, ["3"], (), ["3"])
warrants = {i["id"]: rc.headline_body(i) for i in b_items if rc.headline_body(i)}
after_text = at(AFTER)
a_items, _, _ = rc.parse_record(after_text, ["3"], (), ["3"])
lines = after_text.split("\n")
for it in a_items:
    if it["id"] in warrants and it["shape"] == "table":
        line = lines[it["line0"] - 1].rstrip()
        lines[it["line0"] - 1] = line[:-1] + " **Headline:** %s |" % warrants[it["id"]]
carried = "\n".join(lines)

out = run_job(carried, ["3"])
print(" ", census(out))
fired = codes(out).get("HEADLINE-STALE", [])
print("  HEADLINE-STALE: %d rows: %s" % (len(fired), " ".join(fired)))

b_digests = {i["id"]: rc.headline_digest(i) for i in b_items}
a2, _, _ = rc.parse_record(carried, ["3"], (), ["3"])
changed = [i["id"] for i in a2
           if i["id"] in b_digests and rc.headline_digest(i) != b_digests[i["id"]]]
untouched = [i["id"] for i in a2
             if i["id"] in b_digests and rc.headline_digest(i) == b_digests[i["id"]]]
rederived = [i["id"] for i in a2 if "RE-DERIVED 2026-09-06" in rc.span_text(i)]
print("\n  ground truth from the diff")
print("    rows changed by that land : %d" % len(changed))
print("    rows left untouched       : %d (all silent)" % len(untouched))
print("    fired == changed          :", sorted(fired) == sorted(changed))
print("    of the fired rows, how many carry Reed's own RE-DERIVED marker: %d/%d"
      % (len(set(fired) & set(rederived)), len(fired)))
sys.exit(0)
