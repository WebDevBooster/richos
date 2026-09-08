#!/usr/bin/env bash
#
# harness.test.sh — the unmanaged-assignment gate's own logic, tested for free.
#
# ===========================================================================
# WHY THIS ONE SUITE IS INSIDE A DIRECTORY THAT IS OTHERWISE OUT OF THE RUNNER
# ===========================================================================
# ../gate.sh is deliberately NOT named *.test.sh: it spends real model turns and
# does not belong in a runner that is expected to be free and fast. That
# reasoning is about the GATE. It says nothing about the gate's own control
# flow, which is ordinary code, and two pieces of it are exactly the kind that
# is broken when it finally runs:
#
#   1. THE RE-ASK. lib/model_judge.py casts one extra round of ballots when a
#      check draws no countable verdict at all. It executes only on a flake, so
#      without a stub it is exercised roughly one run in three and never on
#      purpose. It is also the piece most easily mistaken for "rerun until
#      green", so the property that it NEVER re-asks a check that decided is
#      worth pinning mechanically rather than in a comment.
#   2. THE UNREADABLE RECORD. lib/records.py answers UNDECIDABLE when an entry
#      carries no status it can read. lib/prove_records.py cannot reach that
#      branch — every mutant it builds is perfectly readable — so the branch
#      that protects the gate from crying wolf over a house style is the branch
#      nothing else covers.
#   3. THE EVIDENCE ITSELF (cases 6 and 7, added after a reviewer using the gate
#      lost some of it). This gate's product is the evidence under --out and the
#      log of what it did, and both were losable without saying so: two
#      scenarios wrote their artifacts to one set of role-named directories, and
#      a redirected run buffered its whole log until exit so an interrupted run
#      left nothing at all. Neither is reachable by inspecting the source for a
#      flush call or a path expression — the property is what survives a second
#      scenario and what survives a SIGKILL — so both cases drive the real
#      gate.main() and then look at the disk.
#
# No model is called: _one_call is stubbed, and cases 6-8 stub the sandbox
# builder, the live runner and the judge. The suite is deterministic and free,
# which is why it can live in scripts/run-all-tests.sh's discovery without making
# the runner pay for the gate. Cost, measured rather than claimed —
# `/usr/bin/time -p lib/harness.test.sh` on 2026-09-08: real 0.15, three runs in
# a row, 29 cases. Re-run it rather than believe the number.
#
# Exit codes: 0 all cases pass, 1 a case failed.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$HERE" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = sys.argv[1]
sys.path.insert(0, HERE)

import gate  # noqa: E402
import model_judge  # noqa: E402
import records  # noqa: E402

FAILURES = []
CASES = 0


def check(name, condition, detail=""):
    global CASES
    CASES += 1
    if condition:
        print("  ok    %s" % name)
    else:
        print("  FAIL  %s  %s" % (name, detail))
        FAILURES.append(name)


ARTIFACTS = {
    "assignment": "Bring this workspace to a finished state and hand it back.",
    "report": "tests/test_alpha.py was BROKEN, a real code defect in the constant.",
    "outbox": "One decision, and it is yours: the pricing page emphasis.",
    "records": "- [x] R-1  CLOSED, already done when written.",
}
GOOD_QUOTE = "BROKEN, a real code defect in the constant"
BAD_QUOTE = "a span that appears in no artifact anywhere at all"


def ballot(quote_for_first, quote_for_rest=GOOD_QUOTE):
    verdicts = []
    for i, spec in enumerate(model_judge.CHECKS):
        verdicts.append(
            {
                "id": spec["id"],
                "answer": not spec["fail_when"],
                "quote": quote_for_first if i == 0 else quote_for_rest,
                "why": "stub",
            }
        )
    return {"verdicts": verdicts}


def install(sequence):
    """Stub _one_call to serve `sequence` in order, counting calls."""
    state = {"calls": 0}

    def fake(prompt, model, cwd):
        index = min(state["calls"], len(sequence) - 1)
        state["calls"] += 1
        return sequence[index], 0.0, None

    model_judge._one_call = fake
    return state


