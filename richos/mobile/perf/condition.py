"""condition — the state a start-time measurement ran under, written into every record.

A launch time depends on what the app reads at launch, not only on its code. On 2026-10-02
andy-opus-coldstart1 showed that phone records compared as a "slowdown" had been measured with
different conversations on the phone and a live Mac; rebuilt and measured under one fixed
condition, the "slower" build equalled the "fast" one. So every record names its condition, and
a record is compared only with a benchmark taken under the same condition (benchmark.py).

A condition is:

    conversation  the made-up conversation the app held at launch: its fixture name, row count
                  and the sha256 of exactly what was seeded (`as-installed` = not seeded,
                  uncontrolled, never compared)
    mac           "unreachable" or "reachable": whether the app could reach a Mac while measured
    build         "release" or "debug"

`KEYS` are the fields that must be equal for two measurements to be compared. Everything else
in a condition (how it was seeded, its display name) is description.

Two seeded conversations exist:

    FILE_FIXTURE    the app's own saved-state files (session.json, history.json under
                    files/core), generated here; the pairing names a host under `.invalid`, a
                    name that never resolves (RFC 6761), so the Mac is unreachable by
                    construction. Ported from andy-opus-coldstart1's genstate.py (2026-10-02);
                    byte-identical output for the same row count.
    BRIDGE_FIXTURE  the Debug build's development bridge: a `hello` frame of synthetic rows
                    (android.history_frame), fed with the scripted Mac set unreachable.

Synthetic text only: no person, no real conversation, no device-derived number.
"""
import datetime
import hashlib
import json
import os

FILE_FIXTURE = "synthetic-conversation/1"
BRIDGE_FIXTURE = "devbridge-hello/1"
AS_INSTALLED = "as-installed"
# The default row counts are the ones the established benchmarks were measured with: the
# phone's release benchmark at 100 rows (andy-opus-coldstart1), the emulator's Debug benchmark
# at 40 (the 2026-09-24 baseline). A different count is a different condition, never compared.
FILE_DEFAULT_ROWS = 100
BRIDGE_DEFAULT_ROWS = 40
MAC_STATES = ("unreachable", "reachable")
BUILDS = ("release", "debug")
KEYS = ("conversation.fixture", "conversation.rows", "conversation.sha256", "mac", "build")
DIFFERENT = "different conditions"
DECLARATION_SCHEMA = "richos-mobile-perf-condition-declaration/1"

# FILE_FIXTURE's content. Changing any of it changes the fixture: give it a new name.
_API = "https://coldstart-perf.invalid"
_DEVICE = "perf-device-0001"
_THREAD = "perf-thread"
_START = datetime.datetime(2026, 9, 30, 8, 0, tzinfo=datetime.timezone.utc)
_REPLY = ("Here is what I found. The quarterly numbers came in slightly above plan, and the two "
          "open questions from Tuesday are answered in the note I left on your desk. Nothing needs "
          "you today; I will flag anything that changes before your 3 PM.")


class ConditionError(Exception):
    """A condition that cannot be stated honestly (refused by the caller)."""


def _lookup(node, dotted):
    for part in dotted.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def _row_text(i):
    return (f"Perf probe {i // 2 + 1}: what is on my plate this afternoon?" if i % 2 == 0
            else f"{_REPLY} ({i // 2 + 1})")


def file_fixture(rows):
    """{file name: bytes} of FILE_FIXTURE with `rows` cached rows: a paired session whose Mac is
    unreachable, and its history. Deterministic: the same `rows` always gives the same bytes."""
    if not isinstance(rows, int) or rows < 1:
        raise ConditionError(f"a seeded conversation needs at least one row, not {rows!r}")
    out = []
    for i in range(rows):
        at = (_START + datetime.timedelta(minutes=3 * i)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        out.append({"id": f"row-{i:05d}", "thread_id": _THREAD, "cursor": 2 * i + 1,
                    "role": "ceo" if i % 2 == 0 else "rich", "kind": "text", "text": _row_text(i),
                    "created_at": at, "has_audio": False, "from_microphone": False,
                    "state": "complete", "complete": True})
    session = {"threads": [{"id": _THREAD, "title": "Rich"}], "selectedThreadId": _THREAD, "draft": "",
               "online": False, "paired": True, "theme": "dark",
               "pairing": {"phase": "paired", "apiBase": _API, "route": "connect", "deviceId": _DEVICE},
               "cache": {}, "capabilities": ["voice", "attachments"],
               "notifications": {"status": "off", "offerDismissed": True, "previews": True}}
    history = {"identity": _API + "\n" + _DEVICE, "rows": {_THREAD: out}, "older": {_THREAD: False},
               "cursor": 2 * rows}
    return {"session.json": json.dumps(session).encode(), "history.json": json.dumps(history).encode()}


def file_fixture_marker(rows):
    """The text of the newest seeded CEO row, short and unique to this row count: on screen after a
    launch when the app read the fixture (the newest reply's text repeats in every reply)."""
    return _row_text(rows - 1 if (rows - 1) % 2 == 0 else rows - 2)


def _manifest_sha256(files):
    """sha256 of a sha256sum-style manifest of the files, in name order."""
    lines = "".join(f"{hashlib.sha256(files[name]).hexdigest()}  {name}\n" for name in sorted(files))
    return hashlib.sha256(lines.encode()).hexdigest()


def seeded(fixture, rows, sha256, mac, build, seeded_by, files=None):
    if mac not in MAC_STATES:
        raise ConditionError(f"the Mac is {MAC_STATES[0]} or {MAC_STATES[1]}, not {mac!r}")
    if build not in BUILDS:
        raise ConditionError(f"the build is {BUILDS[0]} or {BUILDS[1]}, not {build!r}")
    conversation = {"fixture": fixture, "rows": rows, "sha256": sha256, "seededBy": seeded_by}
    if files:
        conversation["files"] = {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())}
    return {"name": f"{fixture} x{rows}, Mac {mac}, {build} build", "conversation": conversation,
            "mac": mac, "build": build}


