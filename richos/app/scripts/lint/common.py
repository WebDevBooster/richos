"""Shared lint inventory and subprocess handling. No third-party dependencies."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

APP = "richos/app/"


class Refusal(RuntimeError):
    pass


def run(args, *, cwd, timeout=180, env=None, input=None):
    """Own the process group, including Cargo children and cache-lock waiters."""
    started = time.monotonic()
    process = subprocess.Popen(
        [str(a) for a in args], cwd=cwd, env=env, text=True,
        stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = process.communicate(input, timeout=max(.001, timeout))
    except BaseException:
        # Only the process group we created. No name or path matching.
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=1)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise
    return subprocess.CompletedProcess(args, process.returncode, out, err), time.monotonic() - started


def checked(args, root, **kwargs):
    result, _ = run(args, cwd=root, **kwargs)
    if result.returncode:
        raise Refusal(f"{args[0]} failed ({result.returncode}): {result.stderr[-2000:]}")
    return result.stdout


def tracked(root):
    paths = checked(["git", "ls-files", "-z"], root).split("\0")
    return sorted(p for p in paths if p)


def inventory(root):
    """One tracked inventory; fixtures are accounted for but never linted as products."""
    rows = {}
    for path in tracked(root):
        if not path.startswith(APP):
            continue
        p = Path(path)
        if p.suffix not in {".sh", ".rs", ".js"}:
            continue
        if p.suffix == ".sh" and not path.startswith(APP + "scripts/"):
            continue
        if p.suffix == ".js" and not path.startswith(APP + "ui/"):
            continue
        role = "production"
        if "fixtures" in p.parts or "fixture" in p.parts:
            role = "fixture"
        elif p.name.endswith(".test.sh") or "tests" in p.parts or "test" in p.parts:
            role = "suite"
        rows[path] = {"language": {".sh": "shell", ".rs": "rust", ".js": "javascript"}[p.suffix], "role": role}
    for language in ("shell", "rust", "javascript"):
        if not any(r["language"] == language for r in rows.values()):
            raise Refusal(f"zero-file {language} inventory")
    return rows


def select(rows, language):
    return [p for p, r in rows.items() if r["language"] == language and r["role"] != "fixture"]


def shellcheck(root, rows):
    paths = select(rows, "shell")
    if not paths:
        raise Refusal("zero-file ShellCheck scan")
    command = ["shellcheck", "--format=json", "--rcfile=" + APP + ".shellcheckrc", *paths]
    result, _ = run(command, cwd=root)
    if result.returncode not in (0, 1):
        raise Refusal(f"ShellCheck failed: {result.stderr}")
    try:
        diagnostics = json.loads(result.stdout)
        if not isinstance(diagnostics, list):
            raise ValueError("expected diagnostic array")
        counts = {}
        for d in diagnostics:
            if not isinstance(d["code"], int) or d["file"] not in paths:
                raise ValueError("invalid ShellCheck diagnostic")
            rule = "SC" + str(d["code"])
            counts[rule] = counts.get(rule, 0) + 1
        if result.returncode == 1 and not diagnostics:
            raise ValueError("failed scan without diagnostics")
    except (ValueError, KeyError, TypeError) as exc:
        raise Refusal(f"malformed ShellCheck output: {exc}") from exc
    return counts, diagnostics
