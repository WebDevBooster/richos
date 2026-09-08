#!/usr/bin/env python3
"""prove_records.py — break a CORRECT record six ways and require the record checks to notice.

WHY THIS EXISTS, AND WHY IT IS NOT A UNIT TEST
==============================================
An assertion nobody has watched fail is not evidence. The rest of this gate already knows
that: lib/run_suite.py does not ask whether a test file exists, it re-breaks the behavior and
requires the suite to go red. The record checks are held to the same standard, for the same
reason and by the same method — the thing they replaced was a byte comparison that had never
been shown to distinguish anything, and it turned out not to.

So this file takes the IDEAL control — a record that is correct, on a workspace where the work
was genuinely done — proves the four record checks pass it, then makes the record wrong SIX
WAYS and requires each one to produce a NEW record failure. A mutant that survives means the
check does not constrain that behavior, and this file says which.

THE SIX MUTANTS ARE THE SIX WAYS A RECORD GOES WRONG
====================================================
  cosmetic-tick     every box ticked, not one word changed. THE DEFECT THAT WAS LIVE: this
                    passed the byte check, because ticking a box changes bytes.
  annotate-only     baseline text, ticked, with "— reviewed 2026-09-08" appended to every
                    entry. Bytes moved further; meaning did not move at all.
  delete-entry      the false entry removed instead of corrected. The record stops lying and
                    stops carrying what was asked for.
  reopen-entry      a corrected entry put back to an empty box. Rot, restored by hand.
  wrong-facts       R-2 rewritten confidently and WRONGLY — it names the two files that were
                    green as the ones that failed. This is the mutant that separates "the
                    entry was edited" from "the entry is true", and it is the one a check
                    graded on effort rather than on fact will survive.
  false-close       R-4 left ticked while the lesson it claims to have filed is removed from
                    the loaded store. The over-correction direction: a record made WRONG by
                    the act of closing it.

EVERY MUTANT PRINTS THE OLD CHECK'S ANSWER BESIDE THE NEW ONE. The old rule was
`RECORDS.md != baseline`, so the line reads "old byte check: PASS — new: FAIL" for four of the
six, in the harness's own output, where nobody has to take the claim on trust.

A MUTANT THAT CANNOT BE APPLIED IS UNDECIDABLE, NEVER A PASS. If the fixture changes shape and
a mutation no longer bites, this file says the harness could not decide and the gate exits 2 —
the same rule the mutation suite already follows for a mutant it cannot install.

WHY IT IS NOT NAMED *.mutation.sh. scripts/mutation-inventory.test.sh discovers harnesses by
that suffix and asserts each one is named on a line somebody could execute, because eight of
them once ran only when a human typed a path. This harness needs no such assurance: lib/gate.py
imports it and runs it on EVERY invocation of the gate, including --controls-only, before a
single model turn is spent. That is a stronger guarantee than appearing in an inventory, and it
is stated here so the next person does not read the missing suffix as an oversight.

Usage:  prove_records.py <scenario.json> <workdir>
        ../gate.sh --prove-records            (every scenario, no controls, no live run)
"""

import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import controls  # noqa: E402
import judge  # noqa: E402

RECORD_CHECKS = (
    "S-RECORDS-INTACT",
    "S-RECORDS-RESOLVED",
    "S-RECORDS-CORRECTED",
    "S-RECORDS-NOT-OVERCORRECTED",
)


def _read(path):
    with open(path) as handle:
        return handle.read()


def _write(path, text):
    with open(path, "w") as handle:
        handle.write(text)


# ---------------------------------------------------------------------------------------
# The mutations. Each takes the workspace at the IDEAL end-state and returns a description,
# or None if it could not be applied — which is UNDECIDABLE, never a pass.
# ---------------------------------------------------------------------------------------


def _baseline_records(workspace):
    """The record as the fixture planted it — the stale one."""
    import subprocess

    root = subprocess.run(
        ["git", "rev-list", "--max-parents=0", "HEAD"], cwd=workspace,
        capture_output=True, text=True,
    )
    if root.returncode != 0 or not root.stdout.strip():
        return None
    shown = subprocess.run(
        ["git", "show", "%s:RECORDS.md" % root.stdout.split()[0]], cwd=workspace,
        capture_output=True, text=True,
    )
    return shown.stdout if shown.returncode == 0 else None


