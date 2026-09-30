"""Keep mutable Cargo artifacts private to the physical workspace that built them."""
import hashlib
import fnmatch
import os
from pathlib import Path
import shutil
import sys
import tomllib


def cargo_executable(environment):
    paths = [p for p in environment.get("PATH", "").split(os.pathsep)
             if not (Path(p or ".").resolve().parent / "lib/cargo_identity.py").is_file()]
    cargo = shutil.which("cargo", path=os.pathsep.join(paths))
    fallback = Path(environment.get("HOME", str(Path.home()))) / ".cargo/bin/cargo"
    if not cargo and fallback.is_file():
        cargo = str(fallback)
    return cargo


def enable_environment(environment):
    env = dict(environment)
    cargo = cargo_executable(env)
    if not cargo:
        return env
    if not shutil.which("cargo", path=env.get("PATH")):
        env["PATH"] = str(Path(cargo).parent) + os.pathsep + env.get("PATH", "")
    wrapper = str(Path(__file__).resolve().parent.parent / "bin")
    env["PATH"] = wrapper + os.pathsep + env.get("PATH", "")
    if not env.get("RUSTC_WRAPPER") and not env.get("CARGO_BUILD_RUSTC_WRAPPER"):
        cache = shutil.which("sccache", path=env["PATH"])
        installed = Path("/Volumes/E1TB/tools/sccache/v0.18.0/sccache")
        if not cache and installed.is_file() and os.access(installed, os.X_OK):
            cache = str(installed)
        if cache:
            env["RUSTC_WRAPPER"] = cache
            env.setdefault("SCCACHE_DIR", "/Volumes/E1TB/caches/sccache/richos")
    return env


def workspace_root(directory):
    directory = Path(directory).resolve()
    if directory.is_file():
        directory = directory.parent
    manifest = next((p / "Cargo.toml" for p in (directory, *directory.parents)
                     if (p / "Cargo.toml").is_file()), None)
    if manifest is None:
        raise ValueError(f"no Cargo.toml above {directory}")
    data = tomllib.loads(manifest.read_text())
    if "workspace" in data:
        return manifest.parent
    explicit = data.get("package", {}).get("workspace")
    if explicit:
        return (manifest.parent / explicit).resolve()
    for parent in manifest.parent.parents:
        candidate = parent / "Cargo.toml"
        if candidate.is_file():
            workspace = tomllib.loads(candidate.read_text()).get("workspace")
            if workspace is not None:
                relative = manifest.parent.relative_to(parent).as_posix()
                if any(fnmatch.fnmatchcase(relative, pattern) for pattern in workspace.get("exclude", [])):
                    return manifest.parent
                return parent
    return manifest.parent


def target_dir(directory, environment, base=None, cwd=None):
    root = workspace_root(directory)
    configured = base or environment.get("RICHOS_CARGO_CACHE_ROOT") or environment.get("CARGO_TARGET_DIR")
    if not configured:
        configured = "/Volumes/E1TB/caches/cargo-target"
    cache = Path(configured).expanduser()
    if not cache.is_absolute():
        cache = Path(cwd or Path.cwd()) / cache
    cache = cache.resolve()
    # An absent external volume is a refusal, never an internal-disk fallback.
    if str(cache).startswith("/Volumes/"):
        volume = Path(*cache.parts[:3])
        if not os.path.ismount(volume):
            raise ValueError(f"Cargo cache volume is not mounted: {volume}")
    key = hashlib.sha256(os.fsencode(root)).hexdigest()[:24]
    return cache, cache / "workspaces" / key


def command(arguments, environment, cwd):
    environment = enable_environment(environment)
    args, base, directory = [], None, Path(cwd)
    i = 0
    while i < len(arguments):
        arg = arguments[i]
        if arg == "--":
            args.extend(arguments[i:])
            break
        if arg == "--config" and i + 1 < len(arguments):
            config = Path(cwd) / arguments[i + 1]
        elif arg.startswith("--config="):
            config = Path(cwd) / arg.split("=", 1)[1]
        else:
            config = None
        if config is not None and config.is_file():
            build = tomllib.loads(config.read_text()).get("build", {})
            if "target-dir" in build or "build-dir" in build:
                raise ValueError("Cargo config cannot override private artifact output; use --target-dir for a cache root")
        if arg in ("--manifest-path", "--target-dir"):
            if i + 1 == len(arguments):
                raise ValueError(f"{arg} needs a path")
            value = arguments[i + 1]
            if arg == "--target-dir":
                base = value
            else:
                directory = Path(cwd) / value
                args.extend((arg, value))
            i += 2
            continue
        if arg.startswith("--manifest-path="):
            directory = Path(cwd) / arg.split("=", 1)[1]
        elif arg.startswith("--target-dir="):
            base = arg.split("=", 1)[1]
            i += 1
            continue
        if "build.target-dir" in arg or "build.build-dir" in arg:
            raise ValueError("use --target-dir to select a cache root; shared Cargo output config is unsafe")
        args.append(arg)
        i += 1
    # Commands that neither build nor inspect a workspace keep Cargo's normal behavior.
    cargo_args = args[:args.index("--")] if "--" in args else args
    if not args or any(a in ("--version", "-V", "--help", "-h") for a in cargo_args):
        return args, dict(environment)
    try:
        cache, private = target_dir(directory, environment, base, cwd)
    except ValueError:
        if args[0] in ("install", "uninstall", "search", "login", "logout", "new", "init") or args[:2] == ["tauri", "signer"]:
            return args, dict(environment)
        raise
    env = dict(environment, RICHOS_CARGO_CACHE_ROOT=str(cache),
               CARGO_TARGET_DIR=str(private), CARGO_BUILD_TARGET_DIR=str(private),
               CARGO_BUILD_BUILD_DIR=str(private))
    return args, env


def main():
    if sys.argv[1:2] == ["--richos-target-dir"]:
        print(target_dir(sys.argv[2], os.environ, cwd=sys.argv[2])[1])
        return
    # PATH may contain nested wrappers. Resolve the actual Cargo, preserving fake
    # Cargo tools supplied by a fixture and the caller's chosen Rust toolchain.
    cargo = cargo_executable(os.environ)
    if not cargo:
        raise ValueError("cargo is not on PATH")
    args, env = command(sys.argv[1:], os.environ, Path.cwd())
    os.execvpe(cargo, [cargo, *args], env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        sys.exit(f"RichOS Cargo: {exc}")
