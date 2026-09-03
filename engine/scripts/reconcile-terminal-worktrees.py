#!/usr/bin/env python3
"""reconcile-terminal-worktrees.py — THE PERSISTENT RECONCILER. Drives every
terminal worktree transaction from `quarantined` to `removed`, and recovers
any transaction a crash left mid-way, from the durable state alone.

===========================================================================
WHAT IT DOES, PER TERMINAL TRANSACTION, PER MEMBER
===========================================================================
    bound        -> ref_saved      (the ingress normally did this; recovery)
    ref_saved    -> quarantined    (same)
    quarantined  -> captured       kill and reap every process using the
                                   original or the quarantine; require two
                                   identical manifests separated by a
                                   settling interval; archive raw bytes +
                                   index + provenance; reclaim a recreated
                                   original path
    captured     -> verified       re-read the archive and match every digest
    verified     -> unregistered   git no longer lists the worktree (the
                                   backup ref is untouched)
    unregistered -> removed        the quarantine directory is gone
The transaction is `removed` only when every member is. Every transition is
persisted immediately (scripts/lib/worktree-transactions.py, temp file ->
fsync -> rename -> directory fsync), so a crash at ANY boundary is recovered
by rereading what exists and repeating only the idempotent step that follows.

===========================================================================
WHAT IS CAPTURED — and why "git tree equality" is not claimed
===========================================================================
For every quarantined member the archive holds:
  - the member's HEAD under the backup ref (already in the repository);
  - `index.txt`: exact index entries (`git ls-files -s`), and every staged
    blob's bytes under blobs/<sha>;
  - `tree.tar`: raw working-tree bytes of every file that is not on the
    disposable-path policy (tracked or not, ignored or not), with modes and
    symlink targets;
  - `manifest.json`: relpath, kind, size, mode, symlink target, SHA-256 of
    every raw file — computed twice, before and after the settle, and the
    two must be identical;
  - `provenance.json`: repository, original path, branch, HEAD, backup ref,
    the transaction's session and agent ids.
Raw files and index blobs are hashed independently. Git clean filters, LFS
and line-ending conversion can make a git tree differ from the bytes on
disk, so the archive is verified against the RAW digests, and a git tree id
is never presented as byte equality.

The disposable-path policy is COMMITTED (orchestration.config
CAPTURE_DISPOSABLE_PATHS in the engine, overridable per entity): build
outputs and dependency caches are the only things not captured, and the
list is data a reviewer can read.

VERIFICATION covers every manifest entry — file size/mode/digest, symlink
mode/target, directory mode, no extra entries — and every index entry that
needs a standalone blob (`needs_blob`: its object is not in the HEAD tree
the backup ref preserves) must have one that hashes to it under the
repository's object format. Any failure voids the capture and the member
returns to `quarantined`. Every git command the capture needs must succeed
or the member is not `captured` (review 2026-09-03, blockers 2 and 8).

PRIVACY AND RETENTION: capture directories are 0700 and files 0600, by
explicit mode and by a 0077 umask over this process; the archive is deleted
after CAPTURE_RETENTION_DAYS, the backup ref after BACKUP_REF_RETENTION_DAYS,
the transaction record after TRANSACTION_RETENTION_DAYS and only once every
artifact it names is gone — all of it in retention_pass(), run at the end of
every run, so the launchd job does it and nobody is asked to. The encryption
policy (permissions + retention + the volume's encryption; no per-archive
key, and why) is in docs/worktree-lifecycle-transactions.md.

===========================================================================
PROCESS RESIDUE — what is handled and what is honestly not
===========================================================================
Before capture, every process whose cwd or open files resolve inside the
original or the quarantine is terminated (SIGTERM, then SIGKILL) and reaped;
then the manifest is taken twice with a settle between. A process that
recreates the ORIGINAL path after quarantine is detected: its writers are
killed, the residue is captured as `residue-<n>.tar` and removed.

What cannot be removed by shell code: a detached process with no current
filesystem reference that has remembered an absolute path and will write
again later. Absolute prevention needs the platform to run each worker in an
OS-owned job and end the job before cleanup. This reconciler handles
OBSERVED residue and does not claim more.

===========================================================================
FAILURE POLICY
===========================================================================
Normal failures (disk full, an archive that did not verify, a member whose
manifest would not settle) leave the quarantine exactly where it is, record
the attempt count and the last error on the member, and are retried
silently on the next run. A member that reaches `failed` or `missing`
(both-present, provenance contradicts git, vanished) is a HARD failure:
reported once (a marker file beside the transaction), never retried
automatically, and COUNTED as dead-present by `--status` until an operator
resolves it. Nothing here searches for something with a similar name.

===========================================================================
WHO RUNS IT
===========================================================================
launchd (com.richos.worktree-reconciler, installed by scripts/hooks/install.sh)
every RECONCILE_INTERVAL_SECONDS; and SessionStart
(session-start-reap-worktrees.sh) as crash recovery with a short time
budget. SessionStart is not the scheduler. Nothing waits for a later session.

Usage:
  reconcile-terminal-worktrees.py                run every pending transaction
  reconcile-terminal-worktrees.py --status       print the definition-of-done
                                                 metrics as JSON and exit 0/1
  reconcile-terminal-worktrees.py --max-seconds N  stop cleanly after N seconds
  reconcile-terminal-worktrees.py --agent SID/AID  one transaction only
Env (tests): RICHOS_WORKTREE_TX_DIR, RICHOS_WORKTREE_CAPTURE_DIR,
RICHOS_RECONCILE_SETTLE (seconds, default 1.0), RICHOS_RECONCILE_NO_KILL=1.
"""

import argparse
import hashlib
import importlib.util
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tx = _load("worktree_transactions", os.path.join(HERE, "lib", "worktree-transactions.py"))

