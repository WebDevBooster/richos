#!/usr/bin/env python3
"""ci-receipts.py — write and CHECK the receipts a sharded verification leaves.

WHY THIS IS A SEPARATE, TESTED THING

A serial runner proves its own coverage by construction: it printed "117/121"
because it iterated 121 things. A sharded runner cannot. Twelve jobs each
exiting 0 is not the same claim, and the difference is exactly where a green
tick over an unverified commit comes from:

  * a matrix entry that never started (the job list shows eleven, and nobody
    counts job lists),
  * a shard whose selector matched nothing and exited 0,
  * a section id that was renamed, so its unit silently left the plan,
  * two shards that checked out different commits,
  * a job stopped by a concurrency rule while its siblings went green.

So the shards emit receipts and this module reads them back and answers ONE
question: is the union of what actually ran EQUAL to the planned inventory, at
ONE commit, with every unit reaching a verdict that counts as green? Anything
else is named, with the missing unit ids printed, and exits non-zero.

WHAT COUNTS AS GREEN, declared here once so no caller re-decides it:

  PASS        the unit exited its expected code (0 for a suite, 3 for a
              scoped section).
  KNOWN-RED   the unit failed exactly as `lib/ci-known-red.tsv` declares it
              will, the entry has not expired. Reported, never silent.

Everything else — FAIL, LEAKED, RECORD-TOUCHED, CANARY-BLIND, SCOPE-LOST,
KNOWN-RED-BUT-PASSED, KNOWN-RED-EXPIRED — is red, and each name says what
went wrong rather than only that something did.

Usage:
    ci-receipts.py emit                    one JSON line, fields from UNIT_* env
    ci-receipts.py verify --plan <file>    receipts on stdin, plan ids in <file>

Exit codes:
    0  the union equals the plan and every verdict is green
    1  a unit is missing, unplanned, red, or the commits disagree
    2  usage, or a receipt line that cannot be parsed
"""
import json
import os
import sys

GREEN = ("PASS", "KNOWN-RED")


def emit():
    """One receipt line. Every field is required: a receipt with a missing
    unit id would be a record of nothing, and `verify` would count it."""
    try:
        rec = {
            "unit": os.environ["UNIT_ID"],
            "rc": int(os.environ["UNIT_RC"]),
            "expected_rc": int(os.environ["UNIT_EXP"]),
            "verdict": os.environ["UNIT_VERDICT"],
            "seconds": float(os.environ["UNIT_SECS"]),
            "shard": int(os.environ.get("UNIT_SHARD") or 0),
            "shards": int(os.environ.get("UNIT_SHARDS") or 0),
            "sha": os.environ["UNIT_SHA"],
        }
    except KeyError as exc:
        sys.stderr.write("ci-receipts.py emit: missing environment variable %s\n" % exc)
        return 2
    except ValueError as exc:
        sys.stderr.write("ci-receipts.py emit: unparseable numeric field: %s\n" % exc)
        return 2
    sys.stdout.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


