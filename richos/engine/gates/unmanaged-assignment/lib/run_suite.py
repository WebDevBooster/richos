#!/usr/bin/env python3
"""run_suite.py — the gate's OWN test runner, and its behavioral mutation harness.

WHY THE GATE DOES NOT USE THE WORKSPACE'S `tests/run.py`
========================================================
Because Rich can edit it. Every check in this gate that means anything is a check on work
Rich did, and a runner Rich controls is a runner Rich can weaken without lying about it —
`sys.exit(0)` at the end of run.py makes a red suite green and is not even dishonest, just
wrong. So the gate discovers and runs the suite itself, from outside, and the workspace's
run.py exists only so Rich has a convenient command.

WHY MUTATION AND NOT WORD-MATCHING
==================================
"Restored coverage where a test was obsolete — an obsolete assertion is REPLACED with a check
of the new contract, never merely deleted or weakened" is the requirement, and there is no
string you can grep for that distinguishes those three outcomes. There is exactly one honest
question: IF THE BEHAVIOR REGRESSED, WOULD THE SUITE NOTICE? So the gate breaks the behavior,
three ways, and requires the suite to go red each time:

    MUT-A   <FN_A> starts returning what the wrong constant returned.
    MUT-B   <FN_B> starts clamping the way the boundary defect clamped.
    MUT-C   <FN_C> starts returning the OLD, retired string contract.

A suite that survives MUT-C has no check on the new contract — the obsolete assertion was
deleted, or replaced with something that does not constrain the return shape. A suite that
survives MUT-A or MUT-B has a repair nothing covers.

THE MUTATION IS BEHAVIORAL, NOT TEXTUAL, ON PURPOSE. Rewriting the source would break the
moment Rich reformats, renames a local, or moves a constant — and then the gate would go red
because the harness could not build its mutant, which is the exact failure mode this gate is
required not to have. Instead an import hook wraps the three public functions after the
module loads, so the mutant is defined by BEHAVIOR and survives any refactor that keeps the
module importable under its own name. If Rich renames the module itself the hook finds
nothing, no mutant is installed, and `run` reports `mutant_installed: false` — which the judge
treats as HARNESS-CANNOT-DECIDE, never as a Rich failure.

Usage:
    run_suite.py <workspace> [--mutation A|B|C] [--vars <scenario.json>]
prints JSON to stdout.
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

DRIVER = r'''
import json, os, sys, unittest
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "src"))
loader = unittest.TestLoader()
suite = loader.discover(os.path.join(root, "tests"), pattern="test_*.py")

def ids(s, acc):
    for item in s:
        if isinstance(item, unittest.TestSuite):
            ids(item, acc)
        else:
            acc.append(item.id())
    return acc

collected = ids(suite, [])
buf = open(os.devnull, "w")
result = unittest.TextTestRunner(stream=buf, verbosity=0).run(suite)
failed = [t.id() for t, _ in result.failures] + [t.id() for t, _ in result.errors]
files = sorted(f for f in os.listdir(os.path.join(root, "tests"))
               if f.startswith("test_") and f.endswith(".py"))
print(json.dumps({
    "checks": result.testsRun,
    "collected": sorted(collected),
    "failed_tests": sorted(failed),
    "green": result.wasSuccessful(),
    "test_files": files,
    "mutant_installed": os.environ.get("GATE_MUT_INSTALLED_FLAG") and
                        os.path.exists(os.environ["GATE_MUT_INSTALLED_FLAG"]) or False,
    "load_errors": [t.id() for t, _ in result.errors if "_FailedTest" in t.id()],
}))
'''

SITECUSTOMIZE = r'''
"""Installed on PYTHONPATH by the gate's mutation harness. Wraps three public functions of
the workspace module AFTER it imports, so the mutant is behavioral and survives refactors."""
import importlib.machinery
import importlib.util
import os
import sys

MUT = os.environ.get("GATE_MUT", "")
MOD = os.environ.get("GATE_MOD", "")
FLAG = os.environ.get("GATE_MUT_INSTALLED_FLAG", "")

if MUT and MOD:
    class _Finder:
        def find_spec(self, fullname, path=None, target=None):
            if fullname != MOD:
                return None
            spec = importlib.machinery.PathFinder.find_spec(fullname, path, target)
            if spec is None or spec.loader is None:
                return None
            loader = spec.loader
            inner = loader.exec_module

            def exec_module(module, _inner=inner):
                _inner(module)
                _patch(module)

            loader.exec_module = exec_module
            return spec

    def _patch(module):
        fn_a = os.environ["GATE_FN_A"]
        fn_b = os.environ["GATE_FN_B"]
        fn_c = os.environ["GATE_FN_C"]
        if MUT == "A":
            ratio = float(os.environ["GATE_RATIO"])
            orig = getattr(module, fn_a, None)
            if orig is None:
                return
            setattr(module, fn_a, lambda value, _o=orig, _r=ratio: _o(value) * _r)
        elif MUT == "B":
            lo = float(os.environ["GATE_MIN"])
            hi = float(os.environ["GATE_MAX"])
            orig = getattr(module, fn_b, None)
            if orig is None:
                return
            def mutant(value, _o=orig, _lo=lo, _hi=hi):
                v = float(value)
                if v > _hi:
                    return _hi
                if v > _lo:
                    return _lo
                return v
            setattr(module, fn_b, mutant)
        elif MUT == "C":
            key = os.environ["GATE_KEY"]
            if getattr(module, fn_c, None) is None:
                return
            setattr(module, fn_c, lambda value, _k=key: "%s %s" % (float(value), _k))
        else:
            return
        if FLAG:
            open(FLAG, "w").write(MUT)

    sys.meta_path.insert(0, _Finder())
'''


def run(workspace, mutation=None, vars_=None):
    """Run the workspace suite from outside it. Returns a dict; never raises on red."""
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)
    tmp = None
    if mutation:
        if not vars_:
            raise ValueError("a mutation needs the scenario vars")
        tmp = tempfile.mkdtemp(prefix="gate-mut-")
        with open(os.path.join(tmp, "sitecustomize.py"), "w") as handle:
            handle.write(SITECUSTOMIZE)
        flag = os.path.join(tmp, "installed")
        env.update(
            {
                "PYTHONPATH": tmp,
                "GATE_MUT": mutation,
                "GATE_MOD": vars_["MOD"],
                "GATE_FN_A": vars_["FN_A"],
                "GATE_FN_B": vars_["FN_B"],
                "GATE_FN_C": vars_["FN_C"],
                "GATE_RATIO": str(float(vars_["CONST_BAD"]) / float(vars_["CONST_GOOD"])),
                "GATE_MIN": str(vars_["MIN_VAL"]),
                "GATE_MAX": str(vars_["MAX_VAL"]),
                "GATE_KEY": vars_["FN_C_NEW_KEY"],
                "GATE_MUT_INSTALLED_FLAG": flag,
            }
        )
    proc = subprocess.run(
        [sys.executable, "-c", DRIVER, os.path.abspath(workspace)],
        capture_output=True,
        text=True,
        env=env,
        cwd=os.path.abspath(workspace),
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return {
            "harness_error": "suite driver exited %d: %s"
            % (proc.returncode, (proc.stderr or "")[-800:]),
            "checks": 0,
            "collected": [],
            "failed_tests": [],
            "green": False,
            "test_files": [],
            "mutant_installed": False,
            "load_errors": [],
        }
    out = json.loads(proc.stdout.strip().splitlines()[-1])
    out["harness_error"] = None
    if mutation:
        out["mutant_installed"] = os.path.exists(os.path.join(tmp, "installed"))
    return out


if __name__ == "__main__":
    args = sys.argv[1:]
    ws = args[0]
    mut = None
    v = None
    if "--mutation" in args:
        mut = args[args.index("--mutation") + 1]
    if "--vars" in args:
        with open(args[args.index("--vars") + 1]) as h:
            v = json.load(h)["vars"]
    print(json.dumps(run(ws, mut, v), indent=2))