DEFAULT_DISPOSABLE = "node_modules .venv venv target build dist .gradle .next .turbo __pycache__ .pytest_cache .DS_Store .cache"
MAX_SOFT_ATTEMPTS_BEFORE_NOTICE = 12


def log(msg):
    sys.stderr.write("reconcile: %s\n" % msg)


def config_value(key, default, repo=None):
    """One committed setting: the entity's orchestration.config if it
    declares it, else the engine's, else the default. Data a reviewer can
    read, never a constant hidden in code."""
    for cfg in ([os.path.join(repo, "orchestration.config")] if repo else []) + [os.path.join(HERE, "..", "orchestration.config")]:
        try:
            with open(cfg, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith(key + "="):
                        return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    return default


def disposable_paths(repo):
    """The committed disposable-path policy: the entity's orchestration.config
    if it declares one, else the engine's, else the default above."""
    return set(config_value("CAPTURE_DISPOSABLE_PATHS", DEFAULT_DISPOSABLE, repo).split())


def pending_terminal_grace():
    """Seconds a pending terminal event waits for the seal it needs before the
    reconciler routes the agent's creation-time members through cleanup
    without it. Env override for tests: RICHOS_PENDING_TERMINAL_GRACE."""
    v = os.environ.get("RICHOS_PENDING_TERMINAL_GRACE")
    if v is None or v == "":
        v = config_value("PENDING_TERMINAL_GRACE_SECONDS", "600")
    try:
        return float(v)
    except ValueError:
        return 600.0


# --------------------------------------------------------------------------
# manifests
# --------------------------------------------------------------------------

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def build_manifest(root, disposable):
    """{relpath: {kind, size, mode, sha256|target}} over every non-disposable
    entry. `.git` (the worktree pointer file) is included as data."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir
        keep = []
        for d in dirnames:
            rel = os.path.join(rel_dir, d) if rel_dir else d
            if d in disposable or rel in disposable:
                continue
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                out[rel] = {"kind": "symlink", "target": os.readlink(full), "mode": os.lstat(full).st_mode & 0o7777}
                continue
            keep.append(d)
            out[rel] = {"kind": "dir", "mode": os.lstat(full).st_mode & 0o7777}
        dirnames[:] = keep
        for fn in filenames:
            rel = os.path.join(rel_dir, fn) if rel_dir else fn
            if fn in disposable or rel in disposable:
                continue
            full = os.path.join(dirpath, fn)
            st = os.lstat(full)
            if os.path.islink(full):
                out[rel] = {"kind": "symlink", "target": os.readlink(full), "mode": st.st_mode & 0o7777}
            elif os.path.isfile(full):
                out[rel] = {"kind": "file", "size": st.st_size, "mode": st.st_mode & 0o7777, "sha256": sha256_file(full)}
            else:
                out[rel] = {"kind": "other", "mode": st.st_mode & 0o7777}
    return out


# --------------------------------------------------------------------------
# processes
# --------------------------------------------------------------------------

def processes_using(paths):
    """pids whose cwd or open files resolve inside any of the given paths
    (lsof, the measured tool that sees a cwd `pgrep -f` cannot), plus pids
    whose argv names one of them. Never this process or its parents."""
    pids = set()
    existing = [p for p in paths if p and os.path.exists(p)]
    if not existing:
        return pids
    try:
        res = subprocess.run(["lsof", "-t"] + sum([["+D", p] for p in existing], []),
                             capture_output=True, text=True, timeout=60)
        for tok in res.stdout.split():
            if tok.isdigit():
                pids.add(int(tok))
    except Exception:
        pass
    try:
        res = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=20)
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit() and any(p in parts[1] for p in existing):
                pids.add(int(parts[0]))
    except Exception:
        pass
    me = os.getpid()
    ancestors = set()
    p = os.getppid()
    for _ in range(6):
        if p <= 1:
            break
        ancestors.add(p)
        try:
            r = subprocess.run(["ps", "-o", "ppid=", "-p", str(p)], capture_output=True, text=True, timeout=5)
            p = int(r.stdout.strip() or "1")
        except Exception:
            break
    return {x for x in pids if x != me and x not in ancestors}


def kill_and_reap(pids, grace=2.0):
    if not pids or os.environ.get("RICHOS_RECONCILE_NO_KILL") == "1":
        return list(pids)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + grace
    while time.time() < deadline:
        if all(not _alive(p) for p in pids):
            return []
        time.sleep(0.1)
    for pid in pids:
        if _alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    time.sleep(0.2)
    return [p for p in pids if _alive(p)]


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


# --------------------------------------------------------------------------
# capture
# --------------------------------------------------------------------------

def capture_dir(t, index):
    return os.path.join(tx.capture_root(), tx._seg(t["session_id"], "session_id"),
                        tx._seg(t["agent_id"], "agent_id"), "member-%d" % index)


def private_makedirs(path):
    """Create every missing component and pin EVERY component from the
    capture root down to 0700, whether or not it already existed (blocker 8:
    the archive holds ignored evidence). os.makedirs applies `mode` to the
    leaf only; intermediate directories take the ambient umask."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    root = os.path.realpath(tx.capture_root())
    p = os.path.realpath(path)
    while p.startswith(root):
        os.chmod(p, 0o700)
        if p == root:
            break
        p = os.path.dirname(p)


def private_open(path):
    """A NEW file, 0600 from its first byte, whatever the ambient umask."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    return os.fdopen(fd, "wb")


def git_out(cwd, *args):
    r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr


def git_must(cwd, *args):
    """stdout of a git command that MUST succeed; a nonzero exit raises a
    normal (retryable) failure naming the command (blocker 2)."""
    rc, out, err = git_out(cwd, *args)
    if rc != 0:
        raise RuntimeError("git %s failed in %s (rc %d): %s" % (" ".join(args[:2]), cwd, rc, err.strip()[:200]))
    return out


def capture_member(t, index):
    """quarantined -> captured. Raises on a NORMAL (retryable) failure."""
    m = t["members"][index]
    quar = m.get("quarantine")
    orig = m["path"]
    if not quar or not os.path.isdir(quar):
        raise RuntimeError("quarantine %s is not present" % quar)
    settle = float(os.environ.get("RICHOS_RECONCILE_SETTLE") or "1.0")
    disposable = disposable_paths(m.get("repo"))

    # 1. a recreated ORIGINAL path is residue: its writers are killed, its
    #    bytes kept as residue-<n>.tar, and it is removed.
    residue_n = int(m.get("residue_count") or 0)
    if os.path.lexists(orig):
        left = kill_and_reap(processes_using([orig]))
        if left:
            raise RuntimeError("processes still using the recreated original %s: %s" % (orig, left))
        residue_n += 1
        cdir = capture_dir(t, index)
        private_makedirs(cdir)
        rpath = os.path.join(cdir, "residue-%d.tar" % residue_n)
        if os.path.isdir(orig) and not os.path.islink(orig):
            with private_open(rpath) as raw, tarfile.open(fileobj=raw, mode="w") as tar:
                tar.add(orig, arcname="residue")
            shutil.rmtree(orig)
        else:
            os.unlink(orig)
        tx.update_member(t["session_id"], t["agent_id"], index, residue_count=residue_n,
                         residue_last=rpath)
        log("reclaimed residue at the original path %s -> %s" % (orig, rpath))

    # 2. writers inside the quarantine are terminated and reaped
    left = kill_and_reap(processes_using([quar]))
    if left:
        raise RuntimeError("processes still using %s after SIGKILL: %s" % (quar, left))

    # 3. two identical manifests, separated by the settle
    man_a = build_manifest(quar, disposable)
    time.sleep(settle)
    man_b = build_manifest(quar, disposable)
    if man_a != man_b:
        raise RuntimeError("the quarantine changed during the settle interval; something is still writing to %s" % quar)

    # 4. archive: raw tree, index entries + staged blobs, provenance. Every
    #    directory and file is created PRIVATE (0700 / 0600): the archive holds
    #    ignored evidence, which is where secrets live (blocker 8).
    cdir = capture_dir(t, index)
    private_makedirs(cdir)
    tree_tar = os.path.join(cdir, "tree.tar")
    tmp_tar = tree_tar + ".tmp"
    if os.path.exists(tmp_tar):
        os.unlink(tmp_tar)
    with private_open(tmp_tar) as raw, tarfile.open(fileobj=raw, mode="w") as tar:
        for rel in sorted(man_a):
            full = os.path.join(quar, rel)
            info = man_a[rel]
            if info["kind"] == "file":
                tar.add(full, arcname=rel, recursive=False)
            elif info["kind"] == "symlink":
                ti = tarfile.TarInfo(rel); ti.type = tarfile.SYMTYPE; ti.linkname = info["target"]; ti.mode = info["mode"]
                tar.addfile(ti)
            elif info["kind"] == "dir":
                ti = tarfile.TarInfo(rel); ti.type = tarfile.DIRTYPE; ti.mode = info["mode"]
                tar.addfile(ti)
        raw.flush(); os.fsync(raw.fileno())
    os.replace(tmp_tar, tree_tar)

    # THE INDEX, EXACTLY, OR NOT `captured` AT ALL (review 2026-09-03,
    # blocker 2). Every git command needed for provenance or index capture
    # must succeed; a failure raises, which keeps the member `quarantined`
    # with the quarantine on disk and the attempt counted — retryable, and
    # never a permission to delete. A failed `ls-files` used to be recorded
    # as an empty index with the return code tucked into provenance, and the
    # member still advanced: staged-only state would then have been deleted
    # on the strength of an archive that never held it.
    object_format = git_must(quar, "rev-parse", "--show-object-format").strip() or "sha1"
    index_entries = []
    for rec in git_must(quar, "ls-files", "-s", "-z").split("\0"):
        if not rec:
            continue
        meta, _tab, path = rec.partition("\t")
        parts = meta.split()
        if len(parts) < 3 or not _tab:
            raise RuntimeError("unparseable ls-files -s record %r" % rec[:80])
        index_entries.append({"mode": parts[0], "sha": parts[1], "stage": parts[2], "path": path})
    # Which entries need a STANDALONE blob: every one whose object is not in
    # the HEAD tree the backup ref already preserves. Recorded on the entry,
    # so verification can require exactly those files and no fewer.
    head = tx.head_of(quar)
    if not head:
        raise RuntimeError("HEAD of %s is unreadable" % quar)
    head_objects = set()
    for rec in git_must(quar, "ls-tree", "-r", "-z", head).split("\0"):
        if rec:
            meta = rec.partition("\t")[0].split()
            if len(meta) >= 3:
                head_objects.add(meta[2])
    blobs_dir = os.path.join(cdir, "blobs")
    private_makedirs(blobs_dir)
    for e in index_entries:
        e["needs_blob"] = e["mode"] != "160000" and e["sha"] not in head_objects
        if not e["needs_blob"]:
            continue
        bpath = os.path.join(blobs_dir, e["sha"])
        if os.path.exists(bpath) and git_object_id(bpath, object_format) == e["sha"]:
            continue
        r = subprocess.run(["git", "-C", quar, "cat-file", "blob", e["sha"]], capture_output=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError("git cat-file blob %s failed in %s: %s" % (e["sha"], quar, r.stderr.decode("utf-8", "replace").strip()[:200]))
        if os.path.exists(bpath + ".tmp"):
            os.unlink(bpath + ".tmp")
        with private_open(bpath + ".tmp") as f:
            f.write(r.stdout); f.flush(); os.fsync(f.fileno())
        os.replace(bpath + ".tmp", bpath)
        if git_object_id(bpath, object_format) != e["sha"]:
            raise RuntimeError("captured blob %s does not hash to its index entry (%s)" % (bpath, object_format))
    status_txt = git_must(quar, "status", "--porcelain", "--ignored", "-z")
    prov = {"repo": m.get("repo"), "original_path": orig, "quarantine": quar, "branch": m.get("branch"),
            "head": head, "head_at_seal": m.get("head_at_seal"), "backup_ref": m.get("backup_ref"),
            "session_id": t["session_id"], "agent_id": t["agent_id"], "teammate": t.get("teammate"),
            "captured_ts": tx.now_iso(), "disposable_paths": sorted(disposable),
            "object_format": object_format, "index_entries": len(index_entries),
            "standalone_blobs": sum(1 for e in index_entries if e["needs_blob"]),
            "unarchivable_entries": sorted(k for k, v in man_a.items() if v["kind"] == "other"),
            "git_status_porcelain_ignored_z": status_txt}
    tx.atomic_write_json(os.path.join(cdir, "manifest.json"), man_a)
    tx.atomic_write_json(os.path.join(cdir, "index.json"), index_entries)
    tx.atomic_write_json(os.path.join(cdir, "provenance.json"), prov)
    # PROVENANCE MUST AGREE WITH GIT. A quarantine whose HEAD moved away from
    # the backup ref, or whose branch is not the bound one, is a hard failure.
    if m.get("head") and head and head != m.get("head"):
        return tx.update_member(t["session_id"], t["agent_id"], index, state="failed",
                                error="HEAD of the quarantine (%s) is not the HEAD the backup ref saved (%s)" % (head, m.get("head")))
    return tx.update_member(t["session_id"], t["agent_id"], index, state="captured", capture_dir=cdir,
                            captured_files=len([k for k, v in man_a.items() if v["kind"] == "file"]))


class ArchiveMismatch(RuntimeError):
    """The archive does not match its manifest, or the quarantine moved on
    since capture. Either way the capture is void: the member goes BACK to
    quarantined and is captured again on the next run. A void archive is
    never retried as-is, and never authorizes deletion."""


def verify_member(t, index):
    """captured -> verified: the archive is re-read and every digest matched."""
    m = t["members"][index]
    cdir = m.get("capture_dir")
    if not cdir or not os.path.isdir(cdir):
        raise ArchiveMismatch("capture directory %s is not present" % cdir)
    try:
        _verify_archive(m, cdir)
    except ArchiveMismatch as e:
        tx.update_member(t["session_id"], t["agent_id"], index, state="quarantined",
                         capture_dir=None, void_captures=int(m.get("void_captures") or 0) + 1)
        raise RuntimeError("%s — the capture is void; re-capturing on the next run" % e)
    return tx.update_member(t["session_id"], t["agent_id"], index, state="verified",
                            verified_ts=tx.now_iso(), verified_files=m.get("captured_files"))


def _verify_archive(m, cdir):
    """EVERY manifest entry against the archive — type, mode, symlink target,
    size and digest — and every index entry that needs a standalone blob
    against a blob that exists and hashes to it (review 2026-09-03, blockers
    2 and 8). Until this revision only regular-file bytes were compared:
    symlink targets, file and directory modes and entry completeness were
    never checked, and a staged blob was verified only if its file happened
    to exist."""
    manifest = tx.read_json(os.path.join(cdir, "manifest.json"))
    index = tx.read_json(os.path.join(cdir, "index.json"))
    prov = tx.read_json(os.path.join(cdir, "provenance.json"))
    if not isinstance(manifest, dict) or not isinstance(index, list) or not isinstance(prov, dict):
        raise ArchiveMismatch("manifest.json, index.json or provenance.json is missing or unreadable")
    object_format = prov.get("object_format") or "sha1"
    try:
        tar = tarfile.open(os.path.join(cdir, "tree.tar"), "r")
    except Exception as e:
        raise ArchiveMismatch("tree.tar unreadable: %s" % e)
    with tar:
        entries = {}
        for ti in tar:
            name = ti.name.rstrip("/")
            if name in entries:
                raise ArchiveMismatch("archive holds %s twice" % name)
            entries[name] = ti
        for rel, info in manifest.items():
            kind = info.get("kind")
            if kind == "other":
                continue   # declared unarchivable (fifo, socket, device) and listed in provenance
            ti = entries.pop(rel, None)
            if ti is None:
                raise ArchiveMismatch("manifest names %s (%s) which the archive lacks" % (rel, kind))
            if (ti.mode & 0o7777) != info.get("mode"):
                raise ArchiveMismatch("mode mismatch for %s: archive %o, manifest %o" % (rel, ti.mode & 0o7777, info.get("mode") or 0))
            if kind == "file":
                if not ti.isreg():
                    raise ArchiveMismatch("type mismatch for %s: manifest file, archive %s" % (rel, _tar_kind(ti)))
                h = hashlib.sha256()
                f = tar.extractfile(ti)
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
                if h.hexdigest() != info.get("sha256") or ti.size != info.get("size"):
                    raise ArchiveMismatch("digest mismatch for %s" % rel)
            elif kind == "symlink":
                if not ti.issym():
                    raise ArchiveMismatch("type mismatch for %s: manifest symlink, archive %s" % (rel, _tar_kind(ti)))
                if ti.linkname != info.get("target"):
                    raise ArchiveMismatch("symlink target mismatch for %s: archive %r, manifest %r" % (rel, ti.linkname, info.get("target")))
            elif kind == "dir":
                if not ti.isdir():
                    raise ArchiveMismatch("type mismatch for %s: manifest dir, archive %s" % (rel, _tar_kind(ti)))
            else:
                raise ArchiveMismatch("manifest entry %s has unknown kind %r" % (rel, kind))
        if entries:
            raise ArchiveMismatch("archive holds %s which the manifest does not name" % sorted(entries)[0])
    # the quarantine's live digests must STILL match: nothing wrote since capture
    disposable = disposable_paths(m.get("repo"))
    live = build_manifest(m["quarantine"], disposable)
    if live != manifest:
        raise ArchiveMismatch("the quarantine changed after capture")
    # every index entry that needs a standalone blob has one, and it hashes
    # to the entry under the repository's object format
    for e in index:
        if not e.get("needs_blob"):
            continue
        bpath = os.path.join(cdir, "blobs", e["sha"])
        if not os.path.isfile(bpath):
            raise ArchiveMismatch("staged blob %s for %s is missing from the archive" % (e["sha"], e.get("path")))
        if git_object_id(bpath, object_format) != e["sha"]:
            raise ArchiveMismatch("staged blob %s does not hash to its index entry" % e["sha"])


def _tar_kind(ti):
    return "file" if ti.isreg() else "symlink" if ti.issym() else "dir" if ti.isdir() else "other"


def git_object_id(path, object_format="sha1"):
    """The git object id of a blob file under the repository's object format
    — what `ls-files -s` recorded, so a captured blob can be checked against
    the index."""
    data = open(path, "rb").read()
    h = hashlib.sha256() if object_format == "sha256" else hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


def unregister_member(t, index):
    """verified -> unregistered: git no longer lists the worktree. The backup
    ref is never touched; the branch is left alone."""
    m = t["members"][index]
    quar = m.get("quarantine")
    repo = m.get("repo")
    if not repo:
        return tx.update_member(t["session_id"], t["agent_id"], index, state="failed", error="no repository recorded")
    ref = m.get("backup_ref")
    if ref and not tx.head_of(quar) and not _ref_exists(repo, ref):
        return tx.update_member(t["session_id"], t["agent_id"], index, state="failed",
                                error="backup ref %s is gone and the quarantine has no readable HEAD" % ref)
    reg = tx.registered_worktrees(repo) or {}
    if tx.norm_path(quar) in reg:
        rc, _, err = git_out(repo, "worktree", "remove", "--force", quar)
        if rc != 0:
            raise RuntimeError("git worktree remove --force %s failed: %s" % (quar, err.strip()[:200]))
    git_out(repo, "worktree", "prune")
    if ref and not _ref_exists(repo, ref):
        return tx.update_member(t["session_id"], t["agent_id"], index, state="failed",
                                error="backup ref %s vanished during unregistering" % ref)
    return tx.update_member(t["session_id"], t["agent_id"], index, state="unregistered")


def _ref_exists(repo, ref):
    rc, _, _ = git_out(repo, "rev-parse", "-q", "--verify", ref)
    return rc == 0


def remove_member(t, index):
    """unregistered -> removed: the quarantine directory is gone."""
    m = t["members"][index]
    quar = m.get("quarantine")
    if quar and os.path.lexists(quar):
        left = kill_and_reap(processes_using([quar]))
        if left:
            raise RuntimeError("processes still using %s: %s" % (quar, left))
        shutil.rmtree(quar)
    return tx.update_member(t["session_id"], t["agent_id"], index, state="removed", removed_ts=tx.now_iso())


STEPS = {
    "bound": lambda t, i: tx.save_ref(t["session_id"], t["agent_id"], i),
    "ref_saved": lambda t, i: tx.quarantine(t["session_id"], t["agent_id"], i),
    "quarantined": capture_member,
    "captured": verify_member,
    "verified": unregister_member,
    "unregistered": remove_member,
}


def reconcile_transaction(t, deadline=None):
    sid, aid = t["session_id"], t["agent_id"]
    with tx.tx_lock(sid, aid, timeout=5):
        for i in range(len(t.get("members") or [])):
            while True:
                if deadline and time.time() > deadline:
                    return
                t = tx.load_tx(sid, aid)
                m = t["members"][i]
                st = m.get("state")
                if st in ("removed", "failed", "missing"):
                    break
                step = STEPS.get(st)
                if step is None:
                    tx.update_member(sid, aid, i, state="failed", error="unknown state %r" % st)
                    break
                try:
                    t2 = step(t, i)
                except Exception as e:
                    attempts = int(m.get("attempts") or 0) + 1
                    tx.update_member(sid, aid, i, attempts=attempts, last_error=str(e)[:300], last_attempt=tx.now_iso())
                    if attempts == MAX_SOFT_ATTEMPTS_BEFORE_NOTICE:
                        notice_once(t, i, "still failing after %d attempts: %s" % (attempts, e))
                    log("member %s of %s/%s: %s (attempt %d, retrying later)" % (m.get("path"), sid[:8], aid, e, attempts))
                    break
                t = t2 if isinstance(t2, dict) else tx.load_tx(sid, aid)
                if t["members"][i].get("state") == st:
                    # No progress and no exception: the step declined to
                    # advance (a `git worktree repair` whose postcondition did
                    # not hold, blocker 6) and wrote why on the member. It is
                    # retried by the next run; after MAX attempts it is
                    # reported once, like any other soft failure.
                    m2 = t["members"][i]
                    if m2.get("last_error"):
                        attempts = int(m2.get("attempts") or 0)
                        if attempts == MAX_SOFT_ATTEMPTS_BEFORE_NOTICE:
                            notice_once(t, i, "still failing after %d attempts: %s" % (attempts, m2.get("last_error")))
                        log("member %s of %s/%s: %s (attempt %d, retrying later)" % (m2.get("path"), sid[:8], aid, m2.get("last_error"), attempts))
                    break
                if t["members"][i].get("state") in ("failed", "missing"):
                    notice_once(t, i, t["members"][i].get("error") or "hard failure")
                    break


def notice_once(t, index, msg):
    marker = tx.tx_path(t["session_id"], t["agent_id"]) + ".member-%d.notice" % index
    if os.path.exists(marker):
        return
    tx.touch_marker(marker, "%s\n%s\n" % (tx.now_iso(), msg))
    log("HARD FAILURE (reported once) %s/%s member %s: %s" % (t["session_id"][:8], t["agent_id"], t["members"][index].get("path"), msg))


def process_pending_terminals(only=None):
    """A terminal event recorded before its manifest sealed (review
    2026-09-03, blocker 4). For each: a transaction that is terminal consumed
    it; a sealed one is claimed and terminalized now (a crash between seal and
    claim); otherwise try_seal — which itself consumes the pending event when
    it succeeds. When nothing can seal and the grace period has passed, the
    agent's CREATION-TIME ownership — the bound record's prepared external
    members, verified against git exactly as the seal would have, plus the
    native member if a start fact names one that still verifies — becomes a
    fallback transaction that is claimed and terminalized like any other.
    Nothing is discovered by name; a member that no longer verifies is
    recorded and closed by policy, never guessed at.

    A PENDING RECORD WITH NO BOUND RECORD IS NOT "NOTHING WAS OWNED" (landed
    review 2026-09-03, blocker 2). A SubagentStart record can name the exact
    native path `.claude/worktrees/agent-<agent_id>`, and a WorktreeRemove
    can name it as first_path; either verifies through _verify_native_member
    (platform agent-id basename, exact registered worktree). That is
    precisely the path taken when SubagentStart succeeded but the parent's
    PostToolUse[Agent] binder failed — and until this revision the record
    was dropped there, with the native worktree left behind. Now the start
    fact and the first_path are inspected, a verified native member becomes
    a one-member fallback transaction, and an agent with NO verifiable
    member becomes a ZERO-member terminal transaction: the terminal event
    stands as a tombstone, the agent stays terminal, nothing on disk is
    touched, and the record is never reinterpreted as if it had not
    happened."""
    grace = pending_terminal_grace()
    handled = 0
    for sid, aid, p in list(tx.iter_pending_terminals()):
        if only and "%s/%s" % (sid, aid) != only:
            continue
        ppath = tx.pending_terminal_path(sid, aid)
        t = tx.load_tx(sid, aid)
        if t and t.get("terminal"):
            _unlink(ppath); continue
        if t and t.get("sealed"):
            tx.claim_terminal(sid, aid, p.get("ingress") or "SubagentStop", detail=p.get("detail") or "", via_pending=p)
            tx.terminalize(sid, aid, p.get("first_path") or None)
            _unlink(ppath); handled += 1; continue
        sealed, res = tx.try_seal(sid, aid)
        if sealed:
            handled += 1; continue
        age = time.time() - float(p.get("epoch") or 0)
        if age < grace:
            continue
        bound = tx.read_bound(sid, aid)
        start = tx.read_start(sid, aid)
        members = _creation_time_members(sid, aid, bound, start, p)
        fallback = {
            "record": "transaction", "session_id": sid, "agent_id": aid,
            "tool_use_id": (bound or {}).get("tool_use_id"), "teammate": (bound or {}).get("teammate") or "",
            "subagent_type": (bound or {}).get("subagent_type") or (start or {}).get("agent_type") or "",
            "kind": (bound or {}).get("kind") or ("native" if members else "unowned"),
            "members": members, "sealed": True, "sealed_ts": tx.now_iso(), "state": "sealed",
            "sealed_by": "pending-terminal-fallback", "seal_reason": str(res),
            "bound_record": bool(bound), "start_record": bool(start),
            "start_cwd": (start or {}).get("cwd_real") or "", "terminal": None,
        }
        with tx.tx_lock(sid, aid):
            if tx.load_tx(sid, aid) is None:
                tx.atomic_write_json(tx.tx_path(sid, aid), fallback)
        tx.claim_terminal(sid, aid, p.get("ingress") or "SubagentStop", detail=p.get("detail") or "", via_pending=p)
        tx.terminalize(sid, aid, p.get("first_path") or None)
        _unlink(ppath)
        if members:
            log("pending terminal for %s/%s: unsealable after %.0fs (%s); %d creation-time member(s) routed through cleanup%s"
                % (sid[:8], aid, age, res, len(members), "" if bound else " (no bound record: the native member came from the start fact / first_path, verified against git)"))
        else:
            log("pending terminal for %s/%s: unsealable after %.0fs (%s) and no verifiable member: closed as a ZERO-member terminal transaction — the terminal event stands, the agent stays terminal, nothing on disk was owned"
                % (sid[:8], aid, age, res))
        handled += 1
    return handled


def _creation_time_members(sid, aid, bound, start, p):
    """The exact members a pending terminal agent owned at creation time,
    verified against git as the seal would have — never discovered by name.

    External members come from the BOUND record's prepared set: one that
    still verifies is bound as-is; one whose directory is gone is bound
    absent (closed by the library's vanished-member policy); one that is
    still the exact prepared path inside the exact prepared repository but
    has drifted (branch, HEAD) is bound with the drift recorded, so its exact
    bytes are captured before anything is unregistered; a directory at the
    prepared path that is NOT a worktree of the prepared repository is not
    ours and is not touched.

    The native member comes from the START fact's cwd, else from the exact
    path a WorktreeRemove named (first_path) — blocker 2 — and only when
    _verify_native_member accepts it: platform `agent-<id>` basename, exact
    registered linked worktree. Nothing here needs a bound record."""
    members = []
    for e in (bound or {}).get("externals") or []:
        ext, why = tx._verify_external_member(e)
        if ext is not None:
            members.append(ext)
            continue
        real = tx.norm_path(e.get("path"))
        repo = tx.norm_path(e.get("repo"))
        if not os.path.isdir(real):
            members.append({"class": "hand-rolled", "repo": repo, "path": real, "branch": e.get("branch") or "",
                            "head_at_seal": "", "state": "bound", "prepared_but_absent": why})
            continue
        if tx.worktree_toplevel(real) == real and tx.main_checkout_of(real) == repo:
            members.append({"class": "hand-rolled", "repo": repo, "path": real, "branch": tx.branch_of(real) or e.get("branch") or "",
                            "head_at_seal": tx.head_of(real), "state": "bound", "provenance_drift": why})
            continue
        log("pending terminal for %s/%s: %s is not a worktree of the prepared repository %s (%s) — not owned, not touched"
            % (sid[:8], aid, real, repo, why))
    for cand in ((start or {}).get("cwd_real") or tx.norm_path((start or {}).get("cwd")), p.get("first_path") or ""):
        if not cand:
            continue
        nat, _why = tx._verify_native_member(tx.norm_path(cand), aid)
        if nat is not None:
            members.insert(0, nat)
            break
    return members


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


# --------------------------------------------------------------------------
# retention — automatic, persistent (it runs inside the launchd job), no user action
# --------------------------------------------------------------------------

def retention_days(key, default):
    """Days, from orchestration.config (engine) with an env override for
    tests (RICHOS_<KEY>). Data a reviewer can read."""
    v = os.environ.get("RICHOS_" + key)
    if v is None or v == "":
        v = config_value(key, default)
    try:
        return float(v)
    except ValueError:
        return float(default)


def _epoch(iso):
    try:
        from datetime import datetime
        return datetime.fromisoformat(iso).timestamp()
    except Exception:
        return None


def retention_pass():
    """Bounded lifetimes for the three things that otherwise accumulate
    forever (review 2026-09-03, blocker 8): captures (they hold ignored
    evidence, which is where secrets live), backup refs (they keep unlanded
    commits reachable after the harness deletes the branch) and the terminal
    transaction records themselves. Ages are counted from the transaction's
    `removed_ts`; a record is deleted only after every artifact it names is
    gone, so nothing on disk is ever orphaned from the record that explains
    it. The agent-id terminal index (`terminal/<agent_id>`, ~50 bytes) is
    kept: an agent id is terminal forever, and the resume guard reads it."""
    cap_days = retention_days("CAPTURE_RETENTION_DAYS", "30")
    ref_days = retention_days("BACKUP_REF_RETENTION_DAYS", "90")
    tx_days = retention_days("TRANSACTION_RETENTION_DAYS", "90")
    now = time.time()
    expired = {"captures": 0, "backup_refs": 0, "transactions": 0}
    for t in list(tx.iter_transactions()):
        if t.get("state") != "removed":
            continue
        removed = _epoch(t.get("removed_ts") or "")
        if removed is None:
            continue
        age = (now - removed) / 86400.0
        sid, aid = t["session_id"], t["agent_id"]
        with tx.tx_lock(sid, aid, timeout=5):
            for i, m in enumerate(t.get("members") or []):
                cdir = m.get("capture_dir")
                if cdir and not m.get("capture_expired_ts") and age >= cap_days:
                    if os.path.isdir(cdir):
                        shutil.rmtree(cdir)
                    tx.update_member(sid, aid, i, capture_expired_ts=tx.now_iso())
                    expired["captures"] += 1
                ref = m.get("backup_ref")
                if ref and not m.get("backup_ref_expired_ts") and age >= ref_days:
                    gone, why = _expire_backup_ref(m.get("repo"), ref)
                    if gone:
                        tx.update_member(sid, aid, i, backup_ref_expired_ts=tx.now_iso())
                        expired["backup_refs"] += 1
                    else:
                        # STILL TRACKED (landed review 2026-09-03, blocker 4):
                        # no expiry timestamp, so artifacts_gone below stays
                        # false and the record that names the ref outlives it.
                        n = int(m.get("backup_ref_expire_attempts") or 0) + 1
                        tx.update_member(sid, aid, i, backup_ref_expire_attempts=n,
                                         backup_ref_expire_error=why[:300], backup_ref_expire_last_attempt=tx.now_iso())
                        log("retention: backup ref %s of %s/%s NOT expired (attempt %d): %s — the ref and its record stay tracked; retried next run"
                            % (ref, sid[:8], aid, n, why))
            t = tx.load_tx(sid, aid)
            artifacts_gone = all(
                (not m.get("capture_dir") or m.get("capture_expired_ts") or not os.path.isdir(m["capture_dir"]))
                and (not m.get("backup_ref") or m.get("backup_ref_expired_ts"))
                for m in t.get("members") or [])
            if age >= tx_days and artifacts_gone:
                _expire_transaction_record(t)
                expired["transactions"] += 1
    # empty capture parents left behind
    root = tx.capture_root()
    for sdir in _listdir(root):
        sp = os.path.join(root, sdir)
        for adir in _listdir(sp):
            ap = os.path.join(sp, adir)
            if os.path.isdir(ap) and not _listdir(ap):
                _rmdir(ap)
        if os.path.isdir(sp) and not _listdir(sp):
            _rmdir(sp)
    if any(expired.values()):
        log("retention: expired %d capture(s), %d backup ref(s), %d transaction record(s)" % (expired["captures"], expired["backup_refs"], expired["transactions"]))
    return expired


def _expire_backup_ref(repo, ref):
    """(gone, why). A backup ref is `gone` only when the EXACT ref no longer
    resolves in its repository — verified by rev-parse after `update-ref -d`,
    never assumed from the deletion's exit code, and never assumed at all
    (landed review 2026-09-03, blocker 4). Until this revision the deletion's
    result was ignored and the member marked expired regardless; if git had
    rejected it, the ref lived on forever while the only record saying it
    existed was deleted by the transaction retention that trusted the stamp.

    A repository that is not present is NOT `gone`: an unmounted volume
    would otherwise drop the record while the ref survives on it. The
    record is kept and retried; a repository deleted for good keeps a tiny
    record forever, which is the right side of that trade."""
    if not repo or not os.path.isdir(repo):
        return False, "repository %s is not present, so the ref cannot be verified gone" % (repo or "?")
    if not _ref_exists(repo, ref):
        return True, "already absent"
    rc, _, err = git_out(repo, "update-ref", "-d", ref)
    if rc != 0:
        return False, "git update-ref -d %s exited %d: %s" % (ref, rc, err.strip()[:200])
    if _ref_exists(repo, ref):
        return False, "git update-ref -d %s exited 0 but the ref still resolves" % ref
    return True, "deleted and verified absent"


def _expire_transaction_record(t):
    sid, aid = t["session_id"], t["agent_id"]
    sd = tx.session_dir(sid)
    for p in (tx.tx_path(sid, aid), tx.lock_path(sid, aid), tx.bound_path(sid, aid), tx.start_path(sid, aid),
              tx.pending_terminal_path(sid, aid)):
        _unlink(p)
    if t.get("tool_use_id"):
        try:
            _unlink(tx.intent_path(sid, t["tool_use_id"]))
        except ValueError:
            pass
    for n in _listdir(sd):
        if n.startswith(aid + ".json.member-") and n.endswith(".notice"):
            _unlink(os.path.join(sd, n))
    if t.get("teammate"):
        try:
            _unlink(tx.terminal_name_path(sid, t["teammate"]))
        except ValueError:
            pass
    for sub in ("intents", "bound", "starts", "pending-terminal"):
        p = os.path.join(sd, sub)
        if os.path.isdir(p) and not _listdir(p):
            _rmdir(p)
    if os.path.isdir(sd) and not _listdir(sd):
        _rmdir(sd)
    tn = os.path.join(tx.tx_root(), "terminal-names", sid)
    if os.path.isdir(tn) and not _listdir(tn):
        _rmdir(tn)


def _listdir(p):
    try:
        return os.listdir(p)
    except OSError:
        return []


def _rmdir(p):
    try:
        os.rmdir(p)
    except OSError:
        pass


def run(max_seconds=None, only=None):
    deadline = time.time() + max_seconds if max_seconds else None
    n = 0
    try:
        n += process_pending_terminals(only)
    except Exception as e:
        log("pending terminal pass: %s" % e)
    for t in list(tx.iter_transactions()):
        if not t.get("terminal"):
            continue
        # The derived terminal indexes are repaired on EVERY pass, for every
        # terminal transaction including removed ones: a crash between the
        # transaction write and an index write (blocker 5) must not leave a
        # guard reading "live" from a marker that was never written.
        tx._repair_terminal_indexes(t)
        if t.get("state") == "removed":
            continue
        if only and "%s/%s" % (t["session_id"], t["agent_id"]) != only:
            continue
        if deadline and time.time() > deadline:
            log("time budget reached; the rest waits for the next run")
            break
        try:
            reconcile_transaction(t, deadline)
        except Exception as e:
            log("transaction %s/%s: %s" % (t["session_id"][:8], t["agent_id"], e))
        n += 1
    try:
        retention_pass()
    except Exception as e:
        log("retention pass: %s" % e)
    # HEARTBEAT: proof that a run happened, written by the run itself. The
    # live installation test waits for it after a launchd bootstrap (the job
    # ran, not merely loaded), and the spawn gate reports its age.
    try:
        tx.atomic_write_json(os.path.join(tx.tx_root(), "last-run.json"),
                             {"ts": tx.now_iso(), "epoch": time.time(), "pid": os.getpid(),
                              "reconciled": n, "argv": sys.argv[1:]})
    except Exception as e:
        log("heartbeat: %s" % e)
    return n


def status():
    m = tx.metrics()
    m["definition_of_done"] = {
        "terminal_members_with_a_directory_present": m["terminal_members_present"],
        "terminal_transactions_pending_normal_retry": m["pending_retry"],
        "hard_failures_counted_as_dead_present": m["failed_present"],
    }
    m["done"] = (m["terminal_members_present"] == 0 and m["pending_retry"] == 0)
    return m


def main(argv):
    # Nothing this process creates is readable by anyone but the account:
    # captures hold ignored evidence (blocker 8). The explicit 0700/0600
    # modes in private_makedirs/private_open are the first layer; the umask
    # is the second, and it covers every write this file did not think of.
    os.umask(0o077)
    ap = argparse.ArgumentParser(prog="reconcile-terminal-worktrees.py")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--max-seconds", type=float, default=None)
    ap.add_argument("--agent", default=None, help="SESSION_ID/AGENT_ID: reconcile one transaction")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    if a.status:
        s = status()
        print(json.dumps(s, sort_keys=True, indent=1))
        return 0 if s["done"] else 1
    n = run(a.max_seconds, a.agent)
    s = status()
    if not a.quiet:
        print(json.dumps({"reconciled": n, "status": s}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
