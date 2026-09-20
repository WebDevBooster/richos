#!/usr/bin/env python3
"""Rust and shell lint entry point. Run lint.sh --help for modes."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import advisory_rules
from common import APP, Refusal, checked, inventory, select, shellcheck
import dialect
import process_rules
import ratchet
import rust
import state
import suite_rules
import timeout_rules

ROOT = Path(__file__).resolve().parents[4]
BASE = APP + "scripts/lint/baselines/"
RULES = {**process_rules.RULES, **timeout_rules.RULES, **advisory_rules.RULES, **dialect.RULES, **suite_rules.RULES}


def versions(root, cargo=False):
    result = {"python": f"{sys.version_info.major}.{sys.version_info.minor}"}
    shell_version = checked(["shellcheck", "--version"], root)
    if "version: 0.11.0" not in shell_version:
        raise Refusal("ShellCheck 0.11.0 is required")
    result["shellcheck"] = "0.11.0"
    if cargo:
        result["clippy"] = checked(["cargo", "clippy", "--version"], root).strip()
        result["rustc"] = checked(["rustc", "-Vv"], root).strip()
    return result


def record(commands, tool_versions, rules, rows, counts):
    return dict(schema=1, limitation=ratchet.NOTE, commands=commands, versions=tool_versions,
                rules=rules, inventory=rows, counts=counts or {"no-diagnostics": 0})


def summarize(name, counts, diagnostics):
    print(name + ": " + (", ".join(f"{key}={value}" for key, value in sorted(counts.items()) if value) or "no blocking diagnostics"), flush=True)
    advisory = Counter(d["rule"] for d in diagnostics if d.get("classification") == "advisory")
    if advisory:
        print("Advisory candidates (review required): " + ", ".join(f"{key}={value}" for key, value in sorted(advisory.items())), flush=True)


def custom(root, rows):
    findings = []
    counts = {rule: 0 for rule, kind in RULES.items() if kind == "blocking"}
    paths = select(rows, "shell") + select(rows, "rust")
    for path in paths:
        text = (root / path).read_text()
        row = rows[path]
        found = advisory_rules.scan(text, row["role"], row["language"])
        if row["language"] == "shell":
            found += process_rules.scan(text) + timeout_rules.scan(text)
            found += suite_rules.scan(path, text)
        for rule, line in found:
            findings.append(dict(path=path, line=line, rule=rule, classification=RULES[rule]))
            if RULES[rule] == "blocking":
                counts[rule] += 1
    def scan_path(path):
        return path, dialect.scan(root, path, (root / path).read_text())
    # Each hook receives its real file path, preserving ownership and exemptions.
    with ThreadPoolExecutor(max_workers=4) as pool:
        for path, labels in pool.map(scan_path, paths):
            counts["dialect"] += len(labels)
            findings.extend(dict(path=path, rule="dialect", classification="blocking", message=label) for label in labels)
    return counts, findings


def enforce(root, name, actual, args):
    path = BASE + name + ".json"
    baseline_path = root / path
    trusted = ratchet.trusted_record(root, args.trusted_ref, path)
    if args.bootstrap and not baseline_path.exists():
        if trusted is not None:
            raise Refusal(f"bootstrap refuses a baseline already on integration: {name}")
        ratchet.validate(actual)
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(actual, indent=2, sort_keys=True) + "\n")
        return
    try:
        baseline = json.loads(baseline_path.read_text())
    except (OSError, ValueError) as exc:
        raise Refusal(f"missing or malformed baseline: {name}") from exc
    if trusted is not None:
        ratchet.compare(baseline, trusted)
    ratchet.check(actual, baseline)
    if args.lower:
        baseline_path.write_text(json.dumps(ratchet.lower(actual, baseline), indent=2, sort_keys=True) + "\n")


def js_report(root, rows):
    findings = []
    for path in select(rows, "javascript"):
        row = rows[path]
        findings.extend(dict(path=path, line=line, rule=rule, classification="advisory")
                        for rule, line in advisory_rules.scan((root / path).read_text(), row["role"], "javascript"))
        findings.extend(dict(path=path, rule="dialect", classification="structural-match", message=label)
                        for label in dialect.scan(root, path, (root / path).read_text()))
    return {"status": "report-only; advisory candidates require review; dialect matches come from the existing hook",
            "files": len(select(rows, "javascript")), "findings": findings,
            "unsupported": ["process-pattern-kill (shell syntax only)", "process-self-wait (shell syntax only)", "timeout-success (shell syntax only)"],
            "counts": {rule: sum(f["rule"] == rule for f in findings) for rule in (*advisory_rules.RULES, "dialect")}}


def fast_was_run(path, run_id):
    """A script-suite skip cannot bypass the every-build fast lint requirement."""
    if path is None:
        return False
    try:
        data = json.loads(path.read_text())
        if data.get("run_id") != run_id:
            return False
        matches = [s for s in data["suites"] if s["name"] == "lint.test.sh"]
        return len(matches) == 1 and matches[0]["state"] == "passed"
    except (OSError, ValueError, KeyError, TypeError):
        return False


def tauri(root, args, rows, tools, report):
    started = time.monotonic()
    deadline = started + 180
    fingerprint = rust.tauri_inputs(root, tools, deadline)
    green_path = args.state_dir / "lint-tauri-green.json"
    if green_path.resolve().is_relative_to(root.resolve()):
        raise Refusal("last-green state must be outside the source checkout")
    # A baseline edit invalidates the fingerprint before the skip decision.
    if args.nightly and state.green(green_path, fingerprint):
        print("Tauri Clippy skipped: inputs unchanged since its last green check", flush=True)
        report["tauri"] = {"skipped": True, "seconds": time.monotonic() - started}
        return
    print("Tauri Clippy running (180-second cap, including Cargo lock waiting)", flush=True)
    counts, diagnostics = rust.collect(root, rust.TAURI, deadline)
    report["tauri"] = dict(seconds=time.monotonic() - started, counts=counts, diagnostics=diagnostics)
    summarize("Tauri Clippy", counts, diagnostics)
    actual = record({"clippy": rust.TAURI}, tools, {"compiler-diagnostics": "blocking"},
                    {p: r for p, r in rows.items() if r["language"] == "rust"}, counts)
    enforce(root, "tauri", actual, args)
    # Do not bless inputs changed during the check, even by another checkout or
    # an editor. Bootstrap/lower changes a fingerprint input and needs a rerun.
    if not (args.bootstrap or args.lower):
        if rust.tauri_inputs(root, tools, deadline) != fingerprint:
            raise Refusal("Tauri inputs changed during Clippy; last-green unchanged")
        if time.monotonic() >= deadline:
            raise TimeoutError("Tauri Clippy deadline expired")
        revision = checked(["git", "rev-parse", "HEAD"], root).strip()
        state.save(green_path, fingerprint, revision, root)
    report["tauri"] = dict(seconds=time.monotonic() - started, counts=counts, diagnostics=diagnostics)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--fast", action="store_true", help="Rust fast set, shell and custom checks (default)")
    modes.add_argument("--all", action="store_true", help="fast set plus unconditional Tauri Clippy")
    modes.add_argument("--nightly", action="store_true", help="conditional Tauri check inside the owning nightly")
    modes.add_argument("--static", action="store_true", help="shell and custom checks only; not the full build gate")
    modes.add_argument("--js-report", action="store_true", help="report advisory JavaScript candidates only")
    updates = parser.add_mutually_exclusive_group()
    updates.add_argument("--lower", action="store_true", help="propose lower baselines as a working-tree diff")
    updates.add_argument("--bootstrap", action="store_true", help="create initial baselines only when absent on integration")
    parser.add_argument("--trusted-ref", default="refs/heads/main")
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".richos-nightly")
    parser.add_argument("--suite-results", type=Path, help="current nightly script-suite receipt")
    parser.add_argument("--json-out", type=Path, help="write detailed measurement output to the named file")
    args = parser.parse_args(argv)
    started = time.monotonic()
    report = {}
    try:
        # All tool invocations use the same controlled profiles as the nightly.
        os.environ["CARGO_PROFILE_DEV_DEBUG"] = "0"
        os.environ["CARGO_PROFILE_TEST_DEBUG"] = "0"
        rows = inventory(ROOT)
        if args.js_report:
            report = js_report(ROOT, rows)
            print(json.dumps(report, indent=2))
            return 0
        if args.nightly and not os.environ.get("RICHOS_NIGHTLY_RUN_ID"):
            raise Refusal("--nightly requires the nightly's execution marker")
        # Standalone measurement scheduling belongs to the operator. The lint
        # never probes release.lock or host load, including inside a nightly
        # that already owns that lock. Cargo arbitrates its own cache lock.
        tool_versions = versions(ROOT, cargo=not args.static)
        if not args.nightly or not fast_was_run(args.suite_results, os.environ.get("RICHOS_NIGHTLY_RUN_ID")):
            tick = time.monotonic()
            print("ShellCheck and custom rules running", flush=True)
            counts, diagnostics = shellcheck(ROOT, rows)
            report["shell"] = dict(counts=counts, diagnostics=diagnostics)
            summarize("ShellCheck", counts, diagnostics)
            shell_rows = {p: r for p, r in rows.items() if r["language"] == "shell"}
            shell_record = record({"shellcheck": ["shellcheck", "--format=json", "--rcfile=" + APP + ".shellcheckrc", "<shell-inventory>"]},
                                  {"shellcheck": tool_versions["shellcheck"]}, {"shellcheck-diagnostics": "blocking"}, shell_rows, counts)
            enforce(ROOT, "shell", shell_record, args)
            counts, diagnostics = custom(ROOT, rows)
            report["custom"] = dict(counts=counts, diagnostics=diagnostics, seconds=time.monotonic() - tick)
            summarize("Project rules", counts, diagnostics)
            custom_record = record({"custom": ["python3", APP + "scripts/lint/driver.py", "<rust-and-shell-inventory>"]},
                                   {"python": tool_versions["python"]}, RULES,
                                   {p: r for p, r in rows.items() if r["language"] != "javascript"}, counts)
            enforce(ROOT, "custom", custom_record, args)
            print(f"Static checks complete in {time.monotonic() - tick:.2f}s", flush=True)
            if not args.static:
                tick = time.monotonic()
                print("Rust fast set running", flush=True)
                counts, diagnostics = rust.collect(ROOT, rust.FAST)
                report["rust-fast"] = dict(counts=counts, diagnostics=diagnostics, seconds=time.monotonic() - tick)
                summarize("Rust fast set", counts, diagnostics)
                enforce(ROOT, "rust-fast", record({"clippy": rust.FAST}, tool_versions,
                        {"compiler-diagnostics": "blocking"}, {p: r for p, r in rows.items() if r["language"] == "rust"}, counts), args)
        if args.all or args.nightly:
            tauri(ROOT, args, rows, tool_versions, report)
        print(f"Lint passed in {time.monotonic() - started:.2f}s", flush=True)
        return 0
    except (Refusal, OSError, ValueError, subprocess.TimeoutExpired, TimeoutError) as exc:
        if isinstance(exc, (TimeoutError, subprocess.TimeoutExpired)):
            message = "lint deadline refused: Tauri cap 180 seconds (including Cargo lock waiting); launched work stopped" if args.all or args.nightly else "lint command deadline expired; launched work stopped"
        else:
            message = str(exc)
        report["refusal"] = message
        print("Lint refused: " + message, file=sys.stderr)
        return 1
    finally:
        report["total_seconds"] = time.monotonic() - started
        if args.json_out:
            args.json_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt("lint interrupted; cleaning up owned commands")
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
