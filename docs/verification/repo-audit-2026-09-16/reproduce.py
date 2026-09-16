#!/usr/bin/env python3
"""Reproduce the five September 16 audit findings using disposable fixtures.

Run from any directory: python3 /path/to/this/file.py
Requires Node, Rust and Swift. Does not install hooks, record audio or change
the real browser configuration. Results describe current behavior rather
than asserting that the defects must remain present.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[3]
ENGINE = REPO / "richos/engine"
TOOLS = REPO / "richos/tools"


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=180, **kwargs)


def rust_probe(root):
    crate = root / "rust-probe"
    (crate / "src").mkdir(parents=True)
    dependency = json.dumps(str(REPO / "richos/app/crates/richos-core"))
    (crate / "Cargo.toml").write_text(
        '[package]\nname="richos-audit-probe"\nversion="0.0.0"\nedition="2021"\n'
        f'[dependencies]\nrichos-core={{path={dependency}}}\n'
    )
    (crate / "src/main.rs").write_text(r'''
use richos_core::provision::{product_checkout_containing, provision, ProvisionRequest};
use std::{fs, os::unix::fs::symlink, path::PathBuf};
fn main() {
    let root = PathBuf::from(std::env::args().nth(1).unwrap());
    let repo = root.join("product");
    fs::create_dir_all(repo.join("richos/app/crates/richos-core")).unwrap();
    fs::create_dir_all(repo.join("docs")).unwrap();
    fs::write(repo.join("richos/app/crates/richos-core/Cargo.toml"), "").unwrap();
    fs::write(repo.join(".git"), "gitdir: synthetic").unwrap();
    symlink(repo.join("docs"), root.join("external-link")).unwrap();
    let target = root.join("external-link/corpus");
    println!("physical path refused: {}", product_checkout_containing(&repo.join("docs/corpus")).is_some());
    println!("symlink path refused: {}", product_checkout_containing(&target).is_some());
    let result = provision(&ProvisionRequest {
        target, home: None, companies: vec![], compiler_source: Some(root.join("no-compiler")),
    });
    println!("provision accepted: {}", result.is_ok());
    println!("private directory created inside product: {}", repo.join("docs/corpus/ceo/pages/private").exists());
}
''')
    cargo = shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo")
    result = run([cargo, "run", "--offline", "--quiet", "--manifest-path",
                  str(crate / "Cargo.toml"), "--", str(root / "rust-fixture")])
    return {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def swift_probe(root):
    source = root / "main.swift"
    source.write_text(r'''
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let repo = root.appendingPathComponent("product")
try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
let link = root.appendingPathComponent("external-link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.appendingPathComponent("docs"))
let target = link.appendingPathComponent("recordings").path
print("physical path refused: \(DropZone.isInside(repo.appendingPathComponent("docs/recordings").path, repo.path))")
print("symlink path refused: \(DropZone.isInside(target, repo.path))")
do {
    let result = try DropZone.resolve(explicit: target, env: [:], home: root.path, productRepo: repo.path)
    print("recorder accepted zone: \(result.path)")
} catch { print("recorder refused: \(error)") }
''')
    binary = root / "swift-probe"
    build = run(["swiftc", str(TOOLS / "richos-service/companion-macos/Sources/RichOSCompanionCore/DropZone.swift"),
                 str(source), "-o", str(binary)])
    if build.returncode:
        return {"build_exit": build.returncode, "stderr": build.stderr}
    result = run([str(binary), str(root / "swift-fixture")])
    return {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def cli_probe(root):
    repo = root / "cli-product"
    service = repo / "richos/tools/richos-service"
    extension = repo / "richos/tools/richos-extension"
    for name in ("lib", "bin"):
        shutil.copytree(TOOLS / "richos-service" / name, service / name)
    shutil.copy2(TOOLS / "richos-service/package.json", service / "package.json")
    for name in ("sync", "core"):
        shutil.copytree(TOOLS / "richos-extension" / name, extension / name)
    shutil.copy2(TOOLS / "richos-extension/package.json", extension / "package.json")
    session = repo / "docs/session"
    session.mkdir(parents=True)
    record = session / "session.json"
    record.write_text(json.dumps({"schemaVersion": 2, "sessionId": "audit-session",
                                 "status": "closed", "startedAt": 1, "endedAt": 2,
                                 "audio": {"bytes": 0, "parts": 0}}))
    env = dict(os.environ, HOME=str(root / "home"), LORO_CORPUS=str(root / "corpus"),
               RICHOS_DROP_ZONE=str(root / "outside-zone"))
    command = ["node", str(service / "bin/richos-service.js"), "run", str(session), "--model", "small.en"]
    control = run(command + ["--zone", str(session)], env=env)
    result = run(command, env=env)
    return {
        "same_destination_as_zone_refused": "privacy invariant" in control.stderr,
        "explicit_session_exit": result.returncode,
        "explicit_session_privacy_refusal": "privacy invariant" in result.stderr,
        "pipeline_wrote_inside_product": "pipeline" in json.loads(record.read_text()),
    }


def installer_probe(root):
    old, new, home = root / "old-host", root / "new-host", root / "browser-home"
    (home / "Library/Application Support/Google/Chrome").mkdir(parents=True)
    shutil.copytree(TOOLS / "richos-service/host", old)
    (old / "native-host.js").write_text('console.log("AUDIT_NATIVE_HOST_READY");\n')
    env = dict(os.environ, HOME=str(home))
    exits = []
    for directory in (old, new):
        if directory == new:
            old.rename(new)
        result = run(["sh", str(directory / "install-host.sh"), "abcdefghijklmnopabcdefghijklmnop"], env=env)
        exits.append(result.returncode)
    launcher = (new / "richos-host-launcher.sh").read_text()
    result = run([str(new / "richos-host-launcher.sh")], env=env, input="")
    return {
        "install_exit_codes": exits,
        "launcher_kept_old_host_path": str(old / "native-host.js") in launcher,
        "launch_exit": result.returncode,
        "host_ready": "AUDIT_NATIVE_HOST_READY" in result.stdout,
        "missing_old_host_module": "Cannot find module" in result.stderr
                                   and str(old / "native-host.js") in result.stderr,
    }


def dispatcher_probe(root):
    engine = root / "engine"
    hooks = engine / "scripts/hooks"
    hooks.mkdir(parents=True)
    shutil.copytree(ENGINE / "scripts/lib", engine / "scripts/lib",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ENGINE / "scripts/hooks/dispatch-pretooluse.sh", hooks / "dispatch-pretooluse.sh")
    (hooks / "dispatch-pretooluse.manifest").write_text("Bash|missing-rule.sh\nBash|broken-rule.sh\n")
    (hooks / "broken-rule.sh").write_text("exit 1\n")
    (engine / "VERSION").write_text("audit\n")
    env = dict(os.environ, HOME=str(root / "home"), CLAUDE_CONFIG_DIR=str(root / "config"),
               CLAUDE_PLUGIN_ROOT=str(engine))
    payload = json.dumps({"cwd": str(root), "tool_name": "Bash", "tool_input": {"command": "true"}})
    result = run(["bash", str(hooks / "dispatch-pretooluse.sh"), "Bash"], input=payload, env=env, cwd=root)
    return {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="richos-audit-") as temp:
        root = Path(temp)
        results = {}
        for name, probe in (("rust_provision", rust_probe), ("swift_recorder", swift_probe),
                            ("service_cli", cli_probe), ("host_installer", installer_probe),
                            ("hook_dispatcher", dispatcher_probe)):
            results[name] = probe(root)
        print(json.dumps(results, indent=2).replace(str(root), "<sandbox>"))
