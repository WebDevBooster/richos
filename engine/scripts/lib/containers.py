#!/usr/bin/env python3
"""containers.py — THE UNREAPED HALF OF THE WORKSPACE LIFECYCLE.

    "reap PROCESSES, not just directories"  — CLAUDE.md, after a detached
    child outlived both its agent and its worktree.

It was written about processes. Containers are the same defect wearing a
different hat, and nothing was reaping them. Measured on the founder's machine
on 2026-09-13, before this file existed:

    30 containers, 10 active, 7.04GB   |  38 images, 37.34GB, 25.62GB reclaimable
    agent-af36c9abcc76937ab-redis-1 ... Exited (255) 3 weeks ago
    rl55, rlx ....................... Up 3 days

`agent-af36c9abcc76937ab` is an agent id. A teammate made that container, the
teammate is six weeks gone, and the container is still there. His question was
"how many times will this kind of shit keep getting repeated after the current
run is finished?", and the only answer that counts is a lifecycle event, not a
promise to tidy up.

===========================================================================
OWNERSHIP IS DERIVED, NEVER ASKED FOR
===========================================================================
A reaper that needs its creator's cooperation reaps nothing, because the
creator is an ad-hoc `docker run` in some teammate's turn and there is no
engine code path in between. So ownership is read off what Docker records on
its own, in three kinds, and the KIND IS KEPT — it decides what may be done.

  DECLARED (authorizes deletion)
    1. `sh.richos.workspace=<abs path>` — the label this engine asks for, for
       anything created from here on. WORKSPACE_LABEL below is the only
       spelling; docker_run_args() hands it out so no caller invents another.
    2. `com.docker.compose.project.working_dir` — Compose stamps the absolute
       project directory on every container it creates, with no cooperation
       from anyone. This is why the historical residue is attributable at all:
         agent-af36c9abcc76937ab-redis-1
           -> /Users/alex/ab/deeply/.claude/worktrees/agent-af36c9abcc76937ab
         norm-tile-names-redis-1
           -> /Users/alex/ab/deeply/.claude/worktrees/norm-tile-names
       The name leaks the owner too, but the name is a basename that can
       collide and be chosen by hand; the label is an absolute path that is
       exactly what workspaces.py stores. Never parse the name.

  INFERRED (protects, and NEVER authorizes deletion)
    3. A bind mount whose source is a registered workspace. Real, and measured:
         richos-ci86 -> /Users/alex/ab/richos-wt/zach-opus-ci4 (a live agent's
         workspace, running right now).
       But mounting a directory is ALSO exactly how a person runs a container
       against a checkout by hand, and the container is then theirs, not the
       workspace's.

THE ASYMMETRY IS THE WHOLE SAFETY ARGUMENT: every kind of evidence is believed
when it says "do not touch this", and only a declaration is believed when it
says "this is disposable". A wrong protect costs disk. A wrong delete costs
somebody's running work, and one of those is recoverable.

===========================================================================
WHAT THIS FILE WILL NOT DO
===========================================================================
  - It never runs `docker system prune`, or anything with that blast radius.
    Reclaiming the 25.62GB of images is a judgment call about a human's
    machine and it belongs to him. This file reports that number; he spends it.
  - It never deletes an orphan. Something owned by no live workspace is
    REPORTED with its age and size and left alone, because the class "not
    attributable to a live workspace" contains both agent residue and the
    container a person started by hand this morning, and it cannot tell them
    apart with enough confidence to destroy one.
  - It never deletes volumes or images. A volume holds data.
  - It never touches a container whose owner is LIVE, whatever the evidence.

Deletion happens in exactly one circumstance: a workspace ENDED (landed or
discarded), and a container DECLARES that workspace as its owner.

===========================================================================
DEGRADING QUIETLY
===========================================================================
Docker missing, daemon down, `docker` hanging: every entry point returns a
result whose `available` is false and whose `reason` says which, and NOTHING
fails. This is called from the workspace deleter, and a machine without Docker
must land work exactly as it does today. Every docker call is bounded by a
timeout, because a wedged daemon that blocks `docker ps` forever would
otherwise hang a land.

If liveness cannot be established (workspaces.py unreadable), the sweep
protects EVERYTHING and deletes nothing: not knowing who is alive is a reason
to keep your hands still, not a reason to guess.
"""