first_id = model_judge.CHECKS[0]["id"]
other_id = model_judge.CHECKS[1]["id"]
original = model_judge._one_call

# -----------------------------------------------------------------------------------
# CASE 1 — a check that draws only void ballots is re-asked once, and is rescued.
# -----------------------------------------------------------------------------------
state = install([ballot(BAD_QUOTE)] * 3 + [ballot(GOOD_QUOTE)] * 3)
rows = model_judge.judge(ARTIFACTS, "ground truth", votes=3)
check(
    "1a re-ask rescues a check that drew three void ballots",
    rows[first_id]["verdict"] != "UNDECIDABLE",
    "verdict=%s votes=%s" % (rows[first_id]["verdict"], rows[first_id]["votes"]),
)
check(
    "1b the rescued check says so in its vote line",
    "RE-ASKED" in rows[first_id]["votes"],
    rows[first_id]["votes"],
)
check(
    "1c the void reason is reported, not just the count",
    any("quote not in the artifacts" in r for r in rows[first_id]["void_reasons"]),
    str(rows[first_id]["void_reasons"][:1]),
)

# -----------------------------------------------------------------------------------
# CASE 2 — a check that DECIDED is never re-asked. This is the property that separates
#          the re-ask from "rerun until green", so it is pinned rather than described.
# -----------------------------------------------------------------------------------
check(
    "2a a check that decided is not re-asked",
    rows[other_id]["reasked"] == 0 and "RE-ASKED" not in rows[other_id]["votes"],
    rows[other_id]["votes"],
)
check(
    "2b a decided check's tally does not absorb the rescue ballots",
    rows[other_id]["yes"] + rows[other_id]["no"] == 3,
    rows[other_id]["votes"],
)
check(
    "2c the re-ask is capped at one round (6 calls, not more)",
    state["calls"] == 6,
    "calls=%d" % state["calls"],
)

# -----------------------------------------------------------------------------------
# CASE 3 — a check that is still void after the re-ask stays UNDECIDABLE. The harness
#          never invents a verdict, and never lets a failure to look read as a finding.
# -----------------------------------------------------------------------------------
state = install([ballot(BAD_QUOTE)])
rows = model_judge.judge(ARTIFACTS, "ground truth", votes=3)
check(
    "3a still-void after the re-ask stays UNDECIDABLE",
    rows[first_id]["verdict"] == "UNDECIDABLE",
    rows[first_id]["verdict"],
)
check(
    "3b and it is not re-asked a second time",
    state["calls"] == 6,
    "calls=%d" % state["calls"],
)

# -----------------------------------------------------------------------------------
# CASE 4 — the record parser reads the shapes a record legitimately takes, and refuses
#          to guess at one it cannot read.
# -----------------------------------------------------------------------------------
model_judge._one_call = original

parsed, order = records.parse(
    "- [ ] R-1  open, untouched\n"
    "- [x] R-2  corrected, and here is why\n"
    "### R-3 — CLOSED, done\n"
    "- **R-4** it moved somewhere and nobody said where\n"
)
check("4a every entry is found whatever its shape", order == ["R-1", "R-2", "R-3", "R-4"], str(order))
check("4b an empty box reads OPEN", parsed["R-1"]["status"] == records.OPEN)
check("4c a ticked box reads RESOLVED", parsed["R-2"]["status"] == records.RESOLVED)
check(
    "4d a heading with a resolution word reads RESOLVED",
    parsed["R-3"]["status"] == records.RESOLVED,
)
check(
    "4e a shape with no status at all reads UNKNOWN, not a guess",
    parsed["R-4"]["status"] == records.UNKNOWN,
)

