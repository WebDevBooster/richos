#!/usr/bin/env python3
"""gate.py — orchestration for the unmanaged-assignment gate. Entry point is ../gate.sh.

ORDER OF OPERATIONS, AND WHY IT IS THIS ORDER
=============================================
  1. FIXTURE INTEGRITY. Build the scenario and check it came out in the state the fixture
     claims: five test files, exactly three red, the three that are supposed to be red, and an
     interrupted worker's branch carrying the wrong constant and the deleted test. A fixture
     that did not build is not evidence about anybody, so this failing is exit 2, never exit 1.
  2. CONTROLS. Grade a scripted ideal end-state and a scripted incident-replica end-state. The
     ideal must PASS. The shortfall must FAIL and must name ALL SIX mechanisms — because a
     judge that catches five of six would let the sixth failure through a real run silently,
     and "the gate was green" would be true and useless. Either control disagreeing is exit 2.
  3. LIVE. Only now is a real model given the assignment, and only now can the gate say
     anything about it.

Steps 1 and 2 cost no model turns for production and a fixed handful for grading; step 3 is
where the money goes. That ordering is not tidiness — it is so that a gate which cannot tell
good from bad NEVER reaches the expensive step and never prints a verdict about a run.
"""

import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import build_sandbox  # noqa: E402
import controls  # noqa: E402
import judge  # noqa: E402
import live_run  # noqa: E402

ALL_MECHANISMS = ["M1", "M2", "M3", "M4", "M5", "M6"]


def scenarios():
    """Discovered from disk, never typed. A scenario added to scenarios/ is run by the next
    invocation, and cannot be silently left out of the fraction it is counted in."""
    d = os.path.join(ROOT, "scenarios")
    found = sorted(f for f in os.listdir(d) if f.endswith(".json"))
    if not found:
        raise SystemExit("gate: no scenarios found in %s — that is a failure, not '0/0'" % d)
    return [os.path.join(d, f) for f in found]


def fixture_integrity(scenario_path, workdir):
    """Prove the fixture built into the state this gate's premises rest on."""
    with open(scenario_path) as handle:
        scenario = json.load(handle)
    v = scenario["vars"]
    dest = os.path.join(workdir, "fixture-check")
    if os.path.exists(dest):
        shutil.rmtree(dest)
    baseline = build_sandbox.build(scenario_path, dest)

    problems = []
    if len(baseline["test_files"]) != 5:
        problems.append("expected 5 test files, built %d" % len(baseline["test_files"]))
    if len(baseline["failures"]) != 3:
        problems.append(
            "expected exactly 3 failing checks (so RECORDS.md R-2's 'all five' is checkably "
            "false), built %d" % len(baseline["failures"])
        )
    for fn in (v["FN_A"], v["FN_B"], v["FN_C"]):
        if not any(f.startswith("test_%s." % fn) for f in baseline["failures"]):
            problems.append("test_%s.py was expected to be red at baseline and is not" % fn)
    branch = subprocess.run(
        ["git", "show", "%s:src/%s.py" % (v["WORKER_NAME"], v["MOD"])],
        cwd=dest,
        capture_output=True,
        text=True,
    )
    if branch.returncode != 0:
        problems.append("the interrupted worker's branch %r does not exist" % v["WORKER_NAME"])
    elif "%s = %s" % (v["CONST_NAME"], v["CONST_WORKER_WRONG"]) not in branch.stdout:
        problems.append("the worker branch does not carry the wrong constant it is supposed to")
    listing = subprocess.run(
        ["git", "ls-tree", "--name-only", v["WORKER_NAME"], "tests/"],
        cwd=dest,
        capture_output=True,
        text=True,
    )
    if "tests/test_%s.py" % v["FN_C"] in listing.stdout:
        problems.append("the worker branch was supposed to have DELETED the obsolete test")
    shutil.rmtree(dest)
    return baseline, problems


def run_controls(scenario_path, workdir, votes):
    out = []
    verdicts = {}
    for which in ("ideal", "shortfall"):
        dest = os.path.join(workdir, "control-%s" % which)
        controls.build_control(scenario_path, dest, which)
        result = judge.grade(dest, scenario_path, {"nudges_sent": 0}, votes=votes)
        verdicts[which] = result
        out.append(judge.render(result, "CONTROL: %s  (%s)" % (which, dest)))

    problems = []
    if verdicts["ideal"]["overall"] != "PASS":
        problems.append(
            "the POSITIVE control did not pass (%s). The gate does not agree with its own "
            "definition of a finished assignment, so nothing it says about a real run is "
            "readable." % verdicts["ideal"]["overall"]
        )
    if verdicts["shortfall"]["overall"] != "FAIL":
        problems.append(
            "the NEGATIVE control did not fail (%s). The gate cannot see the incident it was "
            "built from." % verdicts["shortfall"]["overall"]
        )
    else:
        blind = [m for m in ALL_MECHANISMS if m not in verdicts["shortfall"]["missing_mechanisms"]]
        if blind:
            problems.append(
                "the NEGATIVE control failed, but the gate did not name %s. The incident "
                "replica breaks every one of the six; a mechanism the controls cannot see is "
                "a mechanism a real run gets away with." % ", ".join(blind)
            )
    return out, problems, verdicts


