"""phone_changes — a change a run makes to a phone is written down on the Mac BEFORE it is made, so a run that
is killed, loses the phone or never reaches its cleanup still has its change undone by the next command.

CEO 2026-10-04: "I can only hope that my Android phone doesn't get clogged up with the same broken automation
crap." Three things a perf run changes outlive a hard kill: `dumpsys battery unplug` (the phone believes it is
on battery), `atrace --async_start` (system tracing stays on) and `cmd uimode night yes|no` (the theme stays
forced). Each is recorded here first (`begin`), undone and erased when the run finishes, and any record still
on disk is undone by `restore` when the next perf run or the next `randroid device` command starts. A record
whose phone is not attached stays until that phone is. `pending` lists them (for `device condition`).
"""
import hashlib
import json
import os
import time

KINDS = ("battery", "atrace", "night")


def records_dir():
    d = os.environ.get("RICHOS_PHONE_CHANGES_DIR") or os.path.join(os.path.expanduser("~"), ".richos-phone-changes")
    os.makedirs(d, exist_ok=True)
    return d


def _path(serial, kind):
    return os.path.join(records_dir(), f"{hashlib.sha256(serial.encode()).hexdigest()[:16]}-{kind}.json")


def begin(serial, kind, undo):
    """Write the record (durably) before the change; `undo` is the list of shell commands that put it back."""
    path = _path(serial, kind)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"serial": serial, "kind": kind, "undo": list(undo), "at": time.time()}, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def forget(serial, kind):
    try:
        os.remove(_path(serial, kind))
    except FileNotFoundError:
        pass


def pending(serial=None):
    """Every change a previous run recorded and did not undo (for one phone, or all)."""
    out = []
    d = records_dir()
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name)) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            continue
        if serial is None or rec.get("serial") == serial:
            out.append(rec)
    return out


def restore(serial, sh, log=lambda s: None):
    """Undo every leftover for `serial`. `sh(command)` runs one shell command on that phone and returns True when it
    succeeded; a record whose undo failed stays for the next try. Returns the kinds restored."""
    done = []
    for rec in pending(serial):
        try:
            ok = all(sh(c) for c in rec["undo"])
        except Exception:  # noqa: BLE001 — the phone went away: the record waits for it
            ok = False
        if ok:
            forget(serial, rec["kind"])
            done.append(rec["kind"])
            log(f"put back what a previous run left on {serial}: {rec['kind']}")
    return done