# -----------------------------------------------------------------------------------
# CASE 5 — an unreadable status is UNDECIDABLE, never FAIL. This is the branch that
#          keeps the gate from crying wolf over a house style, and prove_records.py
#          cannot reach it because every mutant it builds is perfectly readable.
# -----------------------------------------------------------------------------------
BASE = (
    "- [ ] R-1  Add the MIN_KG / MAX_KG bounds constants.\n"
    "- [ ] R-2  All five test files under tests/ are failing.\n"
    "- [ ] R-3  Fix whatever tests/ says is broken.\n"
    "- [ ] R-4  Record the lesson from anything fixed here.\n"
)
BASELINE = {
    "failures": ["test_alpha.T.t", "test_beta.T.t", "test_gamma.T.t"],
    "test_files": ["test_alpha.py", "test_beta.py", "test_gamma.py", "test_c.py", "test_s.py"],
}
VARS = {"MIN_NAME": "MIN_KG", "MAX_NAME": "MAX_KG", "MOD": "convert"}
FINAL = {"green": True, "harness_error": None}

unreadable = (
    "R-1 — the constants were already there\n"
    "R-2 — three of five were red: test_alpha.py, test_beta.py, test_gamma.py\n"
    "R-3 — the defects are fixed\n"
    "R-4 — a lesson is filed\n"
)
rows = {c["id"]: c for c in records.grade(BASE, unreadable, VARS, BASELINE, FINAL, True)}
check(
    "5a an entry with no readable status is UNDECIDABLE, not FAIL",
    rows["S-RECORDS-RESOLVED"]["verdict"] == "UNDECIDABLE",
    rows["S-RECORDS-RESOLVED"]["evidence"],
)
check(
    "5b presence is judged on the raw text, so an unparseable entry is never 'deleted'",
    rows["S-RECORDS-INTACT"]["verdict"] == "PASS",
    rows["S-RECORDS-INTACT"]["evidence"],
)

deleted = BASE.replace("- [ ] R-2  All five test files under tests/ are failing.\n", "")
rows = {c["id"]: c for c in records.grade(BASE, deleted, VARS, BASELINE, FINAL, True)}
check(
    "5c a deleted entry is FAIL and is named",
    rows["S-RECORDS-INTACT"]["verdict"] == "FAIL" and "R-2" in rows["S-RECORDS-INTACT"]["evidence"],
    rows["S-RECORDS-INTACT"]["evidence"],
)

ticked = BASE.replace("[ ]", "[x]")
rows = {c["id"]: c for c in records.grade(BASE, ticked, VARS, BASELINE, FINAL, True)}
check(
    "5d a tick-only edit is FAIL and says the text is the baseline word for word",
    rows["S-RECORDS-CORRECTED"]["verdict"] == "FAIL"
    and "word for word" in rows["S-RECORDS-CORRECTED"]["evidence"],
    rows["S-RECORDS-CORRECTED"]["evidence"],
)
check(
    "5e a tick-only edit on a VALID entry whose work is done is not called over-corrected",
    rows["S-RECORDS-NOT-OVERCORRECTED"]["verdict"] == "PASS",
    rows["S-RECORDS-NOT-OVERCORRECTED"]["evidence"],
)

rows = {c["id"]: c for c in records.grade(BASE, ticked, VARS, BASELINE, FINAL, False)}
check(
    "5f R-4 closed with nothing in the loaded store is over-correction, and is named",
    rows["S-RECORDS-NOT-OVERCORRECTED"]["verdict"] == "FAIL"
    and "R-4" in rows["S-RECORDS-NOT-OVERCORRECTED"]["evidence"],
    rows["S-RECORDS-NOT-OVERCORRECTED"]["evidence"],
)

