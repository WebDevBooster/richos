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
import shlex
import shutil
import subprocess
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


def inventory_identity(path):
    """Bind discovery and existence without hashing unrelated regular-file bytes.

    Links retain their target contents because a reader may traverse them. This
    conservative exception also rejects cycles through the normal path reader.
    """
    path = Path(path)
    if path.is_symlink():
        return {"link": path_identity(path)}
    if not path.exists():
        return {"absent": True}
    mode = path.stat().st_mode & 0o777
    if path.is_dir():
        return {"mode": mode, "directory": {
            p.name: inventory_identity(p) for p in sorted(path.iterdir())}}
    if path.is_file():
        return {"file": True, "mode": mode}
    raise ValueError(f"unsupported inventory input: {path}")


PRIVATE_PROFILE = "private-home-v1"
GIT_FIXTURE = '[user]\n\tname = Verification Fixture\n\temail = verification@example.invalid\n'


def python_runtime(executable):
    """The private profile disables site startup; bind its remaining import roots."""
    program = ('import json,os,sys,sysconfig; print(json.dumps({"version":sys.version,'
               '"paths":[p for p in sys.path if p],"prefix":sys.base_prefix,'
               '"credentials":[os.geteuid(),os.getegid(),sorted(os.getgroups())],'
               '"umask":os.umask(0)}))')
    result = subprocess.run([executable, "-B", "-I", "-S", "-c", program],
                            capture_output=True, text=True, timeout=15, check=True)
    runtime = json.loads(result.stdout)
    # -S excludes site-packages and .pth execution. Source imports ignore bytecode
    # only when it is absent, so include existing bytecode as well as source.
    def inputs(path):
        path = Path(path)
        if path.is_dir() and not path.is_symlink():
            return {p.name: inputs(p) for p in sorted(path.iterdir())
                    if p.name not in ("site-packages", "dist-packages")}
        return path_identity(path)
    runtime["paths"] = {p: digest(inputs(p)) for p in runtime["paths"]}
    framework = Path(runtime["prefix"]) / "Python"
    runtime["framework"] = path_identity(framework)
    return runtime


class InputSnapshot:
    """Share identical reads within one validation pass, never across passes.

    The caller creates a new instance for planning, finalization or coverage.
    There is no persistent metadata cache: changed bytes, inventories and tools
    are read again at the next boundary even if their stat fields are unchanged.
    """
    def __init__(self):
        self.paths = {}
        self.runtimes = {}
        self.inventories = {}

    def path(self, path):
        key = str(Path(path).absolute())
        if key not in self.paths:
            self.paths[key] = path_identity(path)
        return self.paths[key]

    def runtime(self, executable):
        if executable not in self.runtimes:
            self.runtimes[executable] = python_runtime(executable)
        return self.runtimes[executable]

    def inventory(self, path):
        key = str(Path(path).absolute())
        if key not in self.inventories:
            self.inventories[key] = inventory_identity(path)
        return self.inventories[key]


def prepare_environment(item, root, logdir, environment, create=True):
    recipe = contract_for(root, item.label)
    if not recipe.get("isolation"):
        return
    if recipe["isolation"] != PRIVATE_PROFILE:
        raise ValueError("unsupported execution profile: " + recipe["isolation"])
    private = Path(logdir).resolve() / "fixtures" / digest(item.label)
    home, tmp = private / "home", private / "tmp"
    tool_path = environment["PATH"]
    python = shutil.which("python3", path=tool_path)
    if not python:
        raise ValueError("private execution profile requires python3")
    if create:
        home.mkdir(parents=True, mode=0o700)
        tmp.mkdir(mode=0o700)
        (home / ".claude/state").mkdir(parents=True)
        # Allocation appends operational bookkeeping. Seed its file before the
        # record canary witnesses this directory; protected records stay absent.
        (home / ".claude/state/scratch-ledger.jsonl").touch(exist_ok=False)
        (home / ".gitconfig").write_text(GIT_FIXTURE)
        (private / "bin").mkdir(mode=0o700)
        (private / "git-template").mkdir(mode=0o700)
        wrapper = private / "bin/python3"
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(python) + ' -s -S "$@"\n')
        wrapper.chmod(0o700)
    base = {"PATH": str(private / "bin") + os.pathsep + tool_path,
        "RICHOS_VERIFICATION_TOOL_PATH": tool_path, "HOME": str(home), "TMPDIR": str(tmp),
        "CLAUDE_CONFIG_DIR": str(home / ".claude"), "LANG": "C", "LC_ALL": "C", "TZ": "UTC",
        "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"), "GIT_TEMPLATE_DIR": str(private / "git-template"),
        "RICHOS_VERIFICATION_FIXTURE_ROOT": str(private), "RICHOS_VERIFICATION_MODE": "fixture"}
    # Only named stable inputs enter this profile. Per-run ownership/worker fields
    # are attached by launch(), after this environment has been fingerprinted.
    for name in set(recipe["environment"]) | set(recipe["external"]):
        if name in environment and name not in base:
            base[name] = environment[name]
    item.private_environment = base
    item.env = {key: value for key, value in item.env.items() if key in base}