def reweigh(ran, weights_path, emit_path):
    """The whole-run answer to 'is lib/ci-unit-weights.tsv still true?'.

    THE PROBLEM THIS REPLACES was a sentence. The closing line of verify() used
    to read `re-pack against measured cost with: ci-receipts.py verify ...
    (durations above)`, and there were no durations above. Re-measuring was
    therefore a person downloading twelve job logs and doing arithmetic, so
    nobody did it, so 32 of 137 units sat at DEFAULT_WEIGHT for days while one
    of them — 2811.7 s against a 60 s assumption — was the wall clock of every
    push.

    A MAINTENANCE STEP THAT NEEDS A HUMAN EYE IS A MAINTENANCE STEP THAT DOES
    NOT HAPPEN. So this writes the finished file. The reader downloads an
    artifact and commits it; there is no arithmetic left and nothing to
    remember.

    It never changes an exit code. A weight cannot make a green wrong — it
    decides only which machine runs what — and a coverage job that went red
    over packing balance would be waived within a week.
    """
    planned = {}
    if weights_path:
        try:
            with open(weights_path, encoding="utf-8") as fh:
                for ln in fh:
                    if ln.startswith("#") or "\t" not in ln:
                        continue
                    parts = ln.rstrip("\n").split("\t")
                    try:
                        planned[parts[0]] = float(parts[1])
                    except (IndexError, ValueError):
                        continue
        except OSError as exc:
            # NOT silent. An unreadable weights file means this report saw
            # nothing, and "no drift found" over an empty table is exactly the
            # hollow green this whole file exists to refuse.
            print("  weights: %s could not be read (%s) — NO drift check was performed."
                  % (weights_path, exc.__class__.__name__))
            return

    measured = {u: float(recs[0].get("seconds") or 0) for u, recs in ran.items()}

    if emit_path:
        try:
            with open(emit_path, "w", encoding="utf-8") as fh:
                fh.write("# MEASURED on this run. Every unit that ran, in the format\n"
                         "# lib/ci-unit-weights.tsv expects. Replace the rows in that file\n"
                         "# with these and update the run id in its header.\n")
                for uid in sorted(measured):
                    fh.write("%s\t%.1f\tmeasured\n" % (uid, measured[uid]))
            print("  wrote the measured weights of all %d unit(s) to %s" % (len(measured), emit_path))
        except OSError as exc:
            print("  could not write %s (%s)" % (emit_path, exc.__class__.__name__))

    if not planned:
        return
    drift = []
    for uid, secs in measured.items():
        w = planned.get(uid)
        if w is None:
            if secs > 120:
                drift.append((secs, uid, None))
            continue
        if w > 0 and secs > w * 2 and secs > w + 60:
            drift.append((secs, uid, w))
    if not drift:
        print("  weights: every unit finished within 2x its planned weight — the shard plan is current.")
        return
    drift.sort(reverse=True)
    print("  WEIGHTS ARE STALE: %d unit(s) cost materially more than the plan assumed, so they are\n"
          "  in the wrong shards. This does not change what was verified, only where it ran:" % len(drift))
    for secs, uid, w in drift[:12]:
        if w is None:
            print("    %8.1fs  %-62s NO ROW (packed at DEFAULT_WEIGHT)" % (secs, uid))
        else:
            print("    %8.1fs  %-62s planned %.1fs (%.1fx)" % (secs, uid, w, secs / w))