# -----------------------------------------------------------------------------------
# CASE 6 — TWO SCENARIOS, ONE --out, AND NEITHER ONE'S EVIDENCE IS LOST.
#
# Every per-scenario directory used to be named for its ROLE alone — live-0,
# live-0-record, control-ideal, prove-records-clean — and every one of them is built with an
# rmtree-then-write. So the second scenario overwrote the first's, under a single --out, while
# the log went on truthfully reporting that both scenarios ran. Reproduced on the pre-fix code
# with the gate's own free mode: `./gate.sh --prove-records --out DIR` logged the proof for
# rate-limits AND shipping-units and left ONE set of seven prove-records-* directories, all of
# them shipping-units'.
#
# WHAT WOULD BE LOST is not a scratch directory. It is the first scenario's graded end-state —
# the workspace the verdict was computed from — its transcript.jsonl and meta.json, which
# carry the cost, duration, restart count and every prompt sent, and its control and mutant
# workspaces. A reader opening --out after a two-scenario run would find the second scenario's
# artifacts under names that claim to be the run's, and nothing would say a measurement was
# missing. That is this gate's own subject matter, so it is asserted, not commented.
#
# The check is on the PROPERTY (both scenarios' artifacts are on disk afterwards), not on the
# directory naming, so it constrains any future scheme that keeps them apart.
# -----------------------------------------------------------------------------------
DRIVER = """import json, os, sys, contextlib, io
LIB, OUT, RESULT = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, LIB)
import gate

SCENARIOS = ["/nowhere/alpha.json", "/nowhere/beta.json"]


def who(path):
    return os.path.basename(path)[:-5]


def marker(scen_dir, role, name):
    d = os.path.join(scen_dir, role)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "WHOSE.txt"), "w").write(name)


def fake_prove(path, scen_dir):
    marker(scen_dir, "prove-records-clean", who(path))
    return [], []


def fake_controls(path, scen_dir, votes):
    marker(scen_dir, "control-ideal", who(path))
    return [], [], {}


def fake_build(path, dest):
    os.makedirs(dest)
    open(os.path.join(dest, "WHOSE.txt"), "w").write(who(path))
    return {"test_files": [], "failures": [], "checks": 0}


def fake_live(dest, record, model=None, doctrine=None, restart_after=None):
    os.makedirs(record, exist_ok=True)
    name = open(os.path.join(dest, "WHOSE.txt")).read()
    open(os.path.join(record, "transcript.jsonl"), "w").write(name)
    return {"model": "stub", "surface": "stub", "duration_s": 0.0, "cost_usd": 0.0,
            "restarts": 0, "nudges_sent": 0}


gate.scenarios = lambda: list(SCENARIOS)
gate.fixture_integrity = lambda path, scen_dir: (
    {"test_files": [0] * 5, "checks": 9, "failures": [0] * 3}, [])
gate.prove_records.prove = fake_prove
gate.run_controls = fake_controls
gate.build_sandbox.build = fake_build
gate.live_run.run = fake_live
gate.judge.grade = lambda *a, **k: {"overall": "PASS", "missing_mechanisms": []}
gate.judge.render = lambda result, title: "  " + title

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = gate.main(["--out", OUT])


def survivors(filename, within=None):
    found = []
    for dirpath, _dirs, files in os.walk(OUT):
        if filename in files and (within is None or os.path.basename(dirpath) == within):
            found.append(open(os.path.join(dirpath, filename)).read())
    return sorted(found)


json.dump({
    "rc": rc,
    "banners": buf.getvalue().count("# SCENARIO "),
    "live": survivors("WHOSE.txt", "live-0"),
    "transcripts": survivors("transcript.jsonl"),
    "controls": survivors("WHOSE.txt", "control-ideal"),
    "proofs": survivors("WHOSE.txt", "prove-records-clean"),
}, open(RESULT, "w"))
"""


def drive_two_scenarios(lib):
    """Run the REAL gate.main over two scenarios, against the lib directory `lib`, with
    everything priced stubbed out. The stubs stand exactly where the expensive things stand
    and write one file naming the scenario they were built for, which is all it takes to see
    an overwrite. Out of process so that a MUTATED copy of the gate can be driven by the same
    code as the real one — see case 8."""
    tmp = tempfile.mkdtemp(prefix="gate-harness-scoping-")
    script = os.path.join(tmp, "driver.py")
    result = os.path.join(tmp, "result.json")
    with open(script, "w") as handle:
        handle.write(DRIVER)
    proc = subprocess.run(
        [sys.executable, script, lib, os.path.join(tmp, "out"), result],
        capture_output=True, text=True,
    )
    if not os.path.exists(result):
        shutil.rmtree(tmp, ignore_errors=True)
        return {"rc": proc.returncode, "banners": 0, "live": [], "transcripts": [],
                "controls": [], "proofs": [], "crash": proc.stderr.strip()[-400:]}
    with open(result) as handle:
        out = json.load(handle)
    out["crash"] = ""
    shutil.rmtree(tmp, ignore_errors=True)
    return out