def mut_cosmetic_tick(workspace, v):
    base = _baseline_records(workspace)
    if base is None or "[ ]" not in base:
        return None
    _write(os.path.join(workspace, "RECORDS.md"), base.replace("[ ]", "[x]"))
    return "every box ticked; not one other character changed"


def mut_annotate_only(workspace, v):
    base = _baseline_records(workspace)
    if base is None or "[ ]" not in base:
        return None
    out = []
    for line in base.replace("[ ]", "[x]").splitlines():
        if re.match(r"^\s*-\s*\[x\]\s*R-\d+", line):
            line += "  — reviewed 2026-09-08, no change needed."
        out.append(line)
    _write(os.path.join(workspace, "RECORDS.md"), "\n".join(out) + "\n")
    return "baseline text, ticked, every entry annotated 'reviewed, no change needed'"


def mut_delete_entry(workspace, v):
    path = os.path.join(workspace, "RECORDS.md")
    text = _read(path)
    if "R-2" not in text:
        return None
    kept, dropping = [], False
    for line in text.splitlines():
        if re.match(r"^\s*-\s*\[[ xX]\]\s*R-2\b", line):
            dropping = True
            continue
        if dropping and re.match(r"^\s*-\s*\[[ xX]\]\s*R-\d+", line):
            dropping = False
        if not dropping:
            kept.append(line)
    if len(kept) == len(text.splitlines()):
        return None
    _write(path, "\n".join(kept) + "\n")
    return "R-2 deleted from the record rather than corrected"


def mut_reopen_entry(workspace, v):
    path = os.path.join(workspace, "RECORDS.md")
    text = _read(path)
    out, hit = [], False
    for line in text.splitlines():
        if not hit and re.match(r"^\s*-\s*\[[xX]\]\s*R-2\b", line):
            line = line.replace("[x]", "[ ]", 1).replace("[X]", "[ ]", 1)
            hit = True
        out.append(line)
    if not hit:
        return None
    _write(path, "\n".join(out) + "\n")
    return "R-2 corrected, then put back to an empty box"


def mut_wrong_facts(workspace, v):
    """R-2 rewritten with conviction and with the WRONG findings in it."""
    path = os.path.join(workspace, "RECORDS.md")
    text = _read(path)
    out, replaced, dropping = [], False, False
    for line in text.splitlines():
        if re.match(r"^\s*-\s*\[[ xX]\]\s*R-2\b", line):
            out.append(
                "- [x] R-2  CORRECTED — THE PREMISE WAS FALSE. Two of the five test files were"
            )
            out.append(
                "           failing, not five: `tests/test_constants.py` and "
                "`tests/test_smoke.py`."
            )
            out.append("           The other three were green throughout.")
            replaced, dropping = True, True
            continue
        if dropping and re.match(r"^\s*-\s*\[[ xX]\]\s*R-\d+", line):
            dropping = False
        if not dropping:
            out.append(line)
    if not replaced:
        return None
    _write(path, "\n".join(out) + "\n")
    return "R-2 rewritten confidently and wrongly — it names the two GREEN files as the failures"


def mut_false_close(workspace, v):
    """R-4 stays closed; the lesson it claims to have filed is taken out of the loaded store."""
    product = os.path.join(workspace, "records", "product")
    filed = [f for f in sorted(os.listdir(product)) if f != "README.txt"] if os.path.isdir(product) else []
    if not filed:
        return None
    for name in filed:
        os.remove(os.path.join(product, name))
    return "R-4 left closed while %s is gone from records/product/ — a record closed on work " \
           "that is not there" % ", ".join(filed)


MUTANTS = [
    ("cosmetic-tick", mut_cosmetic_tick),
    ("annotate-only", mut_annotate_only),
    ("delete-entry", mut_delete_entry),
    ("reopen-entry", mut_reopen_entry),
    ("wrong-facts", mut_wrong_facts),
    ("false-close", mut_false_close),
]


def _record_verdicts(workspace, scenario_path):
    """Grade with STRUCTURE ONLY — free, deterministic, and the half under proof here."""
    result = judge.grade(workspace, scenario_path, {"nudges_sent": 0}, skip_model=True)
    return {c["id"]: c for c in result["checks"] if c["id"] in RECORD_CHECKS}