class UnqualifiedReader(ValueError):
    """Changed reviewed code must execute fresh until its input review is renewed."""


def qualify_recipe(root, recipe):
    """Check the execution recipe against its independently reviewed read contract.

    This is a finite input floor, not inference about arbitrary programs. Removing
    a known tool or outside-root dependency must fail before reuse or execution.
    """
    root = Path(root)
    def relative(value):
        if not isinstance(value, str) or not value or Path(value).is_absolute() or ".." in Path(value).parts:
            raise ValueError("input must be repository-relative: " + str(value))
        return value
    qualification = relative(recipe["qualification"])
    if not (root / qualification).is_file():
        raise ValueError("input qualification is missing: " + qualification)
    contract = json.loads((root / qualification).read_text())
    fields = {"paths", "tools", "environment", "external"}
    if (not isinstance(contract, dict) or contract.get("schema") != 1
            or not isinstance(contract.get("requires"), dict)
            or set(contract["requires"]) != fields):
        raise ValueError("invalid reviewed input qualification: " + qualification)
    if contract.get("isolation") and recipe.get("isolation") != contract["isolation"]:
        raise ValueError("input qualification requires isolation: " + contract["isolation"])
    review = relative(contract.get("review"))
    if not (root / review).is_file():
        raise ValueError("input review is missing: " + review)
    unit = recipe.get("qualification_unit")
    extra = None
    if unit is not None:
        extra = contract.get("units", {}).get(unit)
        if (not isinstance(extra, dict) or not extra.get("review")
                or not extra.get("sources") or set(extra.get("requires", {})) != fields):
            raise ValueError("missing reviewed unit qualification: " + str(unit))
        for source, expected in extra["sources"].items():
            source = relative(source)
            if not (root / source).is_file() or file_digest(root / source) != expected:
                raise UnqualifiedReader("changed unit reader requires qualification: " + source)
    for field in sorted(fields):
        for values in (recipe[field], contract["requires"][field]):
            if not isinstance(values, list) or any(not isinstance(v, str) or not v for v in values):
                raise ValueError("invalid input list: " + field)
        required = list(contract["requires"][field])
        if extra is not None:
            values = extra["requires"][field]
            if not isinstance(values, list) or any(not isinstance(v, str) or not v for v in values):
                raise ValueError("invalid unit input list: " + field)
            required.extend(values)
            if field == "paths":
                required.extend(extra["sources"])
        declared = recipe[field]
        if field == "paths":
            for path in [*required, *declared]:
                relative(path)
            missing = [path for path in required if not any(
                Path(path).is_relative_to(parent) for parent in declared)]
        else:
            missing = sorted(set(required) - set(declared))
        if missing:
            raise ValueError("input qualification omits " + field + ": " + ", ".join(missing))
    external_paths = recipe.get("external_paths", [])
    required_external = contract.get("external_paths", [])
    if extra is not None:
        required_external = [*required_external, *extra.get("external_paths", [])]
    for values in (external_paths, required_external):
        if (not isinstance(values, list) or any(not isinstance(v, str) or not Path(v).is_absolute()
                                               or ".." in Path(v).parts for v in values)):
            raise ValueError("external paths must be absolute literals")
    missing = sorted(set(required_external) - set(external_paths))
    if missing:
        raise ValueError("input qualification omits external_paths: " + ", ".join(missing))
    git_inputs = recipe.get("git_inputs", {})
    git_required = [contract.get("git_inputs", {})]
    if extra is not None:
        git_required.append(extra.get("git_inputs", {}))
    for declaration in [git_inputs, *git_required]:
        if not isinstance(declaration, dict) or set(declaration) - {"tracked", "last_change"}:
            raise ValueError("invalid Git input declaration")
        for values in declaration.values():
            if not isinstance(values, list):
                raise ValueError("invalid Git input paths")
            for value in values:
                relative(value)
    for declaration in git_required:
        for kind, required_paths in declaration.items():
            missing = sorted(set(required_paths) - set(git_inputs.get(kind, [])))
            if missing:
                raise ValueError("input qualification omits git_inputs " + kind + ": " + ", ".join(missing))
    if git_inputs and "git" not in recipe["tools"]:
        raise ValueError("Git inputs require the git tool identity")
    if "subset" in recipe:
        subset = recipe["subset"]
        reviewed = extra.get("subset") if extra else None
        common = contract.get("subset_requires")
        if (not isinstance(reviewed, dict) or not reviewed.get("review")
                or not isinstance(common, dict)):
            raise ValueError("missing reviewed subset qualification")
        for declaration in (subset, common, reviewed.get("requires")):
            if not isinstance(declaration, dict) or set(declaration) != {"paths", "inventories"}:
                raise ValueError("invalid subset input declaration")
            for values in declaration.values():
                if not isinstance(values, list):
                    raise ValueError("invalid subset input list")
                for value in values:
                    relative(value)
        for field in ("paths", "inventories"):
            floor = [*common[field], *reviewed["requires"][field]]
            if field == "paths":
                floor.extend(extra["sources"])
                floor.extend(extra["requires"]["paths"])
            missing = [p for p in floor if not any(
                Path(p).is_relative_to(parent) for parent in subset[field])]
            if missing:
                raise ValueError("subset qualification omits " + field + ": " + ", ".join(missing))
        # A subset cannot secretly introduce a new outside-root input while
        # claiming that its Tier 1 parent declaration already covered it.
        for path in [*subset["paths"], *subset["inventories"]]:
            if not any(Path(path).is_relative_to(parent) for parent in recipe["paths"]):
                raise ValueError("subset input is outside declared roots: " + path)
    return [qualification, review]


