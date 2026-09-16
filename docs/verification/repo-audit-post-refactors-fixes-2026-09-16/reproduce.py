#!/usr/bin/env python3
"""Verify the six audit fixes against disposable copies of this checkout.

Usage: python3 reproduce.py [repository-root] [output-directory]
Requires Python 3, Node, Bash and Git. No credentials, network or live capture.
Exits nonzero when a fixed behavior regresses; no production data is used.
"""
import argparse
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository_root", nargs="?", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[3])
    parser.add_argument("output_directory", nargs="?", type=pathlib.Path)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    out = (args.output_directory or pathlib.Path(tempfile.mkdtemp(prefix="richos-audit-results-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = {}
    with tempfile.TemporaryDirectory(prefix="richos-audit-probe-") as temp:
        base = pathlib.Path(temp).resolve()
        service = base / "product/richos/tools/richos-service"
        service.mkdir(parents=True)
        original = root / "richos/tools/richos-service"
        for directory in ("lib", "bin"):
            shutil.copytree(original / directory, service / directory)
        shutil.copy2(original / "package.json", service / "package.json")
        extension = base / "product/richos/tools/richos-extension"
        original_extension = root / "richos/tools/richos-extension"
        shutil.copytree(original_extension / "sync", extension / "sync")
        shutil.copy2(original_extension / "package.json", extension / "package.json")
        shutil.copy2(pathlib.Path(__file__).with_name("service-probes.mjs"), service / "probe.mjs")
        run = subprocess.run(["node", str(service / "probe.mjs")], capture_output=True,
                             text=True, timeout=30)
        (out / "service-stderr.log").write_text(run.stderr)
        if run.returncode:
            raise RuntimeError(run.stderr)
        results["service"] = json.loads(run.stdout)

    # Reuse the relocation suite's isolated engine, HOME, settings and Git config.
    spec = importlib.util.spec_from_file_location(
        "audit_relocation", root / "richos/engine/ass-kicker/tests/relocation.test.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fixture = module.Relocation()
    try:
        fixture.setUp()
        config = fixture.engine / "orchestration.config"
        payload = {"cwd": str(fixture.engine), "session_id": "audit-notice-session",
                   "last_assistant_message": "Done."}

        def invoke():
            run = fixture.command("bash", "scripts/hooks/guard-stated-actions.sh",
                                  input=json.dumps(payload), check=False)
            return {"exit": run.returncode, "stdout": run.stdout, "stderr": run.stderr}

        config.write_text("CHECK_STATED_ACTIONS=0\n")
        stood_down = invoke()
        config.write_text("CHECK_STATED_ACTIONS=1\n")
        payload["last_assistant_message"] = 123
        crash = invoke()
        payload["last_assistant_message"] = "Done."
        normal = invoke()
        assert crash["exit"] == 0 and "NOT RUNNING" in crash["stdout"]
        assert "RUNNING AGAIN" not in crash["stdout"]
        assert normal["exit"] == 0 and "RUNNING AGAIN" in normal["stdout"]
        results["stated_action_notice"] = {
            "stood_down": stood_down, "crash": crash, "normal_control": normal}
    finally:
        fixture.doCleanups()

    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Results:", out)


if __name__ == "__main__":
    main()
