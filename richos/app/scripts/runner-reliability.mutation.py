#!/usr/bin/env python3
"""runner-reliability.mutation.py -- the SIGKILL-lease and borrow cases, watched going red.

WHY (2026-09-26). test_sigkill_owner_still_cleans_command_and_releases_lease refused two desktop
nightlies with "child did not start": it let its wrapper inherit RICHOS_MACHINE_WORKERS, which
inside a nightly is the REAL per-user machine budget, and the nightly's own concurrent suites
held all of it. Run alone the variable was unset, so the case passed and never took a machine
lease at all. The fix gave the case private budgets and a machine-lease assertion.

So every case here runs the way a nightly runs it: beside an AMBIENT machine budget that is
full, with the environment a suite inherits from run-tests.sh. First each case must pass
unmutated in that condition (that is the regression proof for the flake). Then each mutant
removes ONE property -- from the product (worker_tokens.py, proc_tree.py) or from the test's
own isolation -- and the case that owns it must go red.

THE SHIPPED FILES ARE NEVER OPENED FOR WRITING. Engine modules are mutated in a private copy of
engine/scripts/lib that is imported before the test runs (the wrapper subprocess runs that copy
too, because the test launches worker_tokens.__file__). The test file is compiled in memory
under its real name, so HERE and every path it derives are the real ones.

Invoked by proof-run.test.sh. Exit 0 = every property proven load-bearing.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1] / "engine/scripts/lib"
TEST = HERE / "runner-reliability.test.py"
sys.path.insert(0, str(LIB))
import proc_tree  # noqa: E402  (the shipped copy supervises every case run)
import worker_tokens  # noqa: E402

SIGKILL = "test_sigkill_owner_still_cleans_command_and_releases_lease"
BORROW = "test_borrow_files_do_not_create_extra_capacity"

# (name, file, case, old text, new text, the failure the case must report, what would happen
# without it). A mutant scores only when its case goes red WITH that failure, never an
# incidental import error.
MUTANTS = (
    ("the-run-takes-no-machine-lease", "worker_tokens.py", SIGKILL,
     "            if self.shared:\n                token.extra = self.shared.try_acquire()",
     "            if False:\n                token.extra = self.shared.try_acquire()",
     "[1, 0] != [1, 1]",
     "every run and nightly on this Mac could exceed the per-user worker ceiling."),
    ("owner-death-leaves-the-command-running", "proc_tree.py", SIGKILL,
     "if interrupted or identity(owner) != owner_id:",
     "if interrupted:",
     "owned child survived",
     "a SIGKILLed runner would leave its command running and its lease held until it ended."),
    ("borrow-files-count-as-tokens", "worker_tokens.py", BORROW,
     'if f.startswith("token-") and f[6:].isdigit()',
     'if f.startswith("token-")',
     "2 != 1",
     "every nested pool's borrow file would become one more worker than the budget allows."),
    ("the-sigkill-case-inherits-the-ambient-machine-budget", TEST.name, SIGKILL,
     "env = {**os.environ, 'RICHOS_MACHINE_WORKERS': str(machine)}\n"
     "        for key in ('RICHOS_WORKER_TOKENS', 'RICHOS_WORKER_SLOT_HELD', 'RICHOS_WORKER_BORROW_LOCK',",
     "env = dict(os.environ)\n"
     "        for key in ('RICHOS_WORKER_TOKENS', 'RICHOS_WORKER_SLOT_HELD', 'RICHOS_WORKER_BORROW_LOCK',",
     "child did not start",
     "the case would wait on the nightly's own full budget and refuse the build again."),
    ("the-borrow-case-inherits-the-ambient-machine-budget", TEST.name, BORROW,
     "parent = worker_tokens.Budget(budget, shared=False).try_acquire()",
     "parent = worker_tokens.Budget(budget).try_acquire()",
     "'NoneType' object has no attribute 'path'",
     "the case would fail whenever the nightly holds every machine token."),
)

# Imports the (possibly mutated) engine copies first, so the test's own `import worker_tokens`
# and `import proc_tree` resolve to them; then runs ONE case of the (possibly mutated) test text.
LAUNCHER = r"""
import json, os, sys, types, unittest
lib, test, case = sys.argv[1:4]
edit = json.loads(os.environ.pop('RUNNER_MUTATION_TEST_EDIT'))
sys.path.insert(0, lib)
import proc_tree, worker_tokens
assert os.path.dirname(os.path.abspath(worker_tokens.__file__)) == os.path.abspath(lib)
text = open(test).read()
if edit:
    text = text.replace(edit[0], edit[1])
