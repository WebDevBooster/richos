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
    ("src/run.rs", "accept-without-passing-checks", "} else if passed {", "} else if true {",
     "ending_a_turn_cannot_complete_failed_work_and_the_controller_continues"),
    ("src/run.rs", "ignore-attempt-budget", "self.snapshot.tasks[i].attempts < self.snapshot.plan.max_attempts", "true",
     "failed_checks_exhaust_budget_without_running_dependents_or_claiming_completion"),
    ("src/run.rs", "replay-interrupted-work", "if matches!(t.state, TaskState::Running | TaskState::Verifying)", "if false",
     "interrupted_execution_is_not_replayed_on_restart_and_a_torn_append_is_recovered"),
    ("src/run.rs", "remove-writer-lock", ".try_lock()", ".metadata().map(|_| ())",
     "a_second_controller_cannot_dispatch_duplicate_work_and_status_reads_do_not_recover_live_tasks"),
    ("src/spine.rs", "hide-managed-output", "record_prompt_received(binding, text, Source::Proactive)", "record_prompt_received(binding, text, Source::Internal)",
     "desktop_adapter_uses_real_scoped_spine_turns_and_external_verification"),
    ("src/native.rs", "autoapprove-managed-permissions", "let decision = if managed {", "let decision = if false {",
     "managed_native_transport_loads_settings_and_denies_unapproved_tools"),
    ("src/native.rs", "strip-managed-settings", '"user,project,local".into()', '"".into()',
     "managed_native_transport_loads_settings_and_denies_unapproved_tools"),
    ("src/run.rs", "require-workspace-for-recovery", "snapshot.plan.validate_structure()?", "snapshot.plan.validate()?",
     "unavailable_workspace_can_be_inspected_and_ended_but_never_executed"),
    ("src/run.rs", "ignore-resource-ceiling", ">= RECOVERY_BUDGET", ">= 1000",
     "recovery_checkpoints_charge_real_cycles_and_stop_at_resource_decision"),
    ("src/run.rs", "skip-recovery-checkpoint", "== RECOVERY_CHECKPOINT", "== 999",
     "recovery_checkpoints_charge_real_cycles_and_stop_at_resource_decision"),
    ("src/run.rs", "reexecute-broken-review", "self.snapshot.plan.autonomous() && self.snapshot.tasks[i].review_pending", "false",
     "review_only_failures_exhaust_the_same_persisted_resource_budget"),
    ("src/registration.rs", "trust-inconsistent-registration", "action != value.rich_committed", "false",
     "neither_false_none_nor_unaccepted_work_crosses_the_consistency_floor"),
    ("src/registration.rs", "drop-verbatim-request", 'CEO request (verbatim):\\n{request}\\nRich', 'Rich',
     "the_contract_preserves_every_byte_including_negative_constraints_and_tail"),
    ("src/spine.rs", "reprime-before-every-report", "self.deliver(id, binding, &prompt, true)", "{ self.lease_primed = false; self.deliver(id, binding, &prompt, true) }",
     "rich_keeps_voice_and_reports_without_registration_or_redundant_priming"),
    ("src/registration.rs", "reject-markdown-whitespace", "normalize(source).contains(&quote)", "source.contains(&quote)",
     "markdown_quote_provenance_tolerates_whitespace_but_preserves_full_contract"),
    ("src/registration.rs", "trust-invented-quotes", "normalize(source).contains(&quote)", "true",
     "quotes_cannot_stitch_passages_change_negation_or_borrow_another_message"),
]

with tempfile.TemporaryDirectory(prefix="richos-run-mutations-") as temporary:
    root = Path(temporary)
    copy = root / "core"
    shutil.copytree(core, copy, ignore=shutil.ignore_patterns("target"))
    shutil.copyfile(core.parents[1] / "Cargo.lock", copy / "Cargo.lock")
    env = dict(os.environ, CARGO_TARGET_DIR=str(root / "target"))
    command = [cargo, "test", "--offline", "--manifest-path", str(copy / "Cargo.toml"), "--test", "run_tests", "--test", "registration_tests"]
    baseline = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if baseline.returncode:
        sys.exit("Baseline failed; no mutation verdict is valid.\n" + baseline.stdout)
    for _, _, _, _, test in mutations:
        if f"test {test} ... ok" not in baseline.stdout:
            sys.exit("Baseline did not execute the required test: " + test + "\n" + baseline.stdout)
    passed = 0
    for relative, name, old, new, test in mutations:
        file = copy / relative
        source = file.read_text()
        if old not in source:
            sys.exit("Mutation target disappeared: " + name)
        file.write_text(source.replace(old, new))
        result = subprocess.run(command + [test, "--", "--exact"], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode == 0 or f"test {test} ... FAILED" not in result.stdout:
            sys.exit("Mutation did not fail at its intended test: " + name + "\n" + result.stdout)
        file.write_text(source)
        print("PASS: " + name + " fails " + test, flush=True)
        passed += 1
    print(f"{passed}/{len(mutations)} behavioral mutations killed.")