def verify(plan_path, weights_path=None, emit_path=None):
    try:
        with open(plan_path, encoding="utf-8") as fh:
            plan = {ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")}
    except OSError as exc:
        sys.stderr.write("ci-receipts.py verify: cannot read the plan: %s\n" % exc)
        return 2
    if not plan:
        sys.stderr.write(
            "ci-receipts.py verify: the plan is EMPTY. Refusing to certify a run against an\n"
            "inventory of nothing — that is a green tick by construction.\n")
        return 2

    ran = {}
    shas = {}
    bad_lines = 0
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
            uid = rec["unit"]
            verdict = rec["verdict"]
        except (ValueError, KeyError, TypeError):
            bad_lines += 1
            continue
        # A unit appearing twice is itself a finding: the plan assigns each to
        # exactly one shard, so a duplicate means two shards ran it and the
        # packing is wrong, or one receipt was collected twice.
        ran.setdefault(uid, []).append(rec)
        shas.setdefault(str(rec.get("sha", "")), []).append(uid)

    problems = []

    if bad_lines:
        problems.append(
            "%d receipt line(s) could not be parsed. A receipt that cannot be read is not "
            "evidence; the shard that wrote it has to be re-run." % bad_lines)

    if not ran:
        problems.append(
            "NO receipts at all. Every shard either failed before its first unit or wrote its "
            "receipt somewhere this check does not look. Nothing was verified.")

    missing = sorted(plan - set(ran))
    if missing:
        problems.append(
            "%d planned unit(s) have NO receipt — nothing ran them, and their absence would "
            "otherwise have read as green:\n    %s" % (len(missing), "\n    ".join(missing)))

    unplanned = sorted(set(ran) - plan)
    if unplanned:
        problems.append(
            "%d unit(s) ran that are NOT in the plan. The inventory moved under the run, so this "
            "result is about a tree nobody planned:\n    %s"
            % (len(unplanned), "\n    ".join(unplanned)))

    duplicated = sorted(u for u, recs in ran.items() if len(recs) > 1)
    if duplicated:
        problems.append(
            "%d unit(s) have more than one receipt. Each unit belongs to exactly one shard, so "
            "either the packing overlapped or a receipt was collected twice:\n    %s"
            % (len(duplicated), "\n    ".join(duplicated)))

    if len(shas) > 1:
        detail = "; ".join("%s (%d unit(s))" % (s or "<empty>", len(u)) for s, u in sorted(shas.items()))
        problems.append(
            "the shards did not all verify the SAME commit: %s. A union taken across two trees "
            "certifies neither of them." % detail)

    red = sorted((u, recs[0].get("verdict"), recs[0].get("rc"))
                 for u, recs in ran.items() if recs[0].get("verdict") not in GREEN)
    if red:
        problems.append(
            "%d unit(s) did not reach a green verdict:\n    %s"
            % (len(red), "\n    ".join("%-72s %s (rc=%s)" % (u, v, rc) for u, v, rc in red)))

    known_red = sorted(u for u, recs in ran.items() if recs[0].get("verdict") == "KNOWN-RED")

    total_secs = sum(float(recs[0].get("seconds") or 0) for recs in ran.values())
    by_shard = {}
    for recs in ran.values():
        rec = recs[0]
        by_shard.setdefault(int(rec.get("shard") or 0), 0.0)
        by_shard[int(rec.get("shard") or 0)] += float(rec.get("seconds") or 0)

    sha = next(iter(shas)) if len(shas) == 1 else "MIXED"
    if problems:
        sys.stderr.write("\n✗ ci-receipts: this run does NOT certify %s.\n\n" % sha)
        for p in problems:
            sys.stderr.write("  - %s\n" % p)
        sys.stderr.write("\n")
        return 1

    print("✓ ci-receipts: %d/%d planned unit(s) ran, all green, all at %s."
          % (len(ran), len(plan), sha))
    if known_red:
        print("  %d declared KNOWN-RED (lib/ci-known-red.tsv): %s"
              % (len(known_red), ", ".join(known_red)))
    print("  serial cost %.0f s across %d shard(s); longest shard %.0f s (%.1f min)."
          % (total_secs, len(by_shard), max(by_shard.values()), max(by_shard.values()) / 60.0))
    # The measurement, turned into the finished file rather than into advice
    # about producing one. See reweigh().
    reweigh(ran, weights_path, emit_path)
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    if argv[0] == "emit":
        return emit()
    if argv[0] == "verify":
        plan = weights = emit_to = None
        rest = argv[1:]
        while rest:
            if rest[0] == "--plan" and len(rest) >= 2:
                plan, rest = rest[1], rest[2:]
            elif rest[0] == "--weights" and len(rest) >= 2:
                weights, rest = rest[1], rest[2:]
            elif rest[0] == "--emit-weights" and len(rest) >= 2:
                emit_to, rest = rest[1], rest[2:]
            else:
                sys.stderr.write("ci-receipts.py verify: unrecognized argument %r\n" % rest[0])
                return 2
        if plan:
            return verify(plan, weights, emit_to)
        sys.stderr.write("ci-receipts.py verify needs --plan <file> "
                         "[--weights <tsv>] [--emit-weights <path>]\n")
        return 2
    sys.stderr.write("ci-receipts.py: unknown subcommand %r\n" % argv[0])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