def for_files(rows, build, seeded_by):
    """The condition of FILE_FIXTURE seeded into the app's files: the Mac is unreachable by
    construction (the pairing names a host under .invalid)."""
    files = file_fixture(rows)
    return seeded(FILE_FIXTURE, rows, _manifest_sha256(files), "unreachable", build, seeded_by, files)


def for_bridge(rows, frame, mac, build):
    """The condition of BRIDGE_FIXTURE: `frame` is the hello frame that was fed."""
    sha = hashlib.sha256(json.dumps(frame, sort_keys=True).encode()).hexdigest()
    return seeded(BRIDGE_FIXTURE, rows, sha, mac, build,
                  "the Debug build's development bridge (a hello frame of synthetic rows)")


def as_installed(mac, build, why):
    """Not seeded: the app held whatever it held. Recorded so the record says so; never compared."""
    return {"name": f"{AS_INSTALLED} (uncontrolled), Mac {mac}, {build or 'unknown'} build",
            "conversation": {"fixture": AS_INSTALLED, "rows": None, "sha256": None, "why": why},
            "mac": mac, "build": build}


def why_not_comparable(record_condition, bench_condition):
    """None when the two conditions are the same on every KEY; otherwise the sentence saying how
    they differ, starting with DIFFERENT."""
    if not record_condition:
        return (f"{DIFFERENT}: the record names no condition (measured before perf.py wrote one, or "
                "written by hand); a record is compared only with benchmarks taken under the same condition")
    if _lookup(record_condition, "conversation.fixture") == AS_INSTALLED:
        return (f"{DIFFERENT}: the record's conversation is {AS_INSTALLED} (not a seeded fixture), "
                "so nothing taken under a fixed condition can be compared with it")
    if (record_condition.get("verified") or {}).get("onScreen") is False:
        return (f"{DIFFERENT}: the seeded row {record_condition['verified'].get('row')!r} was not on screen "
                "after the cold series, so the app did not launch into the conversation it was given")
    if not bench_condition:
        return f"{DIFFERENT}: the benchmark class names no condition yet (it has no number taken under one)"
    diffs = [f"{k} is {_lookup(record_condition, k)!r} here, {_lookup(bench_condition, k)!r} in the benchmark"
             for k in KEYS if _lookup(record_condition, k) != _lookup(bench_condition, k)]
    return f"{DIFFERENT}: " + "; ".join(diffs) if diffs else None


def same(a, b):
    """Two conditions are the same when both are absent or every KEY is equal."""
    if not a or not b:
        return not a and not b
    return all(_lookup(a, k) == _lookup(b, k) for k in KEYS)


def check(cond):
    """Problems with a condition as stated (a benchmark class's, or a declaration's), each a phrase
    that follows the owner's name: "class X names no condition"."""
    if not isinstance(cond, dict) or not cond:
        return ["names no condition"]
    problems = []
    if _lookup(cond, "conversation.fixture") == AS_INSTALLED:
        problems.append(f"names the condition {AS_INSTALLED}, which is never comparable")
    problems += [f"names a condition without {k}" for k in KEYS if _lookup(cond, k) in (None, "")]
    if cond.get("mac") not in MAC_STATES:
        problems.append(f"names a condition whose mac {cond.get('mac')!r} is not one of {MAC_STATES}")
    if cond.get("build") not in BUILDS:
        problems.append(f"names a condition whose build {cond.get('build')!r} is not one of {BUILDS}")
    return problems


# ------------------------------------------------------------------------------------------------
# Declarations: the condition of records measured before perf.py wrote one
# ------------------------------------------------------------------------------------------------

