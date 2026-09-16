#!/usr/bin/env python3
"""Prepare pinned macOS runtimes from public sources into a new staging directory.

Build-time tooling is allowed here. Installed execution must use only the delivered
runtimes and macOS system libraries. This does not install or activate an engine.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def build(destination):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("this runtime recipe supports macOS arm64 only")
    manifest = json.loads(Path(__file__).with_name("runtime-sources.json").read_text())
    destination = destination.absolute()
    if destination.exists():
        raise RuntimeError("destination must be absent; existing delivery is never overwritten")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="richos-public-runtime-build-") as temporary:
        scratch = Path(temporary)
        runtime = scratch / "runtime"
        runtime.mkdir()
        (runtime / "bin").mkdir()
        (runtime / "sources").mkdir()
        for name, source in manifest["sources"].items():
            archive = scratch / f"{name}.download"
            print(f"Fetching verified {name} {source['version']}", flush=True)
            with urllib.request.urlopen(source["url"], timeout=60) as incoming, archive.open("wb") as out:
                shutil.copyfileobj(incoming, out)
            if sha(archive) != source["sha256"]:
                raise RuntimeError(f"{name}: upstream digest mismatch")
            if name == "jq":
                shutil.copyfile(archive, runtime / "bin/jq")
                (runtime / "bin/jq").chmod(0o755)
                with urllib.request.urlopen(source["license_url"], timeout=60) as incoming:
                    license_text = incoming.read()
                if hashlib.sha256(license_text).hexdigest() != source["license_sha256"]:
                    raise RuntimeError("jq license digest mismatch")
                (runtime / "sources/JQ-COPYING").write_bytes(license_text)
                continue
            unpacked = scratch / f"{name}-unpacked"
            unpacked.mkdir()
            with tarfile.open(archive) as tar:
                tar.extractall(unpacked, filter="data")
            entries = list(unpacked.iterdir())
            if len(entries) != 1 or not entries[0].is_dir():
                raise RuntimeError(f"{name}: unexpected upstream archive root")
            if name in ("python", "node"):
                shutil.move(entries[0], runtime / name)
                continue
            if name == "iconv":
                iconv_source = entries[0]
                iconv_prefix = scratch / "iconv-static"
                clean_env = {**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CFLAGS": "-O2 -mmacosx-version-min=13.0 -ffile-prefix-map=" + str(iconv_source) + "=iconv-source"}
                with (scratch / "iconv-build.log").open("w") as log:
                    subprocess.run([str(iconv_source / "configure"), "--prefix=" + str(iconv_prefix),
                        "--disable-shared", "--enable-static", "--disable-nls"], cwd=iconv_source, env=clean_env, stdout=log, stderr=log, check=True)
                    subprocess.run(["make", "-j4"], cwd=iconv_source, env=clean_env, stdout=log, stderr=log, check=True)
                    subprocess.run(["make", "install"], cwd=iconv_source, env=clean_env, stdout=log, stderr=log, check=True)
                shutil.copyfile(archive, runtime / "sources/libiconv-1.18.tar.gz")
                shutil.copyfile(iconv_source / "COPYING.LIB", runtime / "sources/ICONV-COPYING.LIB")
                continue
            # Retain the exact source archive with the GPL implementation. No
            # developer checkout, system Git binary or private configuration is copied.
            shutil.copyfile(archive, runtime / "sources/git-2.55.0.tar.xz")
            git_source = entries[0]
            flags = ["prefix=/", "RUNTIME_PREFIX=YesPlease", "NO_GETTEXT=YesPlease",
                     "NO_TCLTK=YesPlease", "NO_PERL=YesPlease", "NO_OPENSSL=YesPlease",
                     "USE_HOMEBREW_LIBICONV=", "ICONVDIR=" + str(iconv_prefix),
                     "NO_PYTHON=YesPlease", "NO_RUST=YesPlease", "NO_INSTALL_HARDLINKS=YesPlease",
                     "CFLAGS=-O2 -mmacosx-version-min=13.0 -ffile-prefix-map=" + str(git_source) + "=git-source"]
            clean_env = {**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SDKROOT": subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()}
            try:
                with (scratch / "git-build.log").open("w") as log:
                    subprocess.run(["make", "-j4", *flags, "all"], cwd=git_source, env=clean_env, stdout=log, stderr=log, check=True)
                    subprocess.run(["make", *flags, "DESTDIR=" + str(runtime / "git"), "install"], cwd=git_source, env=clean_env, stdout=log, stderr=log, check=True)
            except subprocess.CalledProcessError:
                print((scratch / "git-build.log").read_text()[-10000:], flush=True)
                raise
            shutil.copyfile(git_source / "COPYING", runtime / "sources/GIT-COPYING")
        (runtime / "bin/node").symlink_to("../node/bin/node")
        # Relocation can invalidate upstream bytecode. Never rewrite signed/runtime
        # inventory files during normal execution, including direct CLI invocation.
        (runtime / "bin/python3").write_text('#!/bin/sh\nexec "$(dirname "$0")/../python/bin/python3" -B "$@"\n')
        (runtime / "bin/python3").chmod(0o755)
        # Git resolves its relative helper prefix from argv[0], so invoke the real
        # installed entry point rather than a symlink in the combined bin directory.
        (runtime / "bin/git").write_text('#!/bin/sh\nexec "$(dirname "$0")/../git/bin/git" "$@"\n')
        (runtime / "bin/git").chmod(0o755)
        # License files from binary upstream distributions are retained in full.
        (runtime / "sources/README.txt").write_text("Pinned upstream distributions are listed in runtime-sources.json. Git's exact corresponding source and COPYING are included. Python and Node license notices remain in their distributions. jq is distributed under the MIT license; see https://github.com/jqlang/jq/blob/jq-1.8.2/COPYING. macOS supplies bash and system libraries.\n")
        (runtime / "runtime-sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
        env = {**os.environ, "PATH": str(runtime / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
               "GIT_EXEC_PATH": str(runtime / "git/libexec/git-core"), "PYTHONDONTWRITEBYTECODE": "1"}
        versions = {}
        for name in ("python3", "node", "git", "jq"):
            versions[name] = subprocess.check_output([str(runtime / "bin" / name), "--version"], text=True, env=env).strip()
        subprocess.run([str(runtime / "bin/python3"), "-c", "import sqlite3, fcntl, ssl; print('Python dependency closure OK')"], env=env, check=True)
        # Reject any dynamic dependency on Homebrew or the developer's home.
        for path in runtime.rglob("*"):
            if path.is_file() and not path.is_symlink():
                with path.open("rb") as handle:
                    magic = handle.read(4)
                if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
                    linked = subprocess.check_output(["otool", "-L", str(path)], text=True)
                    dependencies = "\n".join(linked.splitlines()[1:])
                    if "/opt/homebrew/" in dependencies or "/usr/local/" in dependencies or "/Users/" in dependencies:
                        raise RuntimeError(f"nonportable linked dependency: {path.relative_to(runtime)}\n{linked}")
        files = {str(p.relative_to(runtime)): sha(p) for p in runtime.rglob("*") if p.is_file() and not p.is_symlink()}
        links = {str(p.relative_to(runtime)): os.readlink(p) for p in runtime.rglob("*") if p.is_symlink()}
        (runtime / "delivery.json").write_text(json.dumps({"schema": 1, "platform": manifest["platform"], "versions": versions,
            "files": files, "links": links}, indent=2) + "\n")
        shutil.move(runtime, destination)
    print(json.dumps({"runtime": str(destination), "versions": versions, "activated": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    build(parser.parse_args().destination)