def git_input_identity(root, declaration, environment):
    """Read only the qualified index/history inputs, without keying on HEAD.

    File contents are independently covered by paths. Tracked membership and
    commit timestamps can change while those bytes stay identical. Whole-repo
    HEAD would instead invalidate results for unrelated documentation commits.
    """
    if not declaration:
        return {}
    executable = shutil.which("git", path=environment.get("PATH"))
    if not executable:
        raise ValueError("Git input identity requires an available git")
    def read(*args, absent=False):
        result = subprocess.run([executable, "-C", str(root), *args], env=environment,
                                capture_output=True, timeout=10)
        if result.returncode != 0 and not (absent and result.returncode == 1):
            raise ValueError("cannot read qualified Git input: " + " ".join(args))
        return {"exit": result.returncode, "sha256": hashlib.sha256(result.stdout).hexdigest()}
    identity = {}
    if declaration.get("tracked"):
        identity["tracked"] = read("ls-files", "--stage", "-z", "--", *declaration["tracked"])
        # The packaging suite also uses line-oriented ls-files. Its quoting is
        # controlled by local repository config even under the private profile.
        identity["quote_path"] = read("config", "--get", "core.quotepath", absent=True)
    if declaration.get("last_change"):
        identity["last_change"] = {path: read("log", "-1", "--format=%ct", "--", path)
                                   for path in declaration["last_change"]}
    return identity


