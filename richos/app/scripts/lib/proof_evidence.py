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


def command_identity(item, root, logdir):
    # Placement and predicted duration are scheduling metadata. They do not
    # change an exact unit's command, assertions or declared execution inputs.
    row = encode_item(item, root, logdir)
    return {key: row[key] for key in ("check", "cwd", "argv")}


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
                    result["receipt_sha"] = getattr(item, "receipt_sha", source["commit"])
                    result["receipt"] = completed_receipt(item, result["receipt_sha"],
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

    def finalize(self, items):
        """Later checks must not invalidate an earlier pass or its copied proof."""
        source = self.current_source()
        for item in items:
            if item.state != "passed" or item.label not in self.results:
                continue
            row = self.results[item.label]
            try:
                if source != row["source"] or self.current_identity(item) != row["input"]:
                    raise ValueError("inputs changed after this check completed")
                if file_digest(item.log) != row["log_sha256"]:
                    raise ValueError("completed check log changed")
                if row["receipt"] and file_digest(row["receipt"]["path"]) != row["receipt"]["sha256"]:
                    raise ValueError("completed check receipt changed")
            except (OSError, ValueError, KeyError, TypeError) as exc:
                item.state, item.rc = "invalid", 125
                reason = "final evidence validation: " + str(exc)
                item.notes.append(reason)
                row.update(state=item.state, exit=item.rc, invalid=reason)
        atomic(self.logdir / "outcomes.json", self.results)


def read_plan(path):
    plan = json.loads((Path(path) / "plan.json").read_text())
    if plan.get("schema") != 1:
        raise ValueError("unsupported or missing saved plan schema")
    labels = [row["check"] for row in plan["items"]]
    if len(labels) != len(set(labels)):
        raise ValueError("saved plan contains duplicate obligations")
    return plan


def reuse(previous, items, record, exact=True):
    """Select exact applicable passes; leave failed evidence in its original run."""
    previous = Path(previous)
    plan = read_plan(previous)
    if exact and plan["root"] != record.root:
        raise ValueError("exact resume requires the saved checkout")
    if exact and plan["items"] != record.plan["items"]:
        raise ValueError("resume cannot change the frozen plan or execution recipe")
    try:
        outcomes = json.loads((previous / "outcomes.json").read_text())
    except FileNotFoundError:
        outcomes = {}
    for item in items:
        if item.state == "passed":
            continue
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
        elif exact and (old.get("source") != record.source or plan["source"] != record.source):
            reason = "source identity changed"
        elif old.get("source") != plan["source"]:
            reason = "source changed during the original execution"
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
                    item.receipt_sha = old.get("receipt_sha", old["source"]["commit"])
                    completed_receipt(item, item.receipt_sha)
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
                item.state, item.rc, item.log = "waiting", None, None
                for name in ("provenance", "reused_from"):
                    if hasattr(item, name):
                        delattr(item, name)
                if hasattr(item, "receipt_sha"):
                    del item.receipt_sha
                if target and target.exists():
                    target.unlink()
        if reason:
            item.notes.append("execute: " + reason)


def verify_target_receipts(directory, rows, root):
    """Independently recheck the current inputs and exact artifacts for coverage.

    Called by ci-receipts, the sole coverage authority. Historical receipt SHAs
    remain immutable. A target outcome alone cannot excuse a missing, changed,
    noncompleted or unqualified historical receipt.
    """
    import importlib.util
    from types import SimpleNamespace
    directory, root = Path(directory).resolve(), Path(root).resolve()
    plan = read_plan(directory)
    if Path(plan["root"]).resolve() != root:
        raise ValueError("evidence belongs to a different target checkout")
    spec = importlib.util.spec_from_file_location("verification_target_runner",
        root / "richos/app/scripts/proof-run.py")
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    runner.ROOT = str(root)
    if runner.source_identity() != plan["source"]:
        raise ValueError("target source changed since the plan was recorded")
    outcomes = json.loads((directory / "outcomes.json").read_text())
    items = [decode_item(row, runner.Item, root, directory) for row in plan["items"]]
    runner.supply_runtime(items)
    units = {item.argv[item.argv.index("--only-units") + 1]: item
             for item in items if item.engine_unit}
    if len(units) != sum(item.engine_unit for item in items):
        raise ValueError("target execution plan contains duplicate engine obligations")
    for row in rows:
        unit = row["unit"]
        if unit not in units:
            raise ValueError("receipt absent from target execution plan: " + unit)
        item = units[unit]
        outcome = outcomes[item.label]
        identity = plan["identities"][item.label]
        if (outcome.get("state") != "passed" or outcome.get("exit") != 0
                or outcome.get("invalid") or outcome.get("source") != plan["source"]
                or outcome.get("input") != identity):
            raise ValueError("no validated target outcome for " + unit)
        actual = runner.input_identity(item, SimpleNamespace(**identity["settings"]), directory)
        if actual != identity:
            raise ValueError("target execution inputs changed for " + unit)
        receipt = outcome["receipt"]
        if file_digest(receipt["path"]) != receipt["sha256"]:
            raise ValueError("target receipt artifact changed for " + unit)
        stored = [json.loads(line) for line in Path(receipt["path"]).read_text().splitlines() if line.strip()]
        if stored != [row]:
            raise ValueError("coverage receipt differs from its validated artifact for " + unit)
        if file_digest(outcome["log"]) != outcome["log_sha256"]:
            raise ValueError("completed execution log changed for " + unit)
        historical = row.get("sha") != plan["source"]["commit"]
        provenance = outcome.get("provenance")
        if historical or outcome.get("reused_from"):
            if (identity.get("fresh") or not provenance or provenance.get("input") != identity
                    or row.get("sha") != outcome.get("receipt_sha")
                    or row.get("schema") != 2 or row.get("execution_status") != "completed"
                    or row.get("verdict") != "PASS" or row.get("rc") != row.get("expected_rc")
                    or provenance.get("receipt", {}).get("sha256") != receipt["sha256"]
                    or provenance.get("log_sha256") != outcome["log_sha256"]):
                raise ValueError("unqualified historical receipt for " + unit)
        elif row.get("sha") != outcome.get("receipt_sha", plan["source"]["commit"]):
            raise ValueError("receipt execution commit differs for " + unit)
    return plan["source"]["commit"]


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