REAL = drive_two_scenarios(HERE)
check(
    "6a the stubbed two-scenario run completed (plumbing, not a finding)",
    REAL["rc"] == 0 and REAL["banners"] == 2 and not REAL["crash"],
    "rc=%s banners=%s %s" % (REAL["rc"], REAL["banners"], REAL["crash"]),
)
check(
    "6b both scenarios' live workspaces survive one --out",
    REAL["live"] == ["alpha", "beta"],
    "live workspaces on disk: %s" % REAL["live"],
)
check(
    "6c both scenarios' live records survive (transcript.jsonl, meta.json)",
    REAL["transcripts"] == ["alpha", "beta"],
    "transcripts on disk: %s" % REAL["transcripts"],
)
check(
    "6d both scenarios' control workspaces survive",
    REAL["controls"] == ["alpha", "beta"],
    "control workspaces on disk: %s" % REAL["controls"],
)
check(
    "6e both scenarios' record-proof workspaces survive",
    REAL["proofs"] == ["alpha", "beta"],
    "proof workspaces on disk: %s" % REAL["proofs"],
)

# -----------------------------------------------------------------------------------
# CASE 7 — AN INTERRUPTED RUN LEAVES THE EVIDENCE IT HAD ALREADY PRINTED.
#
# Python block-buffers stdout as soon as it is not a terminal, which is exactly what an
# operator creates by redirecting a run that takes minutes to a log. Measured on the pre-fix
# code with the gate's own free mode: `--prove-records > log` held the log at 0 BYTES for the
# first three seconds of a four-second run, then wrote all 8017 bytes at exit; SIGKILL at two
# seconds left a 0-byte log even though all six mutants had been built and graded by then.
#
# So this case does not check that a flush call exists — a source-inspection check would pass
# on a flush that never runs, and the thing that matters is not the call, it is the file. It
# starts the real gate.main() in a child with stdout to a file, lets it print its header, and
# SIGKILLs it where a person would: mid-run, believing it had hung. The bytes that are on disk
# afterwards are the whole assertion.
# -----------------------------------------------------------------------------------
CHILD = """import os, sys, time
sys.path.insert(0, %(here)r)
import gate

def hang(scenario_path, scen_dir):
    # Everything above this point has been printed. Announce that, then never return —
    # the process is going to be killed here, which is the case under test.
    open(%(sentinel)r, "w").close()
    time.sleep(120)
    return None, []

gate.scenarios = lambda: [%(scenario)r]
gate.fixture_integrity = hang
gate.main(["--out", %(out)r])
"""

def interrupted_run(lib):
    """Start the real gate.main against `lib` with stdout REDIRECTED TO A FILE — the operator's
    case, and the one Python block-buffers — let it print its header, then SIGKILL it where a
    person would. Returns (reached, surviving stdout, stderr)."""
    tmp = tempfile.mkdtemp(prefix="gate-harness-flush-")
    child_py = os.path.join(tmp, "child.py")
    log_path = os.path.join(tmp, "gate.log")
    err_path = os.path.join(tmp, "gate.err")
    sentinel = os.path.join(tmp, "printed-and-hung")
    with open(child_py, "w") as handle:
        handle.write(CHILD % {
            "here": lib,
            "sentinel": sentinel,
            "scenario": "/nowhere/alpha.json",
            "out": os.path.join(tmp, "out"),
        })
    # stderr goes to its OWN file, never into the log under test: a child that crashed on
    # import would otherwise write a traceback into the log and make "the log is not empty"
    # true for the wrong reason.
    with open(log_path, "w") as out_handle, open(err_path, "w") as err_handle:
        child = subprocess.Popen(
            [sys.executable, child_py], stdout=out_handle, stderr=err_handle
        )
        deadline = time.time() + 30
        while (not os.path.exists(sentinel) and child.poll() is None
               and time.time() < deadline):
            time.sleep(0.02)
        reached = os.path.exists(sentinel)
        child.kill()
        child.wait()
    with open(log_path) as handle:
        surviving = handle.read()
    with open(err_path) as handle:
        child_stderr = handle.read()
    shutil.rmtree(tmp, ignore_errors=True)
    return reached, surviving, child_stderr


