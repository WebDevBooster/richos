#!/usr/bin/env python3
"""Stage a reviewable broker package or install its fixed files as root.

Installation writes protected pending files outside launchd discovery directories.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

FILES = ("managed-workspace-broker.py", "managed-workspace-manager.py",
         "managed-workspace-volume.py", "managed-workspace-client.py", "managed-workspace-acceptance.py",
         "managed-workspace-failed-creation.py", "legacy-workspace-admin.py",
         "legacy-workspace-gate.py", "legacy-workspace-inspection.py", "legacy-workspace-maintenance.py",
         "terminal-branch-cleanup.py", "worktree-ledger.py", "worktree-transactions.py",
         "terminal-branch-shadow.py", "legacy-workspace-mutation.py", "legacy-workspace-capture.py",
         "terminal-recovery-shadow.py", "legacy-workspace-retirement.py", "legacy-workspace-job.py", "legacy-workspace-operator.py", "legacy-workspace-service.py", "legacy-workspace-acceptance.py", "durable-filesystem-identity.py",
         "workspace-recovery-metadata.py", "legacy-workspace-expiry.py")
INSTALL_ROOT = Path("/Library/Application Support/RichOS/workspace-broker")
POLICY_PATH = INSTALL_ROOT / "policy.json"
CLIENT_CONFIG_PATH = Path("/Library/Application Support/RichOS/ManagedWorkspaces/client.pending.json")
SOCKET_ROOT = Path("/var/db/richos-workspace-sockets")
LABEL = "com.richos.managed-workspace-broker"
PLIST_PATH = INSTALL_ROOT / (LABEL + ".plist.pending")
ACTIVE_PLIST_PATH = Path("/Library/LaunchDaemons") / (LABEL + ".plist")
INTERPRETER = "/Library/Developer/CommandLineTools/usr/bin/python3"
PRIVATE_ROOT = Path("/var/db/richos-workspaces")
ACTIVE_ROOT = Path("/var/db/richos-workspace-mounts")


def payloads(package):
    manifest = json.loads((package / "manifest.json").read_text())
    if not isinstance(manifest, dict) or set(manifest) != set(FILES):
        raise ValueError("package manifest must name exactly the broker runtime files")
    content = {}
    for name in FILES:
        path = package / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("package runtime must be regular files")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != manifest[name]:
            raise ValueError("package hash mismatch: " + name)
        content[name] = data
    return content, manifest


def launchd_plist(release):
    return {"Label": LABEL, "ProgramArguments": [INTERPRETER, "-I", "-S", "-B",
            str(release / "managed-workspace-broker.py"), "--policy", str(POLICY_PATH),
            "--socket", str(SOCKET_ROOT / "broker.sock")],
            "UserName": "root", "GroupName": "wheel", "RunAtLoad": True,
            "KeepAlive": True, "WorkingDirectory": "/", "Umask": 0o077,
            "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"},
            "StandardOutPath": str(INSTALL_ROOT / "broker.stdout.log"),
            "StandardErrorPath": str(INSTALL_ROOT / "broker.stderr.log")}


def stage(output, source=None):
    output = Path(output)
    source = Path(source) if source else Path(__file__).resolve().parent / "lib"
    output.mkdir(parents=False, exist_ok=False)
    manifest = {}
    for name in FILES:
        data = (source / name).read_bytes()
        (output / name).write_bytes(data)
        manifest[name] = hashlib.sha256(data).hexdigest()
    (output / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    shutil.copyfile(__file__, output / "install.py")
    # The actual release path is content-addressed at install time.
    release = INSTALL_ROOT / "releases" / hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    (output / (LABEL + ".plist")).write_bytes(plistlib.dumps(launchd_plist(release)))
    (output / "policy.example.json").write_text(json.dumps({"version": 1,
        "private_root": "/var/db/richos-workspaces", "active_root": "/var/db/richos-workspace-mounts",
        "owners": {"501": {"gid": 20}}, "repositories": {"approved-repo": {
            "path": "/absolute/path/to/approved/repository", "owners": [501],
            "retention_days": 14, "size": "32g"}}}, indent=2) + "\n")
    return output


def reject_unsafe_acl(path):
    """macOS mode bits do not bound ACL grants. Accept only no ACL or deny-only ACLs."""
    if sys.platform != "darwin":
        return
    try:
        result = subprocess.run(["/bin/ls", "-lde", str(path)], capture_output=True,
                                text=True, timeout=5, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
        raise ValueError("ACL metadata unavailable: " + str(path)) from exc
    lines = result.stdout.splitlines()
    if result.returncode != 0 or not lines:
        raise ValueError("ACL metadata unavailable: " + str(path))
    for line in lines[1:]:
        if not re.fullmatch(r"\s*\d+: .+ deny [A-Za-z_,]+", line):
            raise ValueError("ACL grants or unreadable ACL on protected path: " + str(path))


def protected(path):
    path = Path(path).resolve(strict=True)
    for entry in (path, *path.parents):
        info = entry.lstat()
        reject_unsafe_acl(entry)
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("not root protected: " + str(entry))
    return path


def mkdir_protected(path, mode):
    path = Path(path).resolve()
    ancestor = path
    while not ancestor.exists():
        ancestor = ancestor.parent
    protected(ancestor)
    missing = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        cursor = cursor.parent
    for directory in reversed(missing):
        desired = mode if directory == path else 0o755
        directory.mkdir(mode=desired)
        os.chmod(directory, desired)  # Only directories just created by this installer.
    protected(path)
    if stat.S_IMODE(path.stat().st_mode) != mode:
        raise ValueError("existing dedicated directory has unexpected permissions: " + str(path))
    return path


def atomic_file(path, data, mode):
    fd, name = tempfile.mkstemp(prefix=".install-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def install(package, policy_source):
    if os.geteuid() != 0 or not sys.flags.isolated or not sys.flags.no_site:
        raise ValueError("installation requires root with Python -I -S")
    if sys.platform != "darwin":
        raise ValueError("launchd broker installation is macOS-only")
    protected(INTERPRETER)
    if Path(sys.executable).resolve() != Path(INTERPRETER).resolve():
        raise ValueError("installation requires the fixed root-owned Command Line Tools interpreter")
    for entry in sys.path:
        if not entry or not Path(entry).is_absolute():
            raise ValueError("relative installer interpreter import path")
        ancestor = Path(entry)
        while not ancestor.exists():
            ancestor = ancestor.parent
        protected(ancestor)
    # A pending install must not mutate policy beneath a published or running
    # service. Activation and upgrades need their own explicit workflow.
    if any(os.path.lexists(path) for path in (ACTIVE_PLIST_PATH,
            CLIENT_CONFIG_PATH.with_name('client.json'), SOCKET_ROOT / 'broker.sock')):
        raise ValueError('published service artifacts exist; pending installation requires explicit migration')
    content, manifest = payloads(Path(package))
    # Execute exactly the reviewed, hashed broker bytes to share policy
    # validation. No manager or provider is imported during installation.
    namespace = {"__name__": "installation_policy_validation"}
    exec(compile(content["managed-workspace-broker.py"], "reviewed-broker-policy", "exec"), namespace)
    policy = namespace["validate_policy"](json.loads(Path(policy_source).read_text()))
    for key, dedicated in (("private_root", PRIVATE_ROOT), ("active_root", ACTIVE_ROOT)):
        policy[key] = str(Path(policy[key]).resolve())
        if policy[key] != str(dedicated.resolve()):
            raise ValueError("managed storage must use the dedicated " + key + " namespace")
    if policy["private_root"] == policy["active_root"] or Path(policy["private_root"]) in Path(policy["active_root"]).parents:
        raise ValueError("active mounts must be outside private storage")
    for entry in policy["repositories"].values():
        resolved = Path(entry["path"]).resolve(strict=True)
        if not resolved.is_dir():
            raise ValueError("approved source repository is not a directory")
        entry["path"] = str(resolved)
    root = mkdir_protected(INSTALL_ROOT, 0o755)
    releases = mkdir_protected(root / "releases", 0o755)
    digest = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    release = releases / digest
    if not release.exists():
        staging = Path(tempfile.mkdtemp(prefix=".release-", dir=releases))
        try:
            for name, data in content.items():
                atomic_file(staging / name, data, 0o644)
            atomic_file(staging / "manifest.json", (json.dumps(manifest, sort_keys=True) + "\n").encode(), 0o644)
            os.chmod(staging, 0o755)
            os.rename(staging, release)
            fd = os.open(releases, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    else:
        protected(release)
        for name in (*FILES, "manifest.json"):
            protected(release / name)
        installed, installed_manifest = payloads(release)
        if installed != content or installed_manifest != manifest:
            raise ValueError("existing release differs from reviewed package")
    mkdir_protected(policy["private_root"], 0o700)
    mkdir_protected(policy["active_root"], 0o711)
    mkdir_protected(SOCKET_ROOT, 0o711)
    atomic_file(POLICY_PATH, (json.dumps(policy, sort_keys=True, indent=2) + "\n").encode(), 0o600)
    mkdir_protected(CLIENT_CONFIG_PATH.parent, 0o755)
    public = {"version": 1, "socket": str(SOCKET_ROOT / "broker.sock"),
              "active_root": policy["active_root"],
              "repositories": {alias: entry["path"] for alias, entry in policy["repositories"].items()}}
    atomic_file(CLIENT_CONFIG_PATH, (json.dumps(public, sort_keys=True, indent=2) + "\n").encode(), 0o644)
    protected(PLIST_PATH.parent)
    atomic_file(PLIST_PATH, plistlib.dumps(launchd_plist(release)), 0o644)
    return {"release": str(release), "policy": str(POLICY_PATH), "plist": str(PLIST_PATH),
            "client_config": str(CLIENT_CONFIG_PATH), "activated": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--stage", metavar="OUTPUT_DIRECTORY")
    mode.add_argument("--install", action="store_true")
    parser.add_argument("--policy", help="reviewed explicit repository/owner policy, required for installation")
    args = parser.parse_args()
    if args.stage:
        print(stage(args.stage))
    else:
        if not args.policy:
            parser.error("--install requires --policy")
        print(json.dumps(install(Path(__file__).resolve().parent, args.policy), sort_keys=True))


if __name__ == "__main__":
    main()
