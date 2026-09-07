#!/usr/bin/env python3
"""Root Unix socket broker for managed external workspaces.

Run only from a protected installed release using an isolated interpreter.
The socket authenticates operating-system users, not individual same-UID agents.
"""
import argparse
import concurrent.futures
import ctypes
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import struct
import sys
import threading
import time
import uuid

CODE_FILES = ("managed-workspace-broker.py", "managed-workspace-manager.py", "managed-workspace-volume.py", "managed-workspace-client.py", "managed-workspace-acceptance.py", "managed-workspace-failed-creation.py")
MAX_REQUEST = 65536
MAX_RESPONSE = 1048576


class BrokerError(RuntimeError):
    pass


def reject_unsafe_acl(path):
    """macOS mode bits do not bound ACL grants. Accept only no ACL or deny-only ACLs."""
    if sys.platform != "darwin":
        return
    try:
        result = subprocess.run(["/bin/ls", "-lde", str(path)], capture_output=True,
                                text=True, timeout=5, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
        raise BrokerError("ACL metadata unavailable: " + str(path)) from exc
    lines = result.stdout.splitlines()
    if result.returncode != 0 or not lines:
        raise BrokerError("ACL metadata unavailable: " + str(path))
    for line in lines[1:]:
        if not re.fullmatch(r"\s*\d+: .+ deny [A-Za-z_,]+", line):
            raise BrokerError("ACL grants or unreadable ACL on protected path: " + str(path))


def protected_path(path, *, regular=None):
    """Require root control of the resolved object and every ancestor."""
    resolved = Path(path).resolve(strict=True)
    for item in (resolved, *resolved.parents):
        info = item.lstat()
        reject_unsafe_acl(item)
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise BrokerError("unprotected runtime path: " + str(item))
        if item != resolved and not stat.S_ISDIR(info.st_mode):
            raise BrokerError("runtime ancestor is not a directory")
    if regular is True and not resolved.is_file():
        raise BrokerError("regular protected file required")
    if regular is False and not resolved.is_dir():
        raise BrokerError("protected directory required")
    return resolved


def validate_runtime():
    if os.geteuid() != 0 or not sys.flags.isolated or not sys.flags.no_site:
        raise BrokerError("root broker requires Python -I -S from its installed release")
    protected_path(sys.executable, regular=True)
    for entry in sys.path:
        if not entry or not Path(entry).is_absolute():
            raise BrokerError("relative interpreter import path")
        path = Path(entry)
        while not path.exists():
            path = path.parent
        protected_path(path)
    release = protected_path(Path(__file__).parent, regular=False)
    manifest_path = protected_path(release / "manifest.json", regular=True)
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or set(manifest) != set(CODE_FILES):
        raise BrokerError("installed code manifest mismatch")
    for name in CODE_FILES:
        path = protected_path(release / name, regular=True)
        if path.parent != release or hashlib.sha256(path.read_bytes()).hexdigest() != manifest[name]:
            raise BrokerError("installed code hash mismatch: " + name)
    return release


def validate_policy(value):
    if not isinstance(value, dict) or set(value) != {"version", "private_root", "active_root", "owners", "repositories"}:
        raise BrokerError("invalid policy fields")
    if value["version"] != 1:
        raise BrokerError("unsupported policy version")
    for key in ("private_root", "active_root"):
        if not isinstance(value[key], str) or not Path(value[key]).is_absolute():
            raise BrokerError("absolute managed roots required")
    owners, repos = value["owners"], value["repositories"]
    if not isinstance(owners, dict) or not isinstance(repos, dict) or not owners or not repos:
        raise BrokerError("explicit owners and repositories required")
    for uid, record in owners.items():
        if not isinstance(uid, str) or not re.fullmatch(r"[1-9][0-9]*", uid) or int(uid) > 2**31 - 1:
            raise BrokerError("unprivileged owner UID required")
        if not isinstance(record, dict) or set(record) != {"gid"} or type(record["gid"]) is not int or not 0 <= record["gid"] <= 2**31 - 1:
            raise BrokerError("fixed numeric owner GID required")
    for alias, record in repos.items():
        if not isinstance(alias, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", alias):
            raise BrokerError("invalid repository alias")
        if not isinstance(record, dict) or set(record) != {"path", "owners", "retention_days", "size"}:
            raise BrokerError("invalid repository policy")
        if not isinstance(record["path"], str) or not Path(record["path"]).is_absolute():
            raise BrokerError("absolute approved repository path required")
        if not isinstance(record["owners"], list) or not record["owners"] or any(type(uid) is not int or str(uid) not in owners for uid in record["owners"]):
            raise BrokerError("repository owner is not approved")
        if type(record["retention_days"]) is not int or not 1 <= record["retention_days"] <= 365:
            raise BrokerError("fixed retention from 1 to 365 days required")
        if not isinstance(record["size"], str) or not re.fullmatch(r"[1-9][0-9]*[mg]", record["size"]):
            raise BrokerError("fixed sparse capacity required")
    return value


def peer_uid(connection):
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = libc.getpeereid
        getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        getpeereid.restype = ctypes.c_int
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise BrokerError("kernel peer identity unavailable")
        return uid.value
    if sys.platform.startswith("linux"):
        _, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        return uid
    raise BrokerError("unsupported kernel peer authentication")


class Broker:
    def __init__(self, manager, policy):
        self.manager = manager
        self.policy = validate_policy(policy)
        self._status_lock = threading.Lock()
        self._sweep = {"last_attempt_at": None, "last_completed_at": None, "last_success_at": None,
                       "error": None}
        self._issue_digest = None

    @staticmethod
    def _issue(record):
        return bool(record.get("last_error") or record.get("publication_error")) or record.get("state") not in ("active", "retained", "expired", "creation-empty")

    @staticmethod
    def _summary(record):
        return {"id": record.get("id"), "state": record.get("state", "unknown"),
                "reason": str(record.get("last_error") or record.get("publication_error") or record.get("reason") or "")[:512]}

    def run_sweep(self):
        now = time.time()
        try:
            records = self.manager.sweep()
            if not isinstance(records, list) or any(not isinstance(record, dict) for record in records):
                raise BrokerError("invalid manager sweep inventory")
            issues = [self._summary(record) for record in records if self._issue(record)]
            with self._status_lock:
                self._sweep.update(last_attempt_at=now, last_completed_at=time.time(), error=None)
                if not issues:
                    self._sweep["last_success_at"] = self._sweep["last_completed_at"]
        except Exception as exc:
            issues = [{"id": None, "state": "sweep-failed", "reason": str(exc)[:512]}]
            with self._status_lock:
                self._sweep.update(last_attempt_at=now, error="manager-sweep-failed")
        digest = hashlib.sha256(json.dumps(issues, sort_keys=True).encode()).hexdigest()
        if digest != self._issue_digest and (issues or self._issue_digest is not None):
            print(json.dumps({"event": "workspace-sweep-issues", "issues": issues}, sort_keys=True),
                  file=sys.stderr, flush=True)
        self._issue_digest = digest

    def _inventory(self, uid):
        records = self.manager.status(uid)
        if not isinstance(records, list) or any(not isinstance(record, dict) for record in records):
            raise BrokerError("invalid owner inventory")
        owned = [record for record in records if record.get("owner_uid") == uid]
        # The manager owns parsing and identifying incomplete durable requests.
        # Filtering is repeated here so another owner's state is never exposed.
        return {"inventory_complete": True, "inventory_scope": "durable-records", "total": len(owned),
                "unresolved_count": sum(self._issue(record) for record in owned),
                "records": [self._summary(record) for record in owned[:100]],
                "truncated": len(owned) > 100}

    def _record(self, record):
        result = dict(record)
        ident = result["id"]
        result.update(manager_id=ident, workspace_class="managed-image",
                      path=str(Path(self.policy["active_root"]).resolve() / ident / "repo"))
        return result

    def dispatch(self, uid, request):
        if str(uid) not in self.policy["owners"]:
            raise BrokerError("peer UID is not approved")
        if not isinstance(request, dict) or not isinstance(request.get("operation"), str):
            raise BrokerError("object request with operation required")
        op = request["operation"]
        fields = {"health": {"operation"}, "status": {"operation"}, "preparations": {"operation", "after"},
                  "cancel_preparation": {"operation", "id", "session_id"},
                  "create": {"operation", "repository", "commit", "session_id", "agent_name", "request_id"},
                  "bind": {"operation", "id", "session_id", "agent_id"},
                  "terminal": {"operation", "id", "session_id", "agent_id"},
                  "inspect": {"operation", "id"}, "reconcile": {"operation", "id"}}
        if op not in fields or set(request) != fields[op]:
            raise BrokerError("unsupported operation or request fields")
        if op == "status":
            return self._inventory(uid)
        if op == "preparations":
            records = self.manager.status(uid)
            if not isinstance(records, list) or any(not isinstance(row, dict) for row in records):
                raise BrokerError("invalid owner inventory")
            after = request['after']
            if not isinstance(after, str) or (after and not re.fullmatch(r'[0-9a-f-]{36}', after)):
                raise BrokerError('invalid preparation inventory cursor')
            unused = [row for row in records if row.get('owner_uid') == uid and row['id'] > after
                      and row.get('state') in ('active', 'creating', 'creation-incomplete')
                      and row.get('agent_id', 'unknown') is None]
            unused.sort(key=lambda row: row['id'])
            return {"records": [{key: row.get(key) for key in ('id', 'session_id', 'created_at')}
                                for row in unused[:100]], "next_cursor": unused[99]["id"] if len(unused) > 100 else None}
        if op == "health":
            with self._status_lock:
                latest = dict(self._sweep)
            try:
                inventory = self._inventory(uid)
                owned = {key: inventory[key] for key in ("inventory_complete", "inventory_scope", "total", "unresolved_count")}
            except Exception:
                owned = {"inventory_complete": False, "total": None, "unresolved_count": None,
                         "inventory_error": "owner-inventory-unavailable"}
            return dict(owned, protocol=1, service="managed-workspace-broker", server_uid=os.geteuid(),
                        peer_uid=uid, latest_sweep=latest, installed_feature_acceptance="not-assessed",
                        repositories=sorted(alias for alias, entry in self.policy["repositories"].items()
                                            if uid in entry["owners"]))
        if op == "create":
            alias = request["repository"]
            if not isinstance(alias, str):
                raise BrokerError("repository alias required")
            repo = self.policy["repositories"].get(alias)
            if repo is None or uid not in repo["owners"]:
                raise BrokerError("repository is not approved for this peer")
            return self._record(self.manager.create(request_id=request["request_id"], source_repo=repo["path"], commit=request["commit"],
                owner_uid=uid, owner_gid=self.policy["owners"][str(uid)]["gid"],
                session_id=request["session_id"], agent_name=request["agent_name"],
                retention_days=repo["retention_days"], size=repo["size"]))
        ident = request["id"]
        try:
            if str(uuid.UUID(ident)) != ident:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise BrokerError("server-minted workspace ID required")
        # Ownership is independent of current mount readiness. A missing or
        # detached active volume must not prevent its owner recording terminal
        # intent or requesting recovery. The manager validates readiness only
        # for operations that require it, including inspect and bind.
        if self.manager.owner_uid(ident) != uid:
            raise BrokerError("workspace is not owned by this peer")
        if op == "inspect":
            return self._record(self.manager.inspect(ident))
        if op == "reconcile":
            return self._record(self.manager.reconcile(ident))
        if op == "cancel_preparation":
            return self._record(self.manager.cancel_preparation(ident, session_id=request['session_id']))
        return self._record(getattr(self.manager, op)(ident, session_id=request["session_id"], agent_id=request["agent_id"]))

    def handle(self, connection):
        connection.settimeout(5)
        try:
            uid = peer_uid(connection)
            if str(uid) not in self.policy["owners"]:
                raise BrokerError("peer UID is not approved")
            payload = bytearray()
            while b"\n" not in payload:
                chunk = connection.recv(min(4096, MAX_REQUEST + 1 - len(payload)))
                if not chunk:
                    raise BrokerError("incomplete request")
                payload.extend(chunk)
                if len(payload) > MAX_REQUEST:
                    raise BrokerError("request exceeds size limit")
            line, remainder = bytes(payload).split(b"\n", 1)
            if remainder.strip():
                raise BrokerError("one request per connection required")
            request = json.loads(line)
            result = {"ok": True, "result": self.dispatch(uid, request)}
        except Exception as exc:
            result = {"ok": False, "error": str(exc)}
        response = json.dumps(result, sort_keys=True).encode() + b"\n"
        if len(response) > MAX_RESPONSE:
            response = b'{"ok":false,"error":"response exceeds size limit"}\n'
        try:
            connection.sendall(response)
        except OSError:
            pass


def serve(broker, socket_path, *, interval=60):
    supplied = Path(socket_path)
    path = supplied.parent.resolve() / supplied.name
    # /var/run may be recreated on boot. Recreate only this final directory
    # under an already protected parent, never an arbitrary ancestor chain.
    if not path.parent.exists():
        protected_path(path.parent.parent, regular=False)
        path.parent.mkdir(mode=0o711)
        os.chmod(path.parent, 0o711)
    parent = protected_path(path.parent, regular=False)
    if path.parent.resolve() != parent or not path.name:
        raise BrokerError("invalid socket path")
    # A lifetime lock prevents a second daemon from unlinking an active socket.
    lock_fd = os.open(parent / "broker.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != 0:
            raise BrokerError("refusing to replace unexpected socket path")
        path.unlink()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stop = threading.Event()
    slots = threading.BoundedSemaphore(8)
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)
    listener.bind(str(path))
    os.chmod(path, 0o666)
    listener.listen(16)
    listener.settimeout(1)

    def sweep():
        while not stop.is_set():
            broker.run_sweep()
            stop.wait(interval)

    def client(connection):
        try:
            with connection:
                broker.handle(connection)
        finally:
            slots.release()

    threading.Thread(target=sweep, daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    try:
        while not stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            if slots.acquire(blocking=False):
                pool.submit(client, connection)
            else:
                connection.close()
    finally:
        stop.set()
        listener.close()
        pool.shutdown(wait=True)
        path.unlink(missing_ok=True)
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    release = validate_runtime()
    policy_path = protected_path(args.policy, regular=True)
    policy = validate_policy(json.loads(policy_path.read_text()))
    spec = importlib.util.spec_from_file_location("installed_workspace_manager", release / "managed-workspace-manager.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manager = module.WorkspaceManager(policy["private_root"], policy["active_root"], require_root=True)
    serve(Broker(manager, policy), args.socket)


if __name__ == "__main__":
    main()