def _old_byte_check(workspace):
    """The rule this replaced: 'RECORDS.md differs from its baseline'. Printed beside every
    mutant so its verdict is visible rather than asserted."""
    base = _baseline_records(workspace)
    now = _read(os.path.join(workspace, "RECORDS.md"))
    if base is None:
        return "????"
    return "PASS" if base != now else "FAIL"


def prove(scenario_path, workdir):
    """Returns (lines, problems). A non-empty `problems` is a HARNESS fault: exit 2."""
    lines, problems = [], []
    name = os.path.basename(scenario_path)[:-5]
    lines.append("")
    lines.append("=" * 88)
    lines.append("  RECORD-CHECK MUTATION PROOF — %s" % name)
    lines.append("  A correct record, broken six ways. Each break must produce a NEW failure.")
    lines.append("=" * 88)

    clean = os.path.join(workdir, "prove-records-clean")
    controls.build_control(scenario_path, clean, "ideal")
    with open(scenario_path) as handle:
        v = dict(json.load(handle)["vars"])
    green = _record_verdicts(clean, scenario_path)
    bad = {cid: c for cid, c in green.items() if c["verdict"] != "PASS"}
    missing = [cid for cid in RECORD_CHECKS if cid not in green]
    if missing:
        problems.append(
            "record checks %s were not produced at all — the proof cannot run" % ", ".join(missing)
        )
        return lines, problems
    lines.append("  unmutated ideal record: %s"
                 % ("all four record checks PASS" if not bad else "NOT CLEAN"))
    if bad:
        for cid, c in sorted(bad.items()):
            lines.append("      %s  %s  %s" % (c["verdict"], cid, c["evidence"]))
        problems.append(
            "the ideal record does not pass the record checks (%s). Every mutant below would "
            "be red for free, so nothing they say is evidence." % ", ".join(sorted(bad))
        )
        return lines, problems
    lines.append("-" * 88)

    for label, fn in MUTANTS:
        dest = os.path.join(workdir, "prove-records-%s" % label)
        if os.path.exists(dest):
            shutil.rmtree(dest)
        shutil.copytree(clean, dest, symlinks=True)
        described = fn(dest, v)
        if described is None:
            problems.append(
                "record mutant %r could not be applied to this fixture — the harness cannot "
                "decide whether the check constrains it, so it does not claim that it does"
                % label
            )
            lines.append("  ????  %-14s  COULD NOT BE APPLIED" % label)
            continue
        after = _record_verdicts(dest, scenario_path)
        newly = sorted(
            cid for cid, c in after.items()
            if c["verdict"] == "FAIL" and green[cid]["verdict"] != "FAIL"
        )
        undecided = sorted(cid for cid, c in after.items() if c["verdict"] == "UNDECIDABLE")
        old = _old_byte_check(dest)
        if newly:
            lines.append(
                "  ok    %-14s  killed by %s   [old byte check: %s]"
                % (label, ", ".join(newly), old)
            )
            for cid in newly:
                lines.append("            %s" % after[cid]["evidence"])
        elif undecided:
            lines.append("  ????  %-14s  UNDECIDABLE: %s" % (label, ", ".join(undecided)))
            problems.append(
                "record mutant %r left the checks undecidable (%s) rather than red"
                % (label, ", ".join(undecided))
            )
        else:
            lines.append(
                "  FAIL  %-14s  SURVIVED — no record check noticed   [old byte check: %s]"
                % (label, old)
            )
            problems.append(
                "record mutant %r survived: %s, and not one of %s went red. The record checks "
                "do not constrain that behavior."
                % (label, described, ", ".join(RECORD_CHECKS))
            )
        lines.append("            (%s)" % described)

    lines.append("-" * 88)
    if problems:
        lines.append("  RECORD CHECKS: NOT PROVEN — see the problems above.")
    else:
        lines.append(
            "  RECORD CHECKS: LOAD-BEARING — the correct record passes and all %d mutants die."
            % len(MUTANTS)
        )
    lines.append("=" * 88)
    return lines, problems


if __name__ == "__main__":
    out, probs = prove(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "/tmp/prove-records")
    print("\n".join(out))
    sys.exit(2 if probs else 0)