def recipe_identity(root, recipe, environment, snapshot=None):
    """Validate the finite declaration, then fingerprint every declared input.

    An absent contract is deliberately not a reusable identity. The declaration
    and its qualification are versioned source inputs, so changing either cannot
    inherit a previous result. Secret environment values are hashed, never logged.
    """
    if recipe.get("fresh"):
        return {"fresh": recipe["fresh"]}
    required = {"paths", "tools", "environment", "external", "qualification"}
    if set(recipe) - {"isolation", "qualification_unit", "external_paths", "git_inputs", "subset"} != required or not recipe["qualification"]:
        raise ValueError("incomplete verification input contract")
    root = Path(root).resolve()
    snapshot = snapshot or InputSnapshot()
    try:
        qualification_paths = qualify_recipe(root, recipe)
    except UnqualifiedReader as exc:
        return {"fresh": str(exc)}
    paths = {}
    selected_paths = recipe.get("subset", {}).get("paths", recipe["paths"])
    for rel in [*selected_paths, *qualification_paths]:
        path = root / rel
        if Path(rel).is_absolute() or ".." in Path(rel).parts:
            raise ValueError(f"input must be repository-relative: {rel}")
        paths[rel] = digest(snapshot.path(path))
    tools = {}
    for name in recipe["tools"]:
        resolved = shutil.which(name, path=environment.get("RICHOS_VERIFICATION_TOOL_PATH", environment.get("PATH")))
        tools[name] = ({"path": resolved, "input": snapshot.path(resolved)}
                       if resolved else {"absent": True})
        if name == "python3" and resolved and recipe.get("isolation"):
            tools[name]["runtime"] = snapshot.runtime(resolved)
    external = {}
    for name in recipe["external"]:
        value = environment.get(name)
        external[name] = digest(snapshot.path(value)) if value else {"unset": True}
    values = {name: digest(environment[name]) if name in environment else None
              for name in recipe["environment"]}
    profile = None
    if recipe.get("isolation"):
        if recipe["isolation"] != PRIVATE_PROFILE:
            raise ValueError("unsupported execution profile")
        private = environment.get("RICHOS_VERIFICATION_FIXTURE_ROOT")
        if not private or environment.get("HOME") != str(Path(private) / "home"):
            raise ValueError("qualified private execution environment is absent")
        names = {"PATH", "HOME", "TMPDIR", "CLAUDE_CONFIG_DIR", "LANG", "LC_ALL", "TZ",
                 "PYTHONDONTWRITEBYTECODE", "PYTHONNOUSERSITE", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL",
                 "GIT_TEMPLATE_DIR", "RICHOS_VERIFICATION_TOOL_PATH", "RICHOS_VERIFICATION_FIXTURE_ROOT",
                 "RICHOS_VERIFICATION_MODE",
                 *recipe["environment"], *recipe["external"]}
        values = {name: digest(environment[name].replace(private, "$FIXTURE"))
                  if name in environment else None for name in names}
        profile = {"name": PRIVATE_PROFILE, "git_fixture": digest(GIT_FIXTURE),
                   "scratch_ledger_seed": digest("")}
    literal_external = {path: digest(snapshot.path(path)) for path in recipe.get("external_paths", [])}
    return {"contract": digest(recipe), "paths": paths, "tools": tools, "profile": profile,
            "inventories": {path: digest(snapshot.inventory(root / path))
                            for path in recipe.get("subset", {}).get("inventories", [])},
            "external_paths": literal_external,
            "git_inputs": git_input_identity(root, recipe.get("git_inputs"), environment),
            "environment": values, "external": external,
            "platform": [platform.system(), platform.release(), platform.machine(), platform.mac_ver()[0], os.cpu_count()]}


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
                 current_source=None, current_identity=None, current_identities=None):
        self.root, self.logdir = str(root), Path(logdir)
        self.source, self.identities = source, identities
        self.previous = previous
        self.current_source = current_source or (lambda: self.source)
        self.current_identity = current_identity or (lambda item: self.identities[item.label])
        self.current_identities = current_identities or (
            lambda selected: {item.label: self.current_identity(item) for item in selected})
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
                  "attempts": getattr(item, 'attempts', []),
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
        selected = [item for item in items if item.state == 'passed' and item.label in self.results]
        input_error = None
        try:
            identities = self.current_identities(selected)
            changed_during_read = self.current_source() != source
        except (OSError, ValueError, KeyError, TypeError) as exc:
            input_error = str(exc)
        for item in items:
            if item.state != "passed" or item.label not in self.results:
                continue
            row = self.results[item.label]
            try:
                if input_error is not None:
                    raise ValueError(input_error)
                if changed_during_read or source != row["source"] or identities[item.label] != row["input"]:
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


def pool_directory(root, history):
    common = subprocess.check_output(["git", "-C", str(root), "rev-parse",
        "--path-format=absolute", "--git-common-dir"], text=True).strip()
    return Path(history).parent / "input-owners" / digest(os.path.realpath(common))


