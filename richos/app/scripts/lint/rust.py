"""Clippy collection and lint rule configuration."""
import json
from pathlib import Path
import time
import tomllib
from common import APP, Refusal, run, tracked

FAST = [
    ["cargo", "clippy", "--locked", "--all-targets", "--manifest-path", APP + "Cargo.toml"],
    ["cargo", "clippy", "--locked", "--all-targets", "--manifest-path", APP + "crates/richos-user-update/Cargo.toml"],
]
TAURI = [["cargo", "clippy", "--locked", "--all-targets", "--manifest-path", APP + "src-tauri/Cargo.toml"]]


def lint_rules(root):
    """Record actual lint IDs, levels and package inheritance, not just counts."""
    rules = {"toolchain-default-diagnostics": "blocking-count-ceiling"}
    for path in tracked(root):
        if not path.startswith(APP) or Path(path).name != "Cargo.toml":
            continue
        data = tomllib.loads((root / path).read_text())
        tables = {"package": data.get("lints", {}), "workspace": data.get("workspace", {}).get("lints", {})}
        for scope, table in tables.items():
            if scope == "package" and "package" in data:
                rules[path + ":inherits-workspace"] = str(table.get("workspace", False)).lower()
            for group in ("rust", "clippy"):
                for name, setting in table.get(group, {}).items():
                    rules[f"{path}:{scope}:{group}::{name}"] = json.dumps(setting, sort_keys=True)
    return rules


def collect(root, commands, deadline=None):
    counts, diagnostics = {}, []
    for command in commands:
        remaining = deadline - time.monotonic() if deadline else 900
        if remaining <= 0:
            raise TimeoutError("Tauri Clippy deadline expired")
        result, _ = run(command + ["--message-format=json"], cwd=root, timeout=remaining)
        if result.returncode:
            raise Refusal(f"Clippy compilation failed: {result.stderr[-3000:]}")
        finished, artifacts = False, 0
        try:
            for line in result.stdout.splitlines():
                item = json.loads(line)
                reason = item["reason"]
                if reason == "build-finished":
                    finished = item["success"] is True
                elif reason == "compiler-artifact":
                    artifacts += 1
                elif reason == "compiler-message":
                    message = item["message"]
                    if message["level"] not in {"warning", "error"}:
                        continue
                    rule = (message.get("code") or {}).get("code", "compiler-warning")
                    counts[rule] = counts.get(rule, 0) + 1
                    diagnostics.append({"rule": rule, "message": message["message"]})
            if not finished or not artifacts:
                raise ValueError("no successful build-finished event or no compiled targets")
        except (ValueError, KeyError, TypeError) as exc:
            raise Refusal(f"malformed or empty Clippy output: {exc}") from exc
    return counts, diagnostics