import calendar
import json
import os
import subprocess
import sys
import time

# The one spelling of the ownership label. Anything that creates a container
# for a workspace sets this; anything that reaps one reads it.
WORKSPACE_LABEL = "sh.richos.workspace"
COMPOSE_DIR_LABEL = "com.docker.compose.project.working_dir"
# `com.docker.compose.project` is DELIBERATELY not here. It carries the project
# NAME — a basename a person can choose and two repositories can share — and
# this file attributes ownership by absolute path only. A constant sitting here
# unused would be an invitation to the exact shortcut the header argues against.

# A wedged daemon must not hang a land. These are deliberately short.
DOCKER_TIMEOUT = 30
DOCKER_PROBE_TIMEOUT = 10
DOCKER_REMOVE_TIMEOUT = 60


# ---------------------------------------------------------------------------
# talking to docker, and surviving its absence
# ---------------------------------------------------------------------------

def _docker(args, timeout=DOCKER_TIMEOUT):
    """(ok, stdout, reason). Never raises: the caller is a deleter."""
    env = dict(os.environ)
    env.setdefault("DOCKER_CLI_HINTS", "false")
    try:
        r = subprocess.run(["docker"] + list(args), capture_output=True,
                           text=True, timeout=timeout, env=env)
    except FileNotFoundError:
        return False, "", "docker is not installed"
    except subprocess.TimeoutExpired:
        return False, "", "docker did not answer within %ss" % timeout
    except OSError as e:
        return False, "", "docker could not be run (%s)" % e
    if r.returncode != 0:
        err = (r.stderr or "").strip().splitlines()
        detail = err[-1][:200] if err else "exit %d" % r.returncode
        return False, r.stdout, detail
    return True, r.stdout, ""


def docker_available():
    """(bool, reason). A daemon that is installed but not running is not
    available, and saying so is the whole of the degradation path."""
    ok, _out, why = _docker(["version", "--format", "{{.Server.Version}}"],
                            timeout=DOCKER_PROBE_TIMEOUT)
    if ok:
        return True, ""
    return False, why or "the docker daemon is not running"


# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------

def _real(p):
    try:
        return os.path.realpath(p)
    except OSError:
        return p or ""


def _within(child, parent):
    """child IS parent, or is inside it. Both already realpath'd."""
    if not child or not parent:
        return False
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


# ---------------------------------------------------------------------------
# the inventory
# ---------------------------------------------------------------------------

def inventory():
    """Every container on the machine, with labels, mounts, age and exact size.

    Returns {"available": bool, "reason": str, "containers": [...]}.
    One `docker ps -aq` and one `docker inspect --size`, because 30 separate
    inspects is 30 chances for a slow daemon to time out mid-sweep.
    """
    avail, why = docker_available()
    if not avail:
        return {"available": False, "reason": why, "containers": []}
    ok, out, why = _docker(["ps", "-aq"])
    if not ok:
        return {"available": False, "reason": why, "containers": []}
    ids = [i for i in out.split() if i]
    if not ids:
        return {"available": True, "reason": "", "containers": []}
    raw, why = _inspect_size(ids)
    if raw is None:
        return {"available": False, "reason": why, "containers": []}
    return {"available": True, "reason": "", "containers": [_container(c) for c in raw]}