class Pool:
    """One kernel-held owner per qualified input, pointing to existing evidence.

    There is no cached verdict here. Every hit goes through reuse() and the
    normal target coverage verifier. A completed unit can be joined while its
    original run continues with other units: its own lock is the publication
    boundary. Supervisors inherit it until owned cleanup has finished.
    """
    def __init__(self, directory, record, retry_reason=None):
        self.directory, self.record = Path(directory), record
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.retry_reason = retry_reason
        self.held = {}

    def claim(self, item):
        identity = self.record.identities[item.label]
        if identity.get("fresh") or item.label == "engine receipts":
            return True
        if item.label in self.held:
            return True
        key = digest({"check": item.label, "input": identity})
        fd = os.open(self.directory / (key + ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        path = self.directory / (key + ".json")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            try:
                owner = json.loads(path.read_text())
                description = str(owner.get("run", "owner is publishing its identity"))
            except (OSError, ValueError):
                description = "owner is publishing its identity"
            note = "join identical input owner: " + description
            if note not in item.notes:
                item.notes.append(note)
                print("proof-run: %s: %s" % (item.label, note), flush=True)
            return False
        try:
            try:
                previous = json.loads(path.read_text())
            except FileNotFoundError:
                previous = {}
            # Corrupt counters are not absence: refuse rather than reset a budget.
            failures = previous.get("functional_failures", [])
            if not isinstance(failures, list):
                raise ValueError("invalid durable retry history: " + str(path))
            if previous.get("run") and previous["run"] != str(self.record.logdir):
                try:
                    reuse(previous["run"], [item], self.record, exact=False)
                except (OSError, ValueError, KeyError, TypeError) as exc:
                    item.notes.append("prior evidence unavailable: " + str(exc))
            if item.state not in ("waiting", "passed"):
                os.close(fd)
                return False
            if item.state != "passed" and failures:
                reason = ("unchanged inputs exhausted their two-attempt functional budget"
                          if len(failures) >= 2 else
                          "unchanged failed inputs require --retry-reason with the diagnosis")
                if len(failures) >= 2 or not self.retry_reason:
                    item.finish_queue()
                    item.state, item.rc = "blocked", 75
                    item.notes.append(reason + "; prior evidence: " + failures[-1]["run"])
                    os.close(fd)
                    return False
            row = {"run": str(self.record.logdir), "check": item.label,
                   "pid": os.getpid(), "functional_failures": failures,
                   "retry_reason": self.retry_reason, "state": item.state}
            atomic(path, row)
            self.held[item.label] = (fd, path, row)
            item.input_owner_fd = fd
            if item.state == "passed":
                item.finish_queue()
                self.finish(item)
                return False
            return True
        except BaseException:
            os.close(fd)
            raise

    def finish(self, item):
        held = self.held.pop(item.label, None)
        if held is None:
            return
        fd, path, row = held
        try:
            row["state"] = item.state
            if self.functional_failure(item):
                row["functional_failures"].append({"run": str(self.record.logdir),
                    "exit": item.rc, "diagnosis": self.retry_reason})
            atomic(path, row)
        finally:
            # close, not LOCK_UN: an inherited supervisor still owns this flock
            # if the caller is interrupted before descendant cleanup finishes.
            os.close(fd)
            del item.input_owner_fd

    @staticmethod
    def functional_failure(item):
        if item.state != "failed":
            return False
        receipt = receipt_path(item)
        if receipt:
            try:
                rows = [json.loads(line) for line in receipt.read_text().splitlines() if line.strip()]
                return (len(rows) == 1 and rows[0].get("execution_status") == "completed"
                        and rows[0].get("verdict") == "FAIL")
            except (OSError, ValueError):
                return False  # Missing execution evidence is not an assertion failure.
        return item.rc not in (75, 124, 125, 126, 127, 130) and 0 < item.rc < 128

    def close(self, items):
        for item in items:
            self.finish(item)


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
    for item in items:
        prepare_environment(item, root, directory, runner.execution_environment(item), create=False)
    units = {item.argv[item.argv.index("--only-units") + 1]: item
             for item in items if item.engine_unit}
    if len(units) != sum(item.engine_unit for item in items):
        raise ValueError("target execution plan contains duplicate engine obligations")
    snapshot = InputSnapshot()
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
        actual = runner.input_identity(item, SimpleNamespace(**identity["settings"]), directory, snapshot)
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
    if runner.source_identity() != plan["source"]:
        raise ValueError("target source changed during input validation")
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
