"""Durable plans and provenance for retries through the existing proof runner.

Engine green remains a ci-receipts verdict. This module selects an immutable
receipt for each obligation; it never edits one or converts a wrapper exit into
an engine verdict. Input contracts are explicit and unqualified work stays fresh.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import tempfile


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def path_identity(path, ancestors=()):
    """Includes inventories, absence, executable modes and untracked fixture data."""
    path = Path(path)
    location = str(path.absolute())
    if location in ancestors:
        raise ValueError(f"cyclic input link: {path}")
    ancestors = (*ancestors, location)
    if path.is_symlink():
        target = os.readlink(path)
        return {"link": target, "target": path_identity(Path(os.path.normpath(path.parent / target)), ancestors)}
    if not path.exists():
        return {"absent": True}
    if path.is_file():
        return {"sha256": file_digest(path), "mode": path.stat().st_mode & 0o777}
    if path.is_dir():
        return {entry.name: path_identity(entry, ancestors) for entry in sorted(path.iterdir())}
    raise ValueError(f"unsupported input type: {path}")


def recipe_identity(root, recipe, environment):
    """Validate the finite declaration, then fingerprint every declared input.

    An absent contract is deliberately not a reusable identity. The declaration
    and its qualification are versioned source inputs, so changing either cannot
    inherit a previous result. Secret environment values are hashed, never logged.
    """
    if recipe.get("fresh"):
        return {"fresh": recipe["fresh"]}
    required = {"paths", "tools", "environment", "external", "qualification"}
    if set(recipe) != required or not recipe["qualification"]:
        raise ValueError("incomplete verification input contract")
    root = Path(root).resolve()
    if not (root / recipe["qualification"]).is_file():
        raise ValueError("input qualification is missing: " + recipe["qualification"])
    paths = {}
    for rel in [*recipe["paths"], recipe["qualification"]]:
        path = root / rel
        if Path(rel).is_absolute() or ".." in Path(rel).parts:
            raise ValueError(f"input must be repository-relative: {rel}")
        paths[rel] = digest(path_identity(path))
    tools = {}
    for name in recipe["tools"]:
        resolved = shutil.which(name, path=environment.get("PATH"))
        tools[name] = ({"path": resolved, "input": path_identity(resolved)}
                       if resolved else {"absent": True})
    external = {}
    for name in recipe["external"]:
        value = environment.get(name)
        external[name] = digest(path_identity(value)) if value else {"unset": True}
    values = {name: digest(environment[name]) if name in environment else None
              for name in recipe["environment"]}
    return {"contract": digest(recipe), "paths": paths, "tools": tools,
            "environment": values, "external": external,
            "platform": [platform.system(), platform.release(), platform.machine(), platform.mac_ver()[0]]}


def contract_for(root, label):
    path = Path(root) / "richos/app/scripts/proof-inputs.json"
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {"fresh": "no committed input contract"}
    if data.get("schema") != 1 or not isinstance(data.get("checks"), dict):
        raise ValueError("invalid proof-inputs.json")
    return data["checks"].get(label, {"fresh": "input qualification not yet declared for " + label})


def encode_item(item, root, logdir):
    def relative(arg):
        prefix = str(Path(logdir).resolve()) + os.sep
        return "$RUN/" + arg[len(prefix):] if arg.startswith(prefix) else arg
    return {"check": item.label, "cwd": os.path.relpath(item.cwd, root),
            "argv": [relative(arg) for arg in item.argv], "lane": item.lane,
            "weight": item.weight, "after": sorted(item.after), "requires": sorted(item.requires)}


def decode_item(row, factory, root, logdir):
    argv = [str(Path(logdir) / arg[5:]) if arg.startswith("$RUN/") else arg for arg in row["argv"]]
    return factory(row["check"], str(Path(root) / row["cwd"]), argv,
                   row["lane"], row["weight"], row["after"], row["requires"])


def receipt_path(item):
    if item.engine_unit:
        return Path(item.argv[item.argv.index("--receipt") + 1])
    return None


def completed_receipt(item, sha, allow_known_red=False):
    path = receipt_path(item)
    if path is None:
        return None
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    unit = item.argv[item.argv.index("--only-units") + 1]
    if (len(rows) != 1 or rows[0].get("unit") != unit or rows[0].get("sha") != sha
            or rows[0].get("schema") != 2 or rows[0].get("execution_status") != "completed"
            or not (rows[0].get("verdict") == "PASS" and rows[0].get("rc") == rows[0].get("expected_rc")
                    or allow_known_red and rows[0].get("verdict") == "KNOWN-RED")):
        raise ValueError("receipt is not a completed PASS for " + unit)
    return {"path": str(path), "sha256": file_digest(path)}


class Record:
    def __init__(self, root, logdir, items, source, identities, previous=None,
                 current_source=None, current_identity=None):
        self.root, self.logdir = str(root), Path(logdir)
        self.source, self.identities = source, identities
        self.previous = previous
        self.current_source = current_source or (lambda: self.source)
        self.current_identity = current_identity or (lambda item: self.identities[item.label])
        self.source_invalidated = False
        self.lease = Lease(logdir)
        self.plan = {"schema": 1, "root": self.root, "source": source,
                     "items": [encode_item(item, root, logdir) for item in items],
                     "identities": identities, "previous": str(previous) if previous else None}
        atomic(self.logdir / "plan.json", self.plan)
        self.results = {}
        for item in items:
            item.evidence = self
        self.checkpoint(items)

    def checkpoint(self, items):
        for item in items:
            if item.label not in self.identities:
                continue  # Synthetic run findings never become reusable obligations.
            old = self.results.get(item.label, {})
            if old.get("state") == item.state and old.get("exit") == item.rc:
                continue
            self.save(item, self.current_source())

    def save(self, item, source):
        """Called before launch and after completion, independently of the summary."""
        if source != self.source:
            self.source_invalidated = True
        result = {"state": item.state, "exit": item.rc, "source": source,
                  "input": self.identities[item.label], "log": item.log,
                  "receipt": None, "seconds": item.seconds, "reused_from": getattr(item, "reused_from", None)}
        if item.state == "passed":
            if source != self.source:
                result["invalid"] = "source changed during execution"
            else:
                try:
                    if self.current_identity(item) != self.identities[item.label]:
                        raise ValueError("execution inputs changed during the check")
                    result["receipt"] = completed_receipt(item, source["commit"],
                        allow_known_red=not getattr(item, "reused_from", None))
                    result["log_sha256"] = file_digest(item.log)
                except (OSError, ValueError, KeyError, TypeError) as exc:
                    result["invalid"] = "evidence unavailable: " + str(exc)
        if result.get("invalid"):
            item.state, item.rc = "invalid", 125
            item.notes.append(result["invalid"])
            result.update(state=item.state, exit=item.rc)
        if getattr(item, "provenance", None):
            result["provenance"] = item.provenance
        self.results[item.label] = result
        atomic(self.logdir / "outcomes.json", self.results)

    def close(self):
        self.lease.close()


def read_plan(path):
    plan = json.loads((Path(path) / "plan.json").read_text())
    if plan.get("schema") != 1:
        raise ValueError("unsupported or missing saved plan schema")
    labels = [row["check"] for row in plan["items"]]
    if len(labels) != len(set(labels)):
        raise ValueError("saved plan contains duplicate obligations")
    return plan


def reuse(previous, items, record):
    """Select exact applicable passes; leave failed evidence in its original run."""
    previous = Path(previous)
    plan = read_plan(previous)
    if plan["root"] != record.root:
        raise ValueError("exact resume requires the saved checkout")
    if plan["items"] != record.plan["items"]:
        raise ValueError("resume cannot change the frozen plan or execution recipe")
    try:
        outcomes = json.loads((previous / "outcomes.json").read_text())
    except FileNotFoundError:
        outcomes = {}
    for item in items:
        old = outcomes.get(item.label, {})
        item.retry_first = old.get("state") != "passed"
        identity = record.identities[item.label]
        reason = None
        if item.label == "engine receipts":
            reason = "coverage verifier runs over the reconciled receipt set"
        elif identity.get("fresh"):
            reason = identity["fresh"]
        elif old.get("state") != "passed" or old.get("exit") != 0 or old.get("invalid"):
            reason = "no validated passing execution"
        elif old.get("source") != record.source or plan["source"] != record.source:
            reason = "source identity changed"
        elif old.get("input") != identity:
            reason = "declared execution inputs changed"
        else:
            try:
                if file_digest(old["log"]) != old["log_sha256"]:
                    raise ValueError("result log changed")
                target = receipt_path(item)
                if target:
                    original = old["receipt"]
                    if file_digest(original["path"]) != original["sha256"]:
                        raise ValueError("receipt changed")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(original["path"], target)
                    completed_receipt(item, record.source["commit"])
                copied = record.logdir / "reused" / (digest(item.label) + ".log")
                copied.parent.mkdir(exist_ok=True)
                shutil.copyfile(old["log"], copied)
                item.state, item.rc, item.log = "passed", 0, str(copied)
                item.provenance = {"run": str(previous), "source": old["source"],
                                   "receipt": old.get("receipt"), "log_sha256": old["log_sha256"],
                                   "input": old["input"], "earlier": old.get("provenance")}
                item.reused_from = str(previous)
                item.notes.append("validated evidence reused from " + str(previous))
                record.save(item, record.source)
            except (OSError, ValueError, KeyError, TypeError) as exc:
                reason = "saved evidence failed validation: " + str(exc)
                target = receipt_path(item)
                if target and target.exists():
                    target.unlink()
        if reason:
            item.notes.append("execute: " + reason)


class Lease:
    """A saved plan cannot have two simultaneous resume owners."""
    def __init__(self, directory):
        self.stream = open(Path(directory) / "resume.lock", "a")
        try:
            fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.stream.close()
            raise ValueError("saved plan already has an active owner") from None

    def close(self):
        self.stream.close()

    @property
    def fd(self):
        return self.stream.fileno()