def _sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load_declaration(path):
    """A declaration names a condition and the exact record files (by sha256) it applies to, with
    the evidence. It never applies to a record that names a condition of its own."""
    try:
        with open(path) as f:
            decl = json.load(f)
    except (OSError, ValueError) as e:
        raise ConditionError(f"the condition declaration {path} is unreadable: {e}")
    if decl.get("schema") != DECLARATION_SCHEMA:
        raise ConditionError(f"{path}: schema is {decl.get('schema')!r}, not {DECLARATION_SCHEMA}")
    problems = check(decl.get("condition"))
    if problems:
        raise ConditionError(f"the declaration {path} {problems[0]}")
    for key in ("records", "evidence", "declaredBy", "date"):
        if not decl.get(key):
            raise ConditionError(f"{path}: names no {key}")
    for entry in decl["records"]:
        if not entry.get("sha256") or not entry.get("record"):
            raise ConditionError(f"{path}: a record entry lacks record or sha256: {entry}")
    decl["_path"], decl["_sha256"] = path, _sha256_file(path)
    return decl


def consistent(record, cond):
    """Problems where what the record itself says contradicts a declared condition."""
    problems = []
    build = _lookup(record, "build.configuration")
    if build is not None and build != cond["build"]:
        problems.append(f"the record's build is {build}, the declaration says {cond['build']}")
    network = _lookup(record, "conditions.networkCondition")
    transport = _lookup(record, "conditions.transport")
    said = ("unreachable" if network in ("mac-unreachable", "scripted-unreachable") or transport == "unreachable"
            else "reachable" if network == "live" or transport == "accept" else None)
    if said is not None and said != cond["mac"]:
        problems.append(f"the record says the Mac was {said}, the declaration says {cond['mac']}")
    history = _lookup(record, "conditions.history")
    if history is not None and history != _lookup(cond, "conversation.rows"):
        problems.append(f"the record seeded {history} rows, the declaration says {_lookup(cond, 'conversation.rows')}")
    return problems


def apply(record, path, declarations):
    """The record's condition: its own, else the one a declaration states for exactly this file.
    Returns (condition or None, declaration source or None)."""
    own = record.get("condition")
    digest = _sha256_file(path) if declarations else None
    matching = [d for d in declarations or [] if any(e["sha256"] == digest for e in d["records"])]
    if own:
        if matching:
            raise ConditionError(f"{path} names its own condition; a declaration never replaces it")
        return own, None
    if not matching:
        return None, None
    if len(matching) > 1:
        raise ConditionError(f"{path} is named by {len(matching)} condition declarations; one record has one condition")
    decl = matching[0]
    problems = consistent(record, decl["condition"])
    if problems:
        raise ConditionError(f"{path}: the declaration {decl['_path']} contradicts the record: {problems[0]}")
    return decl["condition"], {"declaration": decl["_path"], "declarationSha256": decl["_sha256"]}


def declare(fixture, rows, mac, build, seeded_by, evidence, declared_by, date, record_paths, label=lambda p: p):
    """A declaration for records measured before perf.py wrote a condition: the condition is computed
    here from the fixture (never typed), and every record must agree with it on what it says itself."""
    if fixture == FILE_FIXTURE:
        if mac != "unreachable":
            raise ConditionError(f"{FILE_FIXTURE}'s pairing never resolves: its Mac is unreachable, not {mac}")
        cond = for_files(rows, build, seeded_by)
    elif fixture == BRIDGE_FIXTURE:
        import android
        cond = for_bridge(rows, android.history_frame(rows), mac, build)
        cond["conversation"]["seededBy"] = seeded_by
    else:
        raise ConditionError(f"no fixture named {fixture!r} (known: {FILE_FIXTURE}, {BRIDGE_FIXTURE})")
    records = []
    for path in record_paths:
        with open(path) as f:
            record = json.load(f)
        if record.get("condition"):
            raise ConditionError(f"{path} names its own condition; a declaration is only for records without one")
        problems = consistent(record, cond)
        if problems:
            raise ConditionError(f"{path}: {problems[0]}")
        records.append({"record": label(path), "sha256": _sha256_file(path),
                        "commit": _lookup(record, "build.commit"), "startedAt": record.get("startedAt")})
    if not records:
        raise ConditionError("a declaration names at least one record")
    return {"schema": DECLARATION_SCHEMA, "condition": cond, "records": records, "evidence": evidence,
            "declaredBy": declared_by, "date": date}


def write_fixture(rows, directory):
    """Write FILE_FIXTURE's files into `directory` (for a push); returns {name: path}."""
    os.makedirs(directory, exist_ok=True)
    paths = {}
    for name, data in file_fixture(rows).items():
        paths[name] = os.path.join(directory, name)
        with open(paths[name], "wb") as f:
            f.write(data)
    return paths