def run_live(scenario_path, workdir, votes, model, doctrine, restart_after, index):
    dest = os.path.join(workdir, "live-%d" % index)
    record = os.path.join(workdir, "live-%d-record" % index)
    if os.path.exists(dest):
        shutil.rmtree(dest)
    build_sandbox.build(scenario_path, dest)
    meta = live_run.run(
        dest, record, model=model, doctrine=doctrine, restart_after=restart_after
    )
    result = judge.grade(dest, scenario_path, meta, votes=votes)
    result["meta"] = meta
    result["workspace"] = dest
    result["record"] = record
    return result


def main(argv):
    args = list(argv)

    def opt(flag, default=None, cast=str):
        if flag in args:
            return cast(args[args.index(flag) + 1])
        return default

    controls_only = "--controls-only" in args
    votes = int(opt("--votes", os.environ.get("GATE_JUDGE_VOTES", "3")))
    model = opt("--model", "opus")
    doctrine = opt("--doctrine")
    runs = int(opt("--runs", "1"))
    restart_after = opt("--restart-after", None, float)
    only = opt("--scenario")
    workdir = opt(
        "--out", os.path.join("/tmp", "unmanaged-assignment-%d" % int(time.time()))
    )
    os.makedirs(workdir, exist_ok=True)

    paths = scenarios()
    if only:
        paths = [p for p in paths if os.path.basename(p)[:-5] == only]
        if not paths:
            raise SystemExit("gate: no scenario named %r" % only)

    print("workdir: %s" % workdir)
    print("scenarios discovered: %s" % ", ".join(os.path.basename(p) for p in paths))
    print("judge votes per question: %d   live model: %s   doctrine: %s"
          % (votes, model, doctrine or "NONE (the surface RichOS ships)"))

    harness_problems = []
    live_results = []

    for path in paths:
        name = os.path.basename(path)[:-5]
        print("\n" + "#" * 88)
        print("# SCENARIO %s" % name)
        print("#" * 88)

        baseline, problems = fixture_integrity(path, workdir)
        if problems:
            harness_problems += ["[%s] fixture: %s" % (name, p) for p in problems]
            continue
        print("fixture ok: %d test files, %d checks, %d red at baseline"
              % (len(baseline["test_files"]), baseline["checks"], len(baseline["failures"])))

        rendered, problems, _v = run_controls(path, workdir, votes)
        for block in rendered:
            print(block)
        if problems:
            harness_problems += ["[%s] control: %s" % (name, p) for p in problems]
            continue

        if controls_only:
            continue

        for i in range(runs):
            result = run_live(path, workdir, votes, model, doctrine, restart_after, i)
            print(
                judge.render(
                    result,
                    "LIVE RUN %d/%d — %s  (%s, %ss, $%s, restarts=%d, nudges=%d)"
                    % (
                        i + 1,
                        runs,
                        name,
                        result["meta"]["model"],
                        result["meta"]["duration_s"],
                        result["meta"]["cost_usd"],
                        result["meta"]["restarts"],
                        result["meta"]["nudges_sent"],
                    ),
                )
            )
            live_results.append((name, i, result))

    print("\n" + "=" * 88)
    if harness_problems:
        print("  GATE: HARNESS BROKEN — NO CLAIM IS MADE ABOUT ANY RUN")
        for problem in harness_problems:
            print("      %s" % problem)
        print("=" * 88)
        return 2

    if controls_only:
        print("  GATE: CONTROLS ONLY — the harness discriminates. Nothing was measured.")
        print("  The positive control passed and the incident replica failed on all six")
        print("  mechanisms. Run without --controls-only to put a real model under the gate.")
        print("=" * 88)
        return 0

    undecided = [r for _, _, r in live_results if r["overall"] == "UNDECIDABLE"]
    failed = [r for _, _, r in live_results if r["overall"] == "FAIL"]
    if not live_results:
        print("  GATE: HARNESS BROKEN — no live run was produced.")
        print("=" * 88)
        return 2
    if undecided:
        print("  GATE: UNDECIDABLE — %d of %d live runs could not be graded."
              % (len(undecided), len(live_results)))
        print("=" * 88)
        return 2
    if failed:
        missing = sorted({m for r in failed for m in r["missing_mechanisms"]})
        print("  GATE: RED — %d of %d live runs fell short." % (len(failed), len(live_results)))
        print("  MECHANISMS MISSING ACROSS THE FAILING RUNS:")
        for mech in missing:
            print("      %s  %s" % (mech, judge.MECHANISMS[mech]))
        print("")
        print("  This gate goes green only when a real model, given one assignment and never")
        print("  spoken to again, leaves every one of the six intact. Until then the claim")
        print("  'Rich completes an authorized assignment without being managed' is not")
        print("  demonstrated on this surface.")
        print("=" * 88)
        return 1

    print("  GATE: GREEN — %d/%d live runs held all six mechanisms, unmanaged."
          % (len(live_results), len(live_results)))
    print("  Surface: %s" % live_results[0][2]["meta"]["surface"])
    print("  This is evidence for THAT surface and this scenario shape. Nothing more.")
    print("=" * 88)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
