"""Clippy collection and content-addressed Tauri check inputs."""
import hashlib
import json
import os
from pathlib import Path
import time
from common import APP, Refusal, checked, run, tracked

FAST = [
    ["cargo", "clippy", "--locked", "--all-targets", "--manifest-path", APP + "Cargo.toml"],
    ["cargo", "clippy", "--locked", "--all-targets", "--manifest-path", APP + "crates/richos-user-update/Cargo.toml"],
]
TAURI = [["cargo", "clippy", "--locked", "--all-targets", "--manifest-path", APP + "src-tauri/Cargo.toml"]]


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


def tauri_inputs(root, versions, deadline):
    """Discover local crate roots through Cargo; hash bytes, including dirty files.

    Also include the inputs explicitly declared by local build.rs files and the
    lint implementation. Dynamic build-script declarations are conservatively
    covered by the entire app and web source inventories.
    """
    pending = [root / APP / "src-tauri/Cargo.toml"]
    seen, directories = set(), set()
    while pending:
        manifest = pending.pop().resolve()
        if manifest in seen:
            continue
        seen.add(manifest)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Tauri input discovery deadline expired")
        data = json.loads(checked(["cargo", "metadata", "--locked", "--offline", "--no-deps",
                                   "--format-version=1", "--manifest-path", manifest], root, timeout=remaining))
        for package in data["packages"]:
            directory = Path(package["manifest_path"]).resolve().parent
            directory.relative_to(root)  # refuse external, untracked local dependencies
            directories.add(directory)
            for dep in package["dependencies"]:
                if dep.get("path"):
                    pending.append(Path(dep["path"]) / "Cargo.toml")
    files = set(tracked(root))
    files.update(p for p in checked(["git", "ls-files", "--others", "--exclude-standard", "-z"], root).split("\0") if p)
    # Conservative superset also covers embedded frontend and phone assets. No
    # second hand-maintained list of crate names can miss a new path dependency.
    selected = {p for p in files if p.startswith((APP, "richos/web/", "richos/engine/scripts/", "richos/engine/orchestration.config"))
                or any((root / p).is_relative_to(d) for d in directories)
                or Path(p).name in {"rust-toolchain", "rust-toolchain.toml", "clippy.toml", ".clippy.toml"}
                or ".cargo" in Path(p).parts}
    if not selected:
        raise Refusal("empty Tauri input set")
    digest = hashlib.sha256(json.dumps({"commands": TAURI, "versions": versions}, sort_keys=True).encode())
    for p in sorted(selected):
        digest.update(p.encode() + b"\0")
        digest.update((root / p).read_bytes())
        digest.update(b"\0")
    # User/ancestor Cargo configuration and compiler overrides also affect the
    # result; only their digest is kept, never their contents or operator paths.
    for parent in (root, *root.parents, Path.home()):
        for name in ("config", "config.toml"):
            config = parent / ".cargo" / name
            if config.is_file():
                digest.update(config.read_bytes())
    env = {k: v for k, v in os.environ.items() if k.startswith(("CARGO_", "RUST", "RICHOS_"))
           and k not in {"RICHOS_NIGHTLY_RUN_ID", "CARGO_TARGET_DIR", "RICHOS_NAMED_PERSONS_FILE", "RICHOS_RUNTIME_DIR"}}
    digest.update(json.dumps(env, sort_keys=True).encode())
    return digest.hexdigest()
