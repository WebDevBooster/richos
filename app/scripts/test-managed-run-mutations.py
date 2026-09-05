#!/usr/bin/env python3
"""Break the controller in disposable copies and require specific regressions.

Usage: python3 app/scripts/test-managed-run-mutations.py [cargo executable]
No source checkout is modified. Compiler errors never count as killed mutants.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

core = Path(__file__).resolve().parents[1] / "crates/richos-core"
cargo = sys.argv[1] if len(sys.argv) > 1 else "cargo"
mutations = [
    ("accept-without-passing-checks", "} else if passed {", "} else if true {",
     "ending_a_turn_cannot_complete_failed_work_and_the_controller_continues"),
    ("ignore-attempt-budget", "self.snapshot.tasks[i].attempts < self.snapshot.plan.max_attempts", "true",
     "failed_checks_exhaust_budget_without_running_dependents_or_claiming_completion"),
    ("replay-interrupted-work", "if matches!(t.state, TaskState::Running | TaskState::Verifying)", "if false",
     "interrupted_execution_is_not_replayed_on_restart_and_a_torn_append_is_recovered"),
    ("remove-writer-lock", ".try_lock()", ".metadata().map(|_| ())",
     "a_second_controller_cannot_dispatch_duplicate_work_and_status_reads_do_not_recover_live_tasks"),
]

with tempfile.TemporaryDirectory(prefix="richos-run-mutations-") as temporary:
    root = Path(temporary)
    copy = root / "core"
    shutil.copytree(core, copy, ignore=shutil.ignore_patterns("target"))
    shutil.copyfile(core.parents[1] / "Cargo.lock", copy / "Cargo.lock")
    env = dict(os.environ, CARGO_TARGET_DIR=str(root / "target"))
    command = [cargo, "test", "--offline", "--manifest-path", str(copy / "Cargo.toml"), "--test", "run_tests"]
    baseline = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if baseline.returncode:
        sys.exit("Baseline failed; no mutation verdict is valid.\n" + baseline.stdout)
    file = copy / "src/run.rs"
    source = file.read_text()
    passed = 0
    for name, old, new, test in mutations:
        if old not in source:
            sys.exit("Mutation target disappeared: " + name)
        file.write_text(source.replace(old, new))
        result = subprocess.run(command + [test, "--", "--exact"], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0 or f"test {test} ... FAILED" not in result.stdout:
            sys.exit("Mutation did not fail at its intended test: " + name + "\n" + result.stdout)
        print("PASS: " + name + " fails " + test, flush=True)
        passed += 1
    print(f"{passed}/{len(mutations)} behavioral mutations killed.")