module = types.ModuleType('runner_reliability_under_test')
module.__file__ = test
exec(compile(text, test, 'exec'), module.__dict__)
suite = unittest.defaultTestLoader.loadTestsFromName('Reliability.' + case, module)
result = unittest.TextTestRunner(verbosity=0).run(suite)
sys.exit(0 if result.testsRun == 1 and result.wasSuccessful() else 1)
"""


def passes(lib, case, edit, env, log):
    """One case, supervised by the shipped proc_tree so a mutant's surviving command is reaped."""
    env = {**env, "RUNNER_MUTATION_TEST_EDIT": json.dumps(edit)}
    with open(log, "wb") as out:
        result = subprocess.run(proc_tree.command([sys.executable, "-c", LAUNCHER, str(lib), str(TEST), case]),
                                env=env, stdout=out, stderr=subprocess.STDOUT, timeout=120)
    return result.returncode == 0


def main():
    sources = {"worker_tokens.py": (LIB / "worker_tokens.py").read_text(),
               "proc_tree.py": (LIB / "proc_tree.py").read_text(),
               TEST.name: TEST.read_text()}
    print("=== runner-reliability: SIGKILL lease + borrow, each property proven load-bearing ===")
    with tempfile.TemporaryDirectory(prefix="runner-reliability-mutation.") as tmp:
        tmp = Path(tmp)
        # The ambient machine budget a nightly exports, held in full, never the real one.
        ambient = tmp / "ambient-machine"
        worker_tokens.init(ambient, 8)
        whole = worker_tokens.Budget(ambient, runner=True, shared=False)
        held = [whole.try_acquire() for _ in whole.files]
        try:
            if not all(held) or worker_tokens.Budget(ambient, shared=False).held() != 8:
                print("  FAIL  setup: could not hold the whole ambient budget")
                return 1
            env = {**os.environ, "RICHOS_MACHINE_WORKERS": str(ambient), "RICHOS_WORKER_TOKENS": str(ambient),
                   "RICHOS_WORKER_TOKENS_TOOL": str(LIB / "worker_tokens.py"),
                   "RICHOS_WORKER_TOKENS_RESERVED": "2", "RICHOS_WORKER_SLOT_HELD": "1",
                   "RICHOS_WORKER_BORROW_LOCK": str(ambient / "suite-free.lock")}
            failed = 0
            clean = tmp / "lib-clean"
            shutil.copytree(LIB, clean, ignore=lambda _d, names: [
                n for n in names if not n.endswith(".py") or ".test." in n])
            for case in sorted({m[2] for m in MUTANTS}):
                started = time.monotonic()
                log = tmp / ("control-" + case + ".log")
                if passes(clean, case, None, env, log):
                    print(f"  PASS  control: {case} is green with the ambient machine budget full"
                          f"  [{time.monotonic() - started:.1f}s]")
                else:
                    print(f"  FAIL  control: {case} is red on the UNMUTATED source, so it proves nothing")
                    sys.stdout.write(log.read_text(errors="replace"))
                    failed += 1
            proven = 0
            for name, target, case, old, new, expect, why in MUTANTS:
                started = time.monotonic()
                count = sources[target].count(old)
                if count != 1:
                    print(f"  FAIL  {name}: the text to mutate appears {count} times in {target}, not once")
                    failed += 1
                    continue
                lib, edit = clean, None
                if target == TEST.name:
                    edit = (old, new)
                else:
                    lib = tmp / ("lib-" + name)
                    shutil.copytree(clean, lib)
                    (lib / target).write_text(sources[target].replace(old, new))
                log = tmp / (name + ".log")
                red = not passes(lib, case, edit, env, log)
                took = time.monotonic() - started
                if red and expect not in log.read_text(errors="replace"):
                    print(f"  FAIL  {name} -- {case} went red, but not with {expect!r}:")
                    sys.stdout.write(log.read_text(errors="replace"))
                    failed += 1
                elif red:
                    proven += 1
                    print(f"  PASS  {name} -- removing it turns {case} red  [{took:.1f}s]")
                else:
                    print(f"  FAIL  {name} -- {case} stayed green without it: {why}")
                    failed += 1
        finally:
            for token in held:
                if token:
                    token.release()
    print(f"=== mutation: {proven} of {len(MUTANTS)} properties proven"
          f"{'' if failed else ' -- all load-bearing'} ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