def _inspect_size(ids):
    """(rows, "") or (None, why) — the inspected containers, or a reason.

    A CONTAINER THAT DISAPPEARS BETWEEN THE ps AND THE inspect IS NORMAL, AND
    IT IS NOT AN ERROR ABOUT THE OTHER CONTAINERS. `docker inspect` exits 1 if
    ANY id is gone while still printing every object it did find:

        docker inspect --size <alive> <removed>
        rc=1  stderr: error: no such object: b8405228de60...  stdout: 1 object

    Reading that exit code as the verdict threw the WHOLE inventory away
    because one container had finished — inventory() came back
    available=False with zero rows, so classify() reported nothing and the
    reaper deleted nothing. It failed silently and it failed EXACTLY WHEN THE
    MACHINE WAS BUSY, which is precisely when residue accumulates and when the
    reaping is worth having.

    Measured 2026-09-14: eight concurrent runs of containers.test.sh, with
    nothing mutated, went red 8 out of 8 at D1, D2, D3 and D6 — "the workspace
    landed and its container is still on the machine", "an unowned container
    must be REPORTED", 0 rows where 1 was expected. One engineer lost most of
    an evening to that signature believing it was his own code
    (esc-20260914T003636Z-ea530880), and it was never his code.

    So the verdict comes from the OUTPUT, not the status: whatever docker
    managed to describe is the answer, and only an unreadable or empty reply is
    a failure. --size is the slow flag and is still spent once for the whole
    machine.
    """
    ok, out, why = _docker(["inspect", "--size"] + list(ids))
    text = (out or "").strip()
    if not text:
        return None, (why or "docker inspect returned nothing")
    try:
        raw = json.loads(text)
    except ValueError as e:
        return None, "docker inspect was unreadable (%s)" % e
    if not isinstance(raw, list):
        return None, "docker inspect did not return a list of containers"
    return raw, ""


def _container(c):
    cfg = c.get("Config") or {}
    state = c.get("State") or {}
    labels = cfg.get("Labels") or {}
    mounts = []
    for m in c.get("Mounts") or []:
        if m.get("Type") == "bind" and m.get("Source"):
            mounts.append(m["Source"])
    return {
        "id": (c.get("Id") or "")[:12],
        "name": (c.get("Name") or "").lstrip("/"),
        "image": (cfg.get("Image") or c.get("Image") or "")[:80],
        "created": c.get("Created") or "",
        "created_epoch": _epoch(c.get("Created") or ""),
        "running": bool(state.get("Running")),
        "status": state.get("Status") or "",
        "finished": state.get("FinishedAt") or "",
        "size_rw": c.get("SizeRw") or 0,
        "size_root": c.get("SizeRootFs") or 0,
        "labels": labels,
        "binds": mounts,
    }


def _epoch(ts):
    """Docker's RFC3339 with nanoseconds, without pulling in a date library.

    calendar.timegm, NOT time.mktime: Docker stamps UTC, and mktime reads a
    struct as LOCAL time. The correction `mktime(t) - time.timezone` looks
    right and is wrong under daylight saving, because time.timezone is the
    standard-time offset — measured here in BST, a container three seconds old
    reported an age of `1h`. An age is half of what the orphan report owes the
    reader, so an hour of drift is not cosmetic.
    """
    if not ts:
        return 0
    t = ts.strip().rstrip("Z")
    if "." in t:
        t = t.split(".", 1)[0]
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return int(calendar.timegm(time.strptime(t, fmt)))
        except ValueError:
            continue
    return 0


# ---------------------------------------------------------------------------
# ownership
# ---------------------------------------------------------------------------

def owner_claims(container):
    """Every ownership signal on one container, strongest first.

    [(path, kind)] with kind in "label" | "compose" | "mount". A container can
    carry several — richos-ci86 binds a live workspace AND the main checkout —
    so this returns all of them and the caller decides. `declared` is the half
    that may authorize a deletion.
    """
    out = []
    labels = container.get("labels") or {}
    explicit = (labels.get(WORKSPACE_LABEL) or "").strip()
    if explicit:
        out.append((_real(explicit), "label"))
    compose_dir = (labels.get(COMPOSE_DIR_LABEL) or "").strip()
    if compose_dir:
        out.append((_real(compose_dir), "compose"))
    for b in container.get("binds") or []:
        out.append((_real(b), "mount"))
    return out


def declared_owner(container):
    """(path, kind) or (None, None). ONLY a declaration authorizes deletion."""
    for path, kind in owner_claims(container):
        if kind in ("label", "compose"):
            return path, kind
    return None, None