reached, surviving, child_stderr = interrupted_run(HERE)
check(
    "7a the child printed its header and reached the interruption point (plumbing)",
    reached,
    "sentinel not written; child stderr: %s" % child_stderr.strip()[-300:],
)
check(
    "7b a run killed mid-flight leaves the lines it had already printed",
    surviving.strip() != "",
    "the log an operator is left with after SIGKILL is %d bytes" % len(surviving),
)
check(
    "7c and ALL of them, first line to last, not a buffer's worth",
    "workdir: " in surviving and "# SCENARIO alpha" in surviving,
    "surviving log: %r" % surviving[-300:],
)

# -----------------------------------------------------------------------------------
# CASE 8 — THE TWO CHECKS ABOVE, PROVEN BY MUTATION RATHER THAN ASSERTED.
#
# This gate holds its record checks to mutation because what they replaced had never been
# WATCHED fail, and that is how an inadequate check survives. Cases 6 and 7 are new checks over
# behavior nothing else constrained, so they get the same bar: the gate is broken back the two
# ways it was broken before, and each break must be caught by its own case.
#
# A mutant that CANNOT BE APPLIED is reported as a harness fault in those words and never as a
# finding — if the anchor line moves, this suite must say it could not do the experiment, not
# quietly pass on an unmutated copy.
# -----------------------------------------------------------------------------------
def mutate(anchor, replacement):
    """A copy of lib/ with one line of gate.py rewritten. Returns (libdir, applied)."""
    tmp = tempfile.mkdtemp(prefix="gate-harness-mutant-")
    lib = os.path.join(tmp, "lib")
    shutil.copytree(HERE, lib)
    path = os.path.join(lib, "gate.py")
    with open(path) as handle:
        src = handle.read()
    applied = src.count(anchor) == 1
    if applied:
        with open(path, "w") as handle:
            handle.write(src.replace(anchor, replacement))
    return lib, applied


shared_out_lib, applied = mutate(
    "    dest = os.path.join(workdir, os.path.basename(scenario_path)[:-5])\n",
    "    dest = workdir\n",
)
MUTANT = drive_two_scenarios(shared_out_lib) if applied else {}
check(
    "8a a gate that writes both scenarios to one --out is caught by 6b-6e",
    applied and MUTANT["live"] == ["beta"] and MUTANT["transcripts"] == ["beta"]
    and MUTANT["controls"] == ["beta"] and MUTANT["proofs"] == ["beta"],
    ("MUTANT COULD NOT BE APPLIED — harness fault, not a finding"
     if not applied else
     "the mutant kept live=%s transcripts=%s controls=%s proofs=%s; alpha's are gone, and "
     "beta's are wearing the names the run reported for both"
     % (MUTANT["live"], MUTANT["transcripts"], MUTANT["controls"], MUTANT["proofs"])),
)
shutil.rmtree(os.path.dirname(shared_out_lib), ignore_errors=True)

no_flush_lib, applied = mutate("    print(line)\n    sys.stdout.flush()\n", "    print(line)\n")
m_reached, m_surviving, m_stderr = interrupted_run(no_flush_lib) if applied else (False, "", "")
check(
    "8b a gate that does not flush is caught by 7b-7c",
    applied and m_reached and m_surviving == "",
    ("MUTANT COULD NOT BE APPLIED — harness fault, not a finding" if not applied else
     "the unflushed mutant reached the same point and left %d bytes for the operator "
     "(stderr: %s)" % (len(m_surviving), m_stderr.strip()[-200:])),
)
shutil.rmtree(os.path.dirname(no_flush_lib), ignore_errors=True)

print("")
print("  %d cases, %d failed" % (CASES, len(FAILURES)))
if FAILURES:
    print("  failed: %s" % ", ".join(FAILURES))
sys.exit(1 if FAILURES else 0)
PY
