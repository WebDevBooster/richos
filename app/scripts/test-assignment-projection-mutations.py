#!/usr/bin/env python3
"""Prove display regressions fail after successful compilation, in disposable copies."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

app = Path(__file__).resolve().parents[1]
cargo = sys.argv[1] if len(sys.argv) > 1 else "cargo"
with tempfile.TemporaryDirectory(prefix="richos-projection-mutations-") as tmp:
    root = Path(tmp)
    source = (app / "src-tauri/src/run_view.rs").read_text()
    probe = (app / "crates/richos-core/examples/run_view_probe.rs").read_text().replace('../../../src-tauri/src/run_view.rs', 'projection.rs')
    (root / "src").mkdir()
    (root / "src/main.rs").write_text(probe)
    (root / "Cargo.toml").write_text('[package]\nname="projection-review"\nversion="0.1.0"\nedition="2021"\n[dependencies]\nserde={version="1",features=["derive"]}\nserde_json="1"\nuuid={version="1",features=["v4"]}\nrichos-core={path=' + json.dumps(str(app / "crates/richos-core")) + '}\n')
    shutil.copyfile(app / "Cargo.lock", root / "Cargo.lock")
    env = dict(os.environ, CARGO_TARGET_DIR=str(root / "target"))
    def run(text):
        (root / "src/projection.rs").write_text(text)
        build = subprocess.run([cargo,"build","--offline","--quiet","--manifest-path",str(root / "Cargo.toml")], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        if build.returncode:
            sys.exit("Compilation failed. This is not a killed mutation.\n" + build.stdout)
        return subprocess.run([str(root / "target/debug/projection-review")], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    baseline = run(source)
    if baseline.returncode or len(json.loads(baseline.stdout)) != 3:
        sys.exit("Baseline did not produce all three projections.\n" + baseline.stdout)
    print("PASS baseline: real controller receipts and all three projections")
    mutations = [
        ("raw-task-description", "description: if snapshot.plan.autonomous() {", "description: if false {", "assertion `left == right` failed"),
        ("raw-verifier-receipt", "if snapshot.plan.autonomous() && human_contract(&t.prompt).is_some() {", "if false {", "Machine contract leaked:"),
    ]
    for name, old, new, expected in mutations:
        if source.count(old) != 1:
            sys.exit("Mutation anchor changed: " + name)
        result = run(source.replace(old,new))
        if result.returncode == 0 or expected not in result.stdout:
            sys.exit("Mutation did not fail for its expected assertion: " + name + "\n" + result.stdout)
        print("PASS killed " + name + " after successful compilation")
    print("2/2 projection mutations rejected")