def docker_run_args(workspace_path):
    """The label arguments a container created for a workspace must carry.

    Handed out rather than documented, so that no caller invents a second
    spelling of the thing the reaper greps for:

        docker run $(containers.sh label-args) ...
    """
    return ["--label", "%s=%s" % (WORKSPACE_LABEL, _real(workspace_path))]


# ---------------------------------------------------------------------------
# who is alive
# ---------------------------------------------------------------------------

def live_workspace_paths():
    """(paths, ok, reason) — every workspace the engine currently holds live.

    Asked of workspaces.py, which is the authority. `ok` false means liveness
    could not be established, and the sweep then protects everything: an
    unreadable record is a reason to keep your hands still.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import workspaces  # noqa: F401  (same directory, guarded by __main__)
    except Exception as e:                                  # pragma: no cover
        return set(), False, "scripts/lib/workspaces.py could not be read (%s)" % e
    paths = set()
    try:
        for rec in workspaces.all_agents():
            for w in workspaces.live_workspaces(rec):
                if w.get("path"):
                    paths.add(_real(w["path"]))
    except Exception as e:
        return set(), False, "the workspace records could not be read (%s)" % e
    return paths, True, ""


# ---------------------------------------------------------------------------
# the sweep
# ---------------------------------------------------------------------------

def classify(containers=None, live=None, live_ok=True):
    """Split the machine into what is protected, what is orphaned, and why.

    protected  — owned by a LIVE workspace, by ANY evidence. Never touched.
    orphaned   — carries a DECLARED owner that is not a live workspace. Agent
                 residue, almost certainly. Reported, never deleted here; it
                 is deleted only by reap_for_workspaces at its owner's end.
    unowned    — no ownership evidence at all. rl55, rlx, buzz-prod-*. Most
                 likely a person's. Reported so it is visible, and that is all.
    """
    if containers is None:
        inv = inventory()
        if not inv["available"]:
            return {"available": False, "reason": inv["reason"],
                    "protected": [], "orphaned": [], "unowned": []}
        containers = inv["containers"]
    if live is None:
        live, live_ok, _why = live_workspace_paths()
    protected, orphaned, unowned = [], [], []
    for c in containers:
        claims = owner_claims(c)
        alive = None
        for path, kind in claims:
            if any(_within(path, w) for w in live):
                alive = (path, kind)
                break
        if alive:
            c = dict(c, owner=alive[0], evidence=alive[1])
            protected.append(c)
            continue
        path, kind = declared_owner(c)
        if path:
            orphaned.append(dict(c, owner=path, evidence=kind,
                                 owner_exists=os.path.isdir(path)))
        else:
            unowned.append(dict(c, owner=None, evidence=None))
    return {"available": True, "reason": "", "live_known": live_ok,
            "protected": protected, "orphaned": orphaned, "unowned": unowned}


def reap_for_workspaces(paths, dry_run=False, ending=False):
    """POINT 9, FOR CONTAINERS. Called from the workspace deleter.

    Removes every container that DECLARES one of these workspaces as its owner.
    A container owned by any OTHER workspace is never a candidate at all: the
    named paths bound the whole operation.

    `ending` IS THE CALLER SAYING WHICH IT IS, AND IT IS NOT A FORMALITY.

      ending=True  — the deleter, mid-deletion. The workspace is still marked
        live in the record, because `deleted_at` is only set once removal
        succeeds, so its own liveness must not protect it from its own
        deletion. An earlier draft checked liveness unconditionally "belt and
        braces" and thereby refused the one case this exists for: D1 and D2
        failed with the container still on the machine after a real land.
      ending=False — anybody else, including `containers.sh reap` typed by
        hand. A live workspace's containers are then REFUSED and the reason is
        said out loud. Without this split the safe-looking default would be
        the dangerous one: a mistyped path would destroy a running agent's
        containers, and the mutation harness is what showed the check was not
        doing this job.

    Never raises. Returns a result dict; on a machine without Docker it is
    {"available": False, ...} and the land proceeds exactly as before.

    Never raises. Returns a result dict; on a machine without Docker it is
    {"available": False, ...} and the land proceeds exactly as before.
    """
    result = {"available": False, "reason": "", "removed": [], "failed": [],
              "kept": [], "considered": 0}
    try:
        paths = [_real(p) for p in (paths or []) if p]
        if not paths:
            result["reason"] = "no workspace paths given"
            return result
        inv = inventory()
        if not inv["available"]:
            result["reason"] = inv["reason"]
            return result
        result["available"] = True
        live, _ok, _why = live_workspace_paths()
        if ending:
            # The deleter's own workspaces are exempt from their own liveness:
            # the record still calls them live until the directory is gone.
            # Every OTHER workspace in the set keeps its full protection.
            live = {w for w in live if not any(_within(w, p) for p in paths)}
        for c in inv["containers"]:
            owner, kind = declared_owner(c)
            if not owner or not any(_within(owner, p) for p in paths):
                continue
            result["considered"] += 1
            # Owned by a workspace that is still live: never touched. With
            # ending=True that can only be a DIFFERENT workspace nested in the
            # one being deleted; with ending=False it is the hand-typed reap
            # aimed at a workspace somebody is still working in.
            if any(_within(owner, w) for w in live):
                result["kept"].append({"name": c["name"], "owner": owner,
                                       "why": "its workspace is still registered as live"})
                continue
            if dry_run:
                result["removed"].append({"name": c["name"], "id": c["id"],
                                          "owner": owner, "evidence": kind,
                                          "bytes": c["size_rw"], "dry_run": True})
                continue
            # -f because the workspace is gone: a running container of a dead
            # workspace is the exact residue this exists to remove. -v drops
            # only the container's own anonymous volumes, never a named one.
            ok, _out, why = _docker(["rm", "-f", "-v", c["id"]],
                                    timeout=DOCKER_REMOVE_TIMEOUT)
            if ok:
                result["removed"].append({"name": c["name"], "id": c["id"],
                                          "owner": owner, "evidence": kind,
                                          "bytes": c["size_rw"]})
            else:
                result["failed"].append({"name": c["name"], "id": c["id"],
                                         "why": why})
    except Exception as e:                                  # pragma: no cover
        # A deleter must not be broken by its own tidying-up.
        result["reason"] = "container reap failed harmlessly (%s)" % e
    return result


# ---------------------------------------------------------------------------
# reclaimable, reported and never spent
# ---------------------------------------------------------------------------

def reclaimable():
    """What `docker system df` says is recoverable. REPORTED, NEVER ACTED ON."""
    ok, out, why = _docker(["system", "df", "--format", "{{json .}}"])
    if not ok:
        return {"available": False, "reason": why, "rows": []}
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return {"available": True, "reason": "", "rows": rows}


# ---------------------------------------------------------------------------
# saying it
# ---------------------------------------------------------------------------

def human_bytes(n):
    n = float(n or 0)
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if abs(n) < 1000.0:
            return "%.0f%s" % (n, unit) if unit == "B" else "%.2f%s" % (n, unit)
        n /= 1000.0
    return "%.2fPB" % n


def human_age(epoch):
    if not epoch:
        return "unknown age"
    s = max(0, int(time.time() - epoch))
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        return "%dh" % (s // 3600)
    return "%dd" % (s // 86400)


def _line(c):
    return "    %-34s %-26s %8s  %6s old  %s" % (
        c["name"][:34], c["image"][:26], human_bytes(c["size_rw"]),
        human_age(c["created_epoch"]),
        ("running" if c["running"] else c["status"] or "stopped"))


def report(stream=sys.stdout):
    """The orphan report: what is here, who owns it, what it costs.

    Exit-code-free by design — this is a notice, not a gate. Nothing it prints
    has been deleted by printing it.
    """
    st = classify()
    if not st["available"]:
        stream.write("containers: not checked — %s\n" % st["reason"])
        return 0
    if not st.get("live_known", True):
        stream.write("containers: LIVENESS UNKNOWN — everything is being treated as\n"
                     "  protected, and nothing would be reaped until the record is readable.\n")
    n = len(st["protected"]) + len(st["orphaned"]) + len(st["unowned"])
    stream.write("containers: %d on this machine\n" % n)
    if st["protected"]:
        stream.write("  owned by a LIVE workspace — never touched (%d):\n" % len(st["protected"]))
        for c in sorted(st["protected"], key=lambda x: x["created_epoch"]):
            stream.write(_line(c) + "\n")
            stream.write("        owner: %s  (by %s)\n" % (c["owner"], c["evidence"]))
    if st["orphaned"]:
        total = sum(c["size_rw"] for c in st["orphaned"])
        stream.write("  declare a directory that is NOT a live workspace, %s in total.\n"
                     "  REPORTED, NOT DELETED. Some of these are dead agent worktrees and\n"
                     "  will be reaped if their owner is ever landed or discarded; the rest\n"
                     "  are ordinary compose projects in someone's repository, whose owner\n"
                     "  will never be a workspace and which nothing here will ever remove.\n"
                     "  The two are told apart by the owner line, not by a guess (%d):\n"
                     % (human_bytes(total), len(st["orphaned"])))
        for c in sorted(st["orphaned"], key=lambda x: x["created_epoch"]):
            stream.write(_line(c) + "\n")
            stream.write("        owner: %s  (by %s, %s)\n"
                         % (c["owner"], c["evidence"],
                            "still on disk" if c["owner_exists"] else "gone from disk"))
    if st["unowned"]:
        total = sum(c["size_rw"] for c in st["unowned"])
        stream.write("  no ownership evidence — most likely started by hand, %s in total.\n"
                     "  NEVER deleted by this engine (%d):\n"
                     % (human_bytes(total), len(st["unowned"])))
        for c in sorted(st["unowned"], key=lambda x: x["created_epoch"]):
            stream.write(_line(c) + "\n")
    df = reclaimable()
    if df["available"] and df["rows"]:
        stream.write("  docker system df says this is reclaimable. It is HIS call, not a\n"
                     "  script's — nothing here runs a prune:\n")
        for row in df["rows"]:
            rec = row.get("Reclaimable") or ""
            if rec and not rec.startswith("0B"):
                stream.write("    %-14s %s\n" % (row.get("Type", "?"), rec))
    return 0


# ---------------------------------------------------------------------------

def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="containers.sh", add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("status", help="every container, who owns it, what it costs")
    sub.add_parser("label-args", help="the label a container for this workspace must carry")
    r = sub.add_parser("reap", help="remove the containers an ENDED workspace declared")
    r.add_argument("--workspace", action="append", default=[], required=True)
    r.add_argument("--dry-run", action="store_true")
    # Deliberately not offered on the command line. `ending` says "this
    # workspace is being deleted by me, right now", which is true of the
    # deleter and of nothing a person types. A hand-run reap aimed at a live
    # workspace removes nothing and says why.
    la = ap.parse_args(argv)
    if la.cmd == "reap":
        res = reap_for_workspaces(la.workspace, dry_run=la.dry_run)
        if not res["available"]:
            sys.stdout.write("containers: nothing reaped — %s\n" % (res["reason"] or "docker unavailable"))
            return 0
        for x in res["removed"]:
            sys.stdout.write("%s %s (%s, owner %s by %s)\n"
                             % ("would remove" if x.get("dry_run") else "removed",
                                x["name"], human_bytes(x["bytes"]), x["owner"], x["evidence"]))
        for x in res["kept"]:
            sys.stdout.write("kept %s — %s\n" % (x["name"], x["why"]))
        for x in res["failed"]:
            sys.stdout.write("FAILED to remove %s — %s\n" % (x["name"], x["why"]))
        if not res["removed"] and not res["kept"] and not res["failed"]:
            sys.stdout.write("containers: none declared by that workspace\n")
        return 0
    if la.cmd == "label-args":
        cwd = os.getcwd()
        sys.stdout.write(" ".join(docker_run_args(cwd)) + "\n")
        return 0
    return report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
