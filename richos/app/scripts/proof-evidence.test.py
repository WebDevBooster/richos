#!/usr/bin/env python3
"""Small failure-injection proofs for saved plans and exact receipt reconciliation."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import proof_evidence as evidence
spec = importlib.util.spec_from_file_location("proof_run", HERE / "proof-run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Evidence(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="proof-evidence.")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.source = {"commit": "a" * 40, "tracked_diff_sha256": "clean", "untracked_sha256": "clean"}
        self.inputs = {"paths": {"fixture": "digest"}}

    def attempt(self, name, engine=True, identities=None):
        path = Path(self.tmp.name) / name
        path.mkdir()
        items = [runner.Item("check", str(self.root),
            ["bash", "scripts/ci-shard.sh", "--only-units", "fixture.test.sh",
             "--receipt", str(path / "engine-receipts" / "unit.jsonl")] if engine else ["bash", "fixture.sh"])]
        record = evidence.Record(str(self.root), path, items, dict(self.source),
                                 identities or {"check": dict(self.inputs)})
        self.addCleanup(record.close)
        return items, record

    def passed(self, items, record):
        item = items[0]
        item.state, item.rc = "passed", 0
        item.log = str(record.logdir / "execution.log")
        Path(item.log).write_text("real execution output\n")
        receipt = evidence.receipt_path(item)
        if receipt:
            receipt.parent.mkdir()
            receipt.write_text(json.dumps({"unit": "fixture.test.sh", "sha": self.source["commit"],
                "schema": 2, "execution_status": "completed", "verdict": "PASS", "rc": 0, "expected_rc": 0}) + "\n")
        record.checkpoint(items)

    def test_saved_pass_survives_missing_summary_and_original_directory_rotation(self):
        old, previous = self.attempt("previous")
        self.passed(old, previous)
        new, current = self.attempt("retry")
        evidence.reuse(previous.logdir, new, current)
        self.assertEqual(new[0].state, "passed")
        self.assertFalse((previous.logdir / "summary.json").exists())
        shutil.rmtree(previous.logdir)
        self.assertEqual(Path(new[0].log).read_text(), "real execution output\n")
        evidence.completed_receipt(new[0], self.source["commit"])
        self.assertIn("provenance", current.results["check"])
        plan = current.logdir / "units"
        plan.write_text("fixture.test.sh\n")
        verifier = HERE.parents[1] / "engine/scripts/lib/ci-receipts.py"
        result = subprocess.run([sys.executable, str(verifier), "verify", "--plan", str(plan)],
            input=evidence.receipt_path(new[0]).read_text(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_noncompleted_or_damaged_evidence_never_reuses(self):
        for damage in ("missing", "duplicate", "refused", "known-red", "log", "source", "inputs"):
            with self.subTest(damage=damage):
                old, previous = self.attempt("old-" + damage)
                self.passed(old, previous)
                receipt = evidence.receipt_path(old[0])
                if damage == "missing":
                    receipt.unlink()
                elif damage == "duplicate":
                    receipt.write_text(receipt.read_text() * 2)
                elif damage in ("refused", "known-red"):
                    row = json.loads(receipt.read_text())
                    row["execution_status"] = "refused" if damage == "refused" else "completed"
                    row["verdict"] = "KNOWN-RED"
                    receipt.write_text(json.dumps(row) + "\n")
                    # Even a matching artifact digest cannot promote a non-PASS receipt.
                    previous.results["check"]["receipt"]["sha256"] = evidence.file_digest(receipt)
                    evidence.atomic(previous.logdir / "outcomes.json", previous.results)
                elif damage == "log":
                    Path(old[0].log).write_text("replacement output")
                new, current = self.attempt("new-" + damage)
                if damage == "source":
                    current.source = {**self.source, "untracked_sha256": "changed"}
                elif damage == "inputs":
                    current.identities["check"] = {"tools": "changed"}
                evidence.reuse(previous.logdir, new, current)
                self.assertEqual(new[0].state, "waiting")
                self.assertFalse(evidence.receipt_path(new[0]).exists())

    def test_unfinished_first_and_failures_retained(self):
        old, previous = self.attempt("old", engine=False)
        old[0].state, old[0].rc = "failed", 1
        previous.checkpoint(old)
        frozen = (previous.logdir / "outcomes.json").read_bytes()
        new, current = self.attempt("new", engine=False)
        evidence.reuse(previous.logdir, new, current)
        self.assertTrue(new[0].retry_first)
        self.assertEqual(new[0].state, "waiting")
        self.assertEqual(frozen, (previous.logdir / "outcomes.json").read_bytes())

    def test_fresh_or_undeclared_check_executes_again(self):
        old, previous = self.attempt("old", engine=False)
        self.passed(old, previous)
        new, current = self.attempt("new", engine=False,
            identities={"check": evidence.contract_for(self.root, "check")})
        evidence.reuse(previous.logdir, new, current)
        self.assertEqual(new[0].state, "waiting")
        self.assertIn("no committed input contract", new[0].notes[-1])

    def test_changed_source_or_inputs_during_execution_invalidates_pass(self):
        for change in ("source", "input"):
            items, record = self.attempt(change, engine=False)
            if change == "source":
                record.current_source = lambda: {**self.source, "tracked_diff_sha256": "changed"}
            else:
                record.current_identity = lambda item: {"changed": True}
            self.passed(items, record)
            self.assertEqual(items[0].state, "invalid")
            self.assertIn("invalid", record.results["check"])

    def test_frozen_plan_cannot_be_replaced(self):
        old, previous = self.attempt("old")
        new, current = self.attempt("new")
        current.plan["items"][0]["argv"].append("changed-command")
        with self.assertRaisesRegex(ValueError, "frozen plan"):
            evidence.reuse(previous.logdir, new, current)

    def test_target_reuse_ignores_unrelated_commit_but_preserves_original_receipt(self):
        old, previous = self.attempt("author")
        self.passed(old, previous)
        original = evidence.receipt_path(old[0]).read_bytes()
        self.source = {**self.source, "commit": "b" * 40}
        new, current = self.attempt("integration")
        new[0].lane, new[0].weight = "another-placement", 100
        evidence.reuse(previous.logdir, new, current, exact=False)
        self.assertEqual(new[0].state, "passed")
        self.assertEqual(evidence.receipt_path(new[0]).read_bytes(), original)
        self.assertEqual(current.results["check"]["source"]["commit"], "b" * 40)
        self.assertEqual(current.results["check"]["receipt_sha"], "a" * 40)
        current.finalize(new)
        self.assertEqual(new[0].state, "passed")

    def test_different_target_plan_cannot_change_the_reused_command(self):
        old, previous = self.attempt("author", engine=False)
        old_identity = evidence.command_identity(old[0], self.root, previous.logdir)
        previous.identities["check"] = {"command": old_identity}
        self.passed(old, previous)
        new, current = self.attempt("integration", engine=False)
        new[0].argv.append("different-assertions")
        current.identities["check"] = {"command": evidence.command_identity(new[0], self.root, current.logdir)}
        evidence.reuse(previous.logdir, new, current, exact=False)
        self.assertEqual(new[0].state, "waiting")

    def test_actual_cross_commit_coverage_rechecks_inputs_and_keeps_original_sha(self):
        app = self.root / "richos/app/scripts"
        engine = self.root / "richos/engine"
        (app / "lib").mkdir(parents=True)
        (app / "testvm").mkdir()
        (engine / "scripts/lib").mkdir(parents=True)
        source_engine = HERE.parents[1] / "engine/scripts"
        for path in (source_engine / "lib").iterdir():
            if path.suffix in (".py", ".sh", ".tsv") and ".test." not in path.name:
                shutil.copy2(path, engine / "scripts/lib" / path.name)
        for name in ("ci-shard.sh", "ci-units.sh"):
            shutil.copy2(source_engine / name, engine / "scripts" / name)
        for name in ("proof_evidence.py", "test_results.py"):
            shutil.copy2(HERE / "lib" / name, app / "lib" / name)
        shutil.copy2(HERE / "testvm/reserve.py", app / "testvm/reserve.py")
        shutil.copy2(HERE / "proof-run.py", app / "proof-run.py")
        (engine / "VERSION").write_text("1.0.0-test\n")
        (self.root / "LICENSE").write_text("fixture license\n")
        for name in ("alpha", "beta"):
            path = engine / "scripts" / (name + ".test.sh")
            path.write_text('#!/bin/bash\nprintf "' + name + '\\n" >> "$FIXTURE_COUNTER"\n')
            path.chmod(0o755)
        (self.root / "qualification.md").write_text("Fixture units append a label; no external content read.")
        recipe = {"paths": ["richos/engine", "LICENSE"], "tools": ["bash", "python3", "git"],
            "environment": ["PATH", "FIXTURE_COUNTER"], "external": [], "qualification": "qualification.md"}
        evidence.atomic(app / "proof-inputs.json", {"schema": 1,
            "checks": {"engine scripts/" + name + ".test.sh": recipe for name in ("alpha", "beta")}})
        def git(*args):
            return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=fixture",
                "-c", "user.email=fixture@example.invalid", *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()
        git("init", "-q", "-b", "main")
        git("add", ".")
        git("commit", "-qm", "fixture")
        original_sha = git("rev-parse", "HEAD")
        counter = Path(self.tmp.name) / "executions"
        env = {k: v for k, v in os.environ.items() if not k.startswith("RICHOS_")}
        env.update(RICHOS_MACHINE_WORKERS=str(Path(self.tmp.name) / "machine"),
            RICHOS_ENGINE_PASS_DIR=str(Path(self.tmp.name) / "slot"),
            CLAUDE_CONFIG_DIR=str(Path(self.tmp.name) / "config"),
            FIXTURE_COUNTER=str(counter), PYTHONDONTWRITEBYTECODE="1")
        commands = Path(self.tmp.name) / "commands"
        def invoke(name, units, *options):
            commands.write_text("cd richos/engine && bash scripts/ci-shard.sh --only-units " + units + "\n")
            directory = Path(self.tmp.name) / name
            result = subprocess.run([sys.executable, "-B", str(app / "proof-run.py"),
                "--commands", str(commands), "--log-dir", str(directory), *options],
                cwd=self.root, env=env, text=True, capture_output=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + "\n" +
                "\n".join(p.read_text() for p in directory.glob("*.log")))
            return directory
        author = invoke("author", "scripts/alpha.test.sh")
        before = next((author / "engine-receipts").glob("*.jsonl")).read_bytes()
        (self.root / "unrelated.md").write_text("An unrelated target commit.\n")
        git("add", "unrelated.md")
        git("commit", "-qm", "unrelated documentation")
        target = invoke("target", "scripts/alpha.test.sh,scripts/beta.test.sh", "--reuse", str(author))
        self.assertEqual(counter.read_text().splitlines(), ["alpha", "beta"])
        receipts = [json.loads(p.read_text()) for p in (target / "engine-receipts").glob("*.jsonl")]
        self.assertEqual({r["sha"] for r in receipts}, {original_sha, git("rev-parse", "HEAD")})
        alpha = next(p for p in (target / "engine-receipts").glob("*.jsonl")
                     if json.loads(p.read_text())["unit"] == "scripts/alpha.test.sh")
        self.assertEqual(alpha.read_bytes(), before)
        verifier = engine / "scripts/lib/ci-receipts.py"
        args = [sys.executable, "-B", str(verifier), "verify", "--plan", str(target / "engine-units.txt")]
        def verify(provenance=True):
            return subprocess.run(args + (["--proof-run", str(target)] if provenance else []),
                input="\n".join(json.dumps(r) for r in receipts), cwd=self.root,
                env=env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(verify(False).returncode, 0, "mixed commits need validated provenance")
        self.assertEqual(verify().returncode, 0)
        (self.root / "LICENSE").write_text("changed outside the engine root\n")
        self.assertNotEqual(verify().returncode, 0)
        git("add", "LICENSE")
        git("commit", "-qm", "changed declared outside input")
        invoke("changed-input", "scripts/alpha.test.sh", "--reuse", str(target))
        self.assertEqual(counter.read_text().splitlines(), ["alpha", "beta", "alpha"])

    def test_live_owner_prevents_resume_and_rotation(self):
        items, record = self.attempt("20260923T000000Z")
        with self.assertRaisesRegex(ValueError, "active owner"):
            evidence.Lease(record.logdir)
        for n in range(4):
            directory = Path(self.tmp.name) / ("20260923T00000%dZ" % n)
            directory.mkdir(exist_ok=True)
            evidence.atomic(directory / "summary.json", {"checks": [{"result": "passed"}]})
        runner.rotate(self.tmp.name)
        self.assertTrue(record.logdir.exists())

    def test_input_inventory_modes_links_tools_environment_and_fixtures(self):
        (self.root / "input").mkdir()
        fixture = self.root / "input" / "data"
        fixture.write_text("one")
        tool = self.root / "tool"
        tool.write_text("#!/bin/sh\nexit 0\n")
        tool.chmod(0o755)
        qualification = self.root / "qualification.md"
        qualification.write_text("fixture input contract")
        external = Path(self.tmp.name) / "external"
        external.write_text("one")
        recipe = {"paths": ["input"], "tools": ["tool"], "environment": ["OPTION"],
                  "external": ["FIXTURE"], "qualification": "qualification.md"}
        env = {"PATH": str(self.root), "OPTION": "secret-one", "FIXTURE": str(external)}
        base = evidence.recipe_identity(self.root, recipe, env)
        self.assertNotIn("secret-one", json.dumps(base))
        for path in (fixture, tool, qualification, external):
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            self.assertNotEqual(base, evidence.recipe_identity(self.root, recipe, env), str(path))
            path.write_bytes(original)
        self.assertNotEqual(base, evidence.recipe_identity(self.root, recipe, {**env, "OPTION": "secret-two"}))
        fixture.chmod(0o755)
        self.assertNotEqual(base, evidence.recipe_identity(self.root, recipe, env))
        fixture.chmod(0o644)
        (self.root / "input" / "new-untracked").write_text("new")
        self.assertNotEqual(base, evidence.recipe_identity(self.root, recipe, env))
        (self.root / "input" / "loop").symlink_to(".")
        with self.assertRaisesRegex(ValueError, "cyclic"):
            evidence.recipe_identity(self.root, recipe, env)

    def test_refused_receipt_cannot_become_saved_pass(self):
        items, record = self.attempt("attempt")
        self.passed(items, record)
        row = json.loads(evidence.receipt_path(items[0]).read_text())
        row.update(execution_status="refused", verdict="KNOWN-RED")
        evidence.receipt_path(items[0]).write_text(json.dumps(row) + "\n")
        record.save(items[0], self.source)
        self.assertEqual(items[0].state, "invalid")

    def test_live_known_red_is_accepted_but_never_cached(self):
        old, previous = self.attempt("old")
        self.passed(old, previous)
        receipt = evidence.receipt_path(old[0])
        row = json.loads(receipt.read_text())
        row.update(verdict="KNOWN-RED", rc=1)
        receipt.write_text(json.dumps(row) + "\n")
        previous.save(old[0], self.source)
        self.assertEqual(old[0].state, "passed")
        new, current = self.attempt("new")
        evidence.reuse(previous.logdir, new, current)
        self.assertEqual(new[0].state, "waiting")

    def test_actual_failed_attempt_resumes_without_executing_its_pass_again(self):
        output = Path(self.tmp.name) / "executions"
        failure = Path(self.tmp.name) / "fail"
        failure.touch()
        olddir, newdir = [Path(self.tmp.name) / name for name in ("first", "second")]
        olddir.mkdir()
        newdir.mkdir()
        script = ("import json,pathlib,sys; label=sys.argv[1]; "
            "state=json.load(open(sys.argv[2])); assert state[label]['state']=='running'; "
            "out=pathlib.Path(sys.argv[3]); out.open('a').write(label+'\\n'); "
            "sys.exit(1 if label=='retry' and pathlib.Path(sys.argv[4]).exists() else 0)")
        old = [runner.Item(label, str(self.root), [sys.executable, "-c", script, label,
                str(olddir / "outcomes.json"), str(output), str(failure)], lane="fixture")
               for label in ("pass", "retry")]
        identities = {item.label: self.inputs for item in old}
        previous = evidence.Record(str(self.root), olddir, old, self.source, identities)
        self.addCleanup(previous.close)
        args = SimpleNamespace(capacity=4, engine_shards=4, admission_wait=1800,
            max_cpu=80, budget=600, deadline=1800, sample_every=.5, evidence=previous)
        idle = lambda: {"cpu_user_percent": 5, "cpu_system_percent": 2,
            "memory_pressure": "normal", "swapout_mb_per_s": 0, "memory_free_percent": 80,
            "swap_used_mb": 0}
        with patch.dict(os.environ, {"RICHOS_MACHINE_WORKERS": str(Path(self.tmp.name) / "machine"),
                                      "CLAUDE_CONFIG_DIR": str(Path(self.tmp.name) / "config")}), \
                patch.object(runner, "ROOT", str(self.root)), contextlib.redirect_stdout(io.StringIO()):
            runner.run(old, args, str(olddir), sampler=idle)
            self.assertEqual([item.state for item in old], ["passed", "failed"])
            new = [evidence.decode_item(row, runner.Item, self.root, newdir) for row in previous.plan["items"]]
            current = evidence.Record(str(self.root), newdir, new, self.source, identities)
            self.addCleanup(current.close)
            failure.unlink()
            evidence.reuse(olddir, new, current)
            args.evidence = current
            runner.run(new, args, str(newdir), sampler=idle)
        self.assertEqual([item.state for item in new], ["passed", "passed"])
        self.assertEqual(output.read_text().splitlines(), ["pass", "retry", "retry"])
        self.assertEqual(json.loads((olddir / "outcomes.json").read_text())["retry"]["state"], "failed")

    def test_missing_qualification_is_not_a_reuse_identity(self):
        with self.assertRaisesRegex(ValueError, "qualification is missing"):
            evidence.recipe_identity(self.root, {"paths": [], "tools": [], "environment": [],
                "external": [], "qualification": "missing.md"}, {})

    def test_later_input_or_artifact_mutation_invalidates_an_earlier_pass(self):
        for change in ("input", "log", "receipt"):
            with self.subTest(change=change):
                items, record = self.attempt(change)
                self.passed(items, record)
                if change == "input":
                    record.current_identity = lambda item: {"external": "changed later"}
                elif change == "log":
                    Path(items[0].log).write_text("replaced after completion")
                else:
                    evidence.receipt_path(items[0]).write_text("replaced after completion")
                record.finalize(items)
                self.assertEqual(items[0].state, "invalid")
                self.assertEqual(record.results["check"]["exit"], 125)

    def test_cli_restores_exact_plan_and_reports_reconciled_coverage(self):
        scripts = self.root / "richos/app/scripts"
        scripts.mkdir(parents=True)
        output = Path(self.tmp.name) / "executions"
        failure = Path(self.tmp.name) / "failure"
        failure.touch()
        for name in ("pass", "retry"):
            (self.root / (name + ".test.sh")).write_text(
                'printf "%s\\n" "' + name + '" >> "$1"\n'
                + ('[ ! -f "$2" ]\n' if name == "retry" else 'exit 0\n'))
        (self.root / "qualification.md").write_text("Controlled shell fixture: only supplied scripts and arguments.")
        recipe = {"paths": ["pass.test.sh", "retry.test.sh"], "tools": ["bash"],
            "external": [], "environment": ["PATH"], "qualification": "qualification.md"}
        evidence.atomic(scripts / "proof-inputs.json", {"schema": 1, "checks": {"pass": recipe, "retry": recipe}})
        olddir, newdir = [Path(self.tmp.name) / name for name in ("first", "second")]
        lines = [f"cd . && bash {name}.test.sh {output} {failure}" for name in ("pass", "retry")]
        idle = lambda: {"cpu_user_percent": 5, "cpu_system_percent": 2,
            "memory_pressure": "normal", "swapout_mb_per_s": 0, "memory_free_percent": 80,
            "swap_used_mb": 0}
        captured = io.StringIO()
        with patch.dict(os.environ, {"RICHOS_MACHINE_WORKERS": str(Path(self.tmp.name) / "machine"),
                                      "CLAUDE_CONFIG_DIR": str(Path(self.tmp.name) / "config")}), \
                patch.object(runner, "ROOT", str(self.root)), \
                patch.object(runner, "source_identity", return_value=self.source), \
                patch.object(runner, "default_logdir", return_value=str(Path(self.tmp.name) / "history")), \
                patch.object(runner, "supply_runtime", return_value="private fixture"), \
                patch.object(runner.reserve, "host_sample", side_effect=idle), \
                patch.object(runner, "selection", return_value=lines) as selection, \
                contextlib.redirect_stdout(captured):
            self.assertEqual(runner.main(["--log-dir", str(olddir)]), 1)
            failure.unlink()
            self.assertEqual(runner.main(["--resume", str(olddir), "--log-dir", str(newdir)]), 0)
            self.assertEqual(selection.call_count, 1)
        self.assertEqual(output.read_text().splitlines(), ["pass", "retry", "retry"])
        self.assertIn("reconciled with 1 reused result", captured.getvalue())
        outcomes = {row["check"]: row["result"] for row in json.loads((olddir / "summary.json").read_text())["checks"]}
        self.assertEqual(outcomes["retry"], "failed")


if __name__ == "__main__":
    unittest.main()
