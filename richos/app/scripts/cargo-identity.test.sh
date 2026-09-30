#!/usr/bin/env bash
# run-tests: no-host-screen: builds and runs tiny Rust fixtures with no UI or network
# run-tests: inputs richos/app/scripts/cargo-identity.test.sh richos/app/scripts/bin/cargo richos/app/scripts/lib/cargo_identity.py richos/app/scripts/lib/cargo-cache-env.sh richos/app/scripts/testvm/reserve.py
# run-tests: covers richos/app/scripts/bin/cargo richos/app/scripts/lib/cargo_identity.py richos/app/scripts/lib/cargo-cache-env.sh richos/app/scripts/testvm/reserve.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/cargo-cache-env.sh"
python3 -B - "$HERE" <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import shutil

here = Path(sys.argv[1])
sys.path.insert(0, str(here / "lib"))
import cargo_identity
wrapper = here / "bin/cargo"
scratch = Path(tempfile.mkdtemp(prefix="cargo-identity.", dir=os.environ["TMPDIR"]))
try:
    missing = dict(HOME=str(scratch / "no-cargo-home"), PATH="/usr/bin:/bin")
    assert shutil.which("cargo", path=cargo_identity.enable_environment(missing)["PATH"]) is None
    missing_shell = subprocess.run(["/bin/bash", "-c", '. "$1"; command -v cargo', "fixture",
                                   str(here / "lib/cargo-cache-env.sh")], env=missing,
                                  capture_output=True, text=True, timeout=30)
    assert missing_shell.returncode != 0 and not missing_shell.stdout
    print("PASS a missing Rust toolchain stays missing for host capability checks")
    environment = dict(os.environ, CARGO_TARGET_DIR=str(scratch / "shared"))
    environment.pop("RICHOS_CARGO_CACHE_ROOT", None)
    dependency = scratch / "shared-dependency"
    (dependency / "src").mkdir(parents=True)
    (dependency / "Cargo.toml").write_text('[package]\nname="common_fixture"\nversion="0.1.0"\nedition="2021"\n')
    (dependency / "src/lib.rs").write_text('pub fn ready() {}\n')
    roots = []
    for label in ("alpha", "beta"):
        root = scratch / label
        (root / "src").mkdir(parents=True)
        (root / "Cargo.toml").write_text('[package]\nname="identity_fixture"\nversion="0.1.0"\nedition="2021"\n[dependencies]\ncommon_fixture={path="../shared-dependency"}\n')
        (root / "src/lib.rs").write_text(f'pub fn identity() -> &\'static str {{ common_fixture::ready(); "{label}" }}\n'
            f'#[test] fn own_source() {{ assert_eq!(identity(), "{label}"); }}\n')
        (root / "src/main.rs").write_text('fn main() { println!("{}", identity_fixture::identity()); }\n')
        # The other checkout's artifact will be newer than every source here.
        for path in root.rglob("*"):
            os.utime(path, (946684800, 946684800))
        roots.append(root)

    def cargo(root, *args):
        result = subprocess.run([str(wrapper), *args], cwd=root, env=environment,
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result

    executables = []
    for root in (roots[0], roots[1], roots[0]):
        label = root.name
        result = cargo(root, "test", "--offline", "--lib", "--message-format=json")
        artifacts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        tests = [a["executable"] for a in artifacts if a.get("reason") == "compiler-artifact" and a.get("executable")]
        assert len(tests) == 1, tests
        executables.append(tests[0])
        assert cargo(root, "run", "--offline", "--quiet").stdout.strip() == label
        assert cargo(root, "run", "--offline", "--quiet", "--", "--help", "--target-dir", "ignored").stdout.strip() == label
        print("PASS old-mtime checkout builds and runs its own library and binary:", label)
    assert executables[0] != executables[1], executables
    assert executables[0] == executables[2], executables

    # Cargo retains its own locking and parallelism. Different checkout outputs
    # cannot replace one another after the build lock is released.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(cargo, root, "run", "--offline", "--quiet") for root in roots]
        assert [f.result().stdout.strip() for f in futures] == ["alpha", "beta"]
    print("PASS concurrent checkouts execute distinct application binaries")

    for flag in (("--target-dir", str(scratch / "explicit")), ("--target-dir=" + str(scratch / "explicit"),)):
        targets = [json.loads(cargo(root, "metadata", "--offline", "--no-deps", "--format-version=1", *flag).stdout)["target_directory"] for root in roots]
        assert targets[0] != targets[1], targets
        assert all(str(scratch / "explicit") in p for p in targets)
    print("PASS inherited and explicit target roots retain separate workspace namespaces")

    # A relocated fixture in the same process needs a new namespace too.
    copied = scratch / "copied"
    shutil.copytree(roots[0], copied)
    assert json.loads(cargo(copied, "metadata", "--offline", "--no-deps", "--format-version=1").stdout)["target_directory"] != json.loads(cargo(roots[0], "metadata", "--offline", "--no-deps", "--format-version=1").stdout)["target_directory"]
    print("PASS copied fixture workspace gets its own artifacts")
    # A detached or excluded package is its own Cargo workspace, even when
    # nested below another manifest. It cannot inherit that parent's output.
    (roots[0] / "Cargo.toml").write_text((roots[0] / "Cargo.toml").read_text() + '\n[workspace]\nexclude=["excluded"]\n')
    excluded = roots[0] / "excluded"
    (excluded / "src").mkdir(parents=True)
    (excluded / "Cargo.toml").write_text('[package]\nname="excluded_fixture"\nversion="0.1.0"\n')
    (excluded / "src/lib.rs").write_text('pub fn ready() {}\n')
    targets = [json.loads(cargo(root, "metadata", "--offline", "--no-deps", "--format-version=1").stdout)["target_directory"] for root in (roots[0], excluded)]
    assert targets[0] != targets[1]
    unsafe = scratch / "unsafe.toml"
    unsafe.write_text('[build]\ntarget-dir="shared-again"\n')
    denied = subprocess.run([str(wrapper), "metadata", "--no-deps", "--config", str(unsafe)], cwd=roots[0], env=environment, capture_output=True, text=True, timeout=30)
    assert denied.returncode and 'cannot override private artifact output' in denied.stderr
    print("PASS excluded packages stay isolated and output config cannot bypass isolation")
    admitted = subprocess.run([sys.executable, "-B", str(here / "testvm/reserve.py"), "--wait", "300", "--",
                               "cargo", "run", "--offline", "--quiet", "--manifest-path",
                               str(roots[1] / "Cargo.toml")], cwd=here, env=environment,
                              capture_output=True, text=True, timeout=360)
    assert admitted.returncode == 0, admitted.stdout + admitted.stderr
    assert admitted.stdout.strip() == "beta", admitted.stdout
    print("PASS direct Cargo through reserve.py executes the requested checkout")
finally:
    shutil.rmtree(scratch)
PY
