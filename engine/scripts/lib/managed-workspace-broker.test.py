#!/usr/bin/env python3
"""Socket authority, isolated runtime and reviewable installation packaging tests."""
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import pwd
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock
import uuid

HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


broker = module("broker_tested", HERE / "managed-workspace-broker.py")
client = module("client_tested", HERE / "managed-workspace-client.py")
installer = module("installer_tested", HERE.parent / "install-managed-workspace-broker.py")


class FakeManager:
    def __init__(self):
        self.records, self.calls = {}, []

    def create(self, **kwargs):
        ident = str(uuid.uuid4())
        record = dict(kwargs, id=ident, state="active")
        self.records[ident] = record
        self.calls.append(("create", kwargs))
        return record

    def status(self, uid):
        return [record for record in self.records.values() if record["owner_uid"] == uid]

    def sweep(self):
        return list(self.records.values())

    def owner_uid(self, ident):
        return self.records[ident]["owner_uid"]

    def inspect(self, ident):
        return self.records[ident]

    def bind(self, ident, **kwargs):
        self.calls.append(("bind", ident, kwargs))
        self.records[ident].update(kwargs)
        return self.records[ident]

    def terminal(self, ident, **kwargs):
        self.calls.append(("terminal", ident, kwargs))
        self.records[ident]["state"] = "terminal"
        return self.records[ident]

    def reconcile(self, ident):
        self.calls.append(("reconcile", ident))
        return self.records[ident]

    def cancel_preparation(self, ident, **kwargs):
        self.calls.append(('cancel_preparation', ident, kwargs))
        return self.records[ident]


class BrokerSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="managed-broker-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.policy = {"version": 1, "private_root": str(self.root / "vault"),
            "active_root": str(self.root / "active"), "owners": {"501": {"gid": 20}, "502": {"gid": 20}},
            "repositories": {"repo": {"path": str(self.root / "approved"), "owners": [501],
                                     "size": "128m", "retention_days": 14}}}
        self.manager = FakeManager()
        self.broker = broker.Broker(self.manager, self.policy)
        self.create = {"operation": "create", "repository": "repo", "commit": "a" * 40,
                       "session_id": "session", "agent_name": "worker", "request_id": "stable-attempt"}

    def test_unused_preparation_inventory_and_cancellation_are_owner_scoped(self):
        own = self.broker.dispatch(501, self.create)['id']
        self.manager.records[own].update(agent_id=None)
        other = str(uuid.uuid4())
        self.manager.records[other] = dict(id=other, owner_uid=502, agent_id=None, state='active', session_id='secret')
        inventory = self.broker.dispatch(501, {'operation': 'preparations', 'after': ''})
        self.assertEqual([row['id'] for row in inventory['records']], [own])
        self.broker.dispatch(501, dict(operation='cancel_preparation', id=own, session_id='session'))
        self.assertEqual(self.manager.calls[-1], ('cancel_preparation', own, {'session_id': 'session'}))
        with self.assertRaises(broker.BrokerError):
            self.broker.dispatch(501, dict(operation='cancel_preparation', id=other, session_id='secret'))
        self.manager.records[own]['agent_id'] = 'worker'
        self.assertEqual(self.broker.dispatch(501, {'operation': 'preparations', 'after': ''})['records'], [])

    def test_preparations_after_first_page_are_reachable(self):
        for number in range(105):
            ident = str(uuid.UUID(int=number+1))
            self.manager.records[ident] = dict(id=ident, owner_uid=501, agent_id=None,
                                               state='active', session_id='session'+str(number))
        first = self.broker.dispatch(501, {'operation': 'preparations', 'after': ''})
        second = self.broker.dispatch(501, {'operation': 'preparations', 'after': first['next_cursor']})
        self.assertEqual(len(first['records']), 100)
        self.assertEqual(len(second['records']), 5)
        self.assertIsNone(second['next_cursor'])
        self.assertFalse({row['id'] for row in first['records']} & {row['id'] for row in second['records']})

    def test_completed_empty_creation_is_not_permanent_cleanup_debt(self):
        self.assertFalse(broker.Broker._issue(dict(state='creation-empty')))
        self.assertTrue(broker.Broker._issue(dict(state='creation-empty', last_error='receipt damaged')))

    def test_create_uses_only_root_policy_owner_path_size_and_retention(self):
        result = self.broker.dispatch(501, self.create)
        kwargs = self.manager.calls[-1][1]
        self.assertEqual(kwargs["source_repo"], str(self.root / "approved"))
        self.assertEqual(kwargs["owner_uid"], 501)
        self.assertEqual(kwargs["owner_gid"], 20)
        self.assertEqual(kwargs["retention_days"], 14)
        self.assertEqual(kwargs["size"], "128m")
        self.assertEqual(kwargs["request_id"], "stable-attempt")
        self.assertEqual(result["path"], str(self.root / "active" / result["manager_id"] / "repo"))
        self.assertEqual(result["workspace_class"], "managed-image")

    def test_unapproved_peer_and_repository_never_reach_manager(self):
        for uid, request in ((999, self.create), (502, self.create),
                             (501, dict(self.create, repository="/arbitrary/path"))):
            with self.assertRaises(broker.BrokerError):
                self.broker.dispatch(uid, request)
        self.assertEqual(self.manager.calls, [])

    def test_client_cannot_supply_owner_expiry_device_or_arbitrary_delete(self):
        for key in ("owner_uid", "owner_gid", "retention_days", "size", "source_repo", "device", "now"):
            with self.assertRaises(broker.BrokerError):
                self.broker.dispatch(501, dict(self.create, **{key: 0}))
        for operation in ("delete", "sweep", "detach", "attach", "expire"):
            with self.assertRaises(broker.BrokerError):
                self.broker.dispatch(501, {"operation": operation, "id": str(uuid.uuid4())})
        self.assertEqual(self.manager.calls, [])

    def test_existing_minted_id_owner_checked_before_mutation(self):
        ident = self.broker.dispatch(501, self.create)["id"]
        request = {"operation": "terminal", "id": ident, "session_id": "session", "agent_id": "agent"}
        with self.assertRaises(broker.BrokerError):
            self.broker.dispatch(502, request)
        self.assertEqual(len(self.manager.calls), 1)
        self.assertEqual(self.broker.dispatch(501, request)["state"], "terminal")
        with self.assertRaises((KeyError, broker.BrokerError)):
            self.broker.dispatch(501, dict(request, id=str(uuid.uuid4())))
        with self.assertRaises(broker.BrokerError):
            self.broker.dispatch(501, dict(request, id="../../victim"))
        self.assertEqual(len(self.manager.calls), 2)

    def test_mount_readiness_failure_does_not_block_terminal_authorization(self):
        ident = self.broker.dispatch(501, self.create)["id"]
        with mock.patch.object(self.manager, "inspect", side_effect=RuntimeError("active volume missing")):
            record = self.broker.dispatch(501, {"operation": "terminal", "id": ident,
                                               "session_id": "session", "agent_id": "agent"})
            self.assertEqual(record["state"], "terminal")
            self.assertEqual(self.broker.dispatch(501, {"operation":"reconcile", "id":ident})["id"], ident)
            with self.assertRaisesRegex(RuntimeError, "active volume missing"):
                self.broker.dispatch(501, {"operation":"inspect", "id":ident})

    def test_health_requires_approved_peer_and_has_no_manager_side_effects(self):
        result = self.broker.dispatch(501, {"operation": "health"})
        self.assertEqual(result["protocol"], 1)
        self.assertEqual(result["peer_uid"], 501)
        self.assertEqual(result["repositories"], ["repo"])
        with self.assertRaises(broker.BrokerError):
            self.broker.dispatch(999, {"operation": "health"})
        self.assertEqual(self.manager.calls, [])

    def test_status_is_owner_filtered_bounded_and_health_reports_unknown(self):
        for index in range(105):
            ident = str(uuid.uuid4())
            self.manager.records[ident] = {"id": ident, "owner_uid": 501, "state": "creation-incomplete",
                                           "last_error": "initialization interrupted"}
        foreign = str(uuid.uuid4())
        self.manager.records[foreign] = {"id": foreign, "owner_uid": 502, "state": "active"}
        with mock.patch.object(self.manager, "status", return_value=list(self.manager.records.values())):
            result = self.broker.dispatch(501, {"operation": "status"})
        self.assertEqual(result["total"], 105)
        self.assertEqual(result["unresolved_count"], 105)
        self.assertEqual(len(result["records"]), 100)
        self.assertTrue(result["truncated"])
        self.assertNotIn(foreign, json.dumps(result))
        health = self.broker.dispatch(501, {"operation": "health"})
        self.assertEqual(health["unresolved_count"], 105)
        self.assertIsNone(health["latest_sweep"]["last_success_at"])
        self.assertEqual(health["installed_feature_acceptance"], "not-assessed")
        with mock.patch.object(self.manager, "status", side_effect=OSError("unreadable durable map")):
            health = self.broker.dispatch(501, {"operation": "health"})
        self.assertFalse(health["inventory_complete"])
        self.assertIsNone(health["unresolved_count"])

    def test_changed_sweep_issues_logged_without_records_or_unchanged_noise(self):
        ident = str(uuid.uuid4())
        self.manager.records[ident] = {"id": ident, "owner_uid": 501, "state": "creation-incomplete",
                                       "last_error": "incomplete", "payload": {"private": "never logged"}}
        stream = io.StringIO()
        with mock.patch.object(broker.sys, "stderr", stream):
            self.broker.run_sweep()
            self.broker.run_sweep()
            self.manager.records[ident]["state"] = "active"
            self.manager.records[ident].pop("last_error")
            self.broker.run_sweep()
        lines = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(len(lines), 2)
        self.assertEqual(set(lines[0]["issues"][0]), {"id", "state", "reason"})
        self.assertEqual(lines[1]["issues"], [])
        self.assertNotIn("never logged", stream.getvalue())
        self.assertIsNotNone(self.broker.dispatch(501, {"operation":"health"})["latest_sweep"]["last_success_at"])

    def test_sweep_exception_and_publication_error_remain_visible(self):
        ident = str(uuid.uuid4())
        self.manager.records[ident] = {"id": ident, "owner_uid": 501, "state": "retained",
                                       "publication_error": "branch moved"}
        status = self.broker.dispatch(501, {"operation": "status"})
        self.assertEqual(status["unresolved_count"], 1)
        self.assertEqual(status["records"][0]["reason"], "branch moved")
        stream = io.StringIO()
        with mock.patch.object(broker.sys, "stderr", stream), \
                mock.patch.object(self.manager, "sweep", side_effect=OSError("unreadable store")):
            self.broker.run_sweep()
            self.broker.run_sweep()
        self.assertEqual(len(stream.getvalue().splitlines()), 1)
        health = self.broker.dispatch(501, {"operation": "health"})
        self.assertEqual(health["latest_sweep"]["error"], "manager-sweep-failed")
        self.assertIsNone(health["latest_sweep"]["last_success_at"])

    def test_stable_request_id_required_before_creation(self):
        del self.create["request_id"]
        with self.assertRaises(broker.BrokerError):
            self.broker.dispatch(501, self.create)
        self.assertEqual(self.manager.calls, [])

    def test_kernel_peer_identity_matches_real_socket_peer(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        self.assertEqual(broker.peer_uid(left), os.getuid())
        self.assertEqual(client._server_uid(right), os.getuid())

    def exchange(self, raw, uid=501):
        left, right = socket.socketpair()
        with mock.patch.object(broker, "peer_uid", return_value=uid):
            thread = threading.Thread(target=self.broker.handle, args=(left,))
            thread.start()
            try:
                right.sendall(raw)
                right.shutdown(socket.SHUT_WR)
                response = bytearray()
                while b"\n" not in response:
                    response.extend(right.recv(4096))
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive())
                return json.loads(response)
            finally:
                left.close()
                right.close()

    def test_actual_socket_handler_valid_request_and_malformed_limits(self):
        self.assertTrue(self.exchange(json.dumps(self.create).encode() + b"\n")["ok"])
        for raw in (b"{broken\n", b"[]\n", b"{}\n{}\n", b"x" * (broker.MAX_REQUEST + 1), b"{}"):
            self.assertFalse(self.exchange(raw)["ok"])
        self.assertEqual(len(self.manager.calls), 1)

    def test_peer_query_failure_cannot_reach_dispatch(self):
        left, right = socket.socketpair()
        try:
            with mock.patch.object(broker, "peer_uid", side_effect=OSError("no credentials")):
                self.broker.handle(left)
            self.assertFalse(json.loads(right.recv(4096))["ok"])
            self.assertEqual(self.manager.calls, [])
        finally:
            left.close(); right.close()

    def test_real_serve_startup_request_and_signal_shutdown(self):
        socket_path = self.root / "runtime" / "served.sock"
        script = """
import importlib.util, json, pathlib, sys, types
spec=importlib.util.spec_from_file_location('server',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
# Only host privilege boundaries are substituted for this disposable fixture.
m.protected_path=lambda path, **kw: pathlib.Path(path).resolve()
m.peer_uid=lambda connection: 501
policy=json.loads(sys.argv[3])
manager=types.SimpleNamespace(sweep=lambda: [], owner_uid=lambda ident:501, inspect=lambda ident: {'id':ident,'owner_uid':501,'state':'active'})
m.serve(m.Broker(manager,policy),sys.argv[2],interval=0.05)
"""
        child = subprocess.Popen([sys.executable, "-c", script, str(HERE / "managed-workspace-broker.py"),
                                  str(socket_path), json.dumps(self.policy)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not socket_path.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertIsNone(child.poll(), "real broker startup exited before binding")
            self.assertTrue(socket_path.exists(), "real broker never bound its socket")
            ident = str(uuid.uuid4())
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(5)
                connection.connect(str(socket_path))
                connection.sendall(json.dumps({'operation':'inspect','id':ident}).encode()+b'\n')
                response = json.loads(connection.recv(4096))
            self.assertTrue(response["ok"], response)
            self.assertEqual(response["result"]["id"], ident)
            child.terminate()
            _, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, stderr.decode())
            self.assertFalse(socket_path.exists(), "shutdown retained stale socket")
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)

    def test_client_rejects_nonroot_server_before_sending_request(self):
        fake = mock.MagicMock()
        fake.__enter__.return_value = fake
        with mock.patch.object(client.socket, "socket", return_value=fake), \
                mock.patch.object(client, "_server_uid", return_value=501):
            with self.assertRaisesRegex(client.ClientError, "not root"):
                client.call(self.create)
        fake.sendall.assert_not_called()

    def test_client_root_authenticated_roundtrip_and_explicit_server_failure(self):
        for response, succeeds in (({"ok": True, "result": {"id": "minted"}}, True),
                                   ({"ok": False, "error": "broker unavailable"}, False)):
            # Only peer UID is mocked. Framing and Unix socket exchange are real.
            path = self.root / ("socket-" + str(succeeds))
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(path)); listener.listen(1)
            received = []
            def server():
                with listener.accept()[0] as peer:
                    received.append(json.loads(peer.recv(4096)))
                    peer.sendall(json.dumps(response).encode() + b"\n")
            thread = threading.Thread(target=server)
            thread.start()
            try:
                with mock.patch.object(client, "_server_uid", return_value=0):
                    if succeeds:
                        self.assertEqual(client.call(self.create, socket_path=path), {"id": "minted"})
                    else:
                        with self.assertRaises(client.ClientError):
                            client.call(self.create, socket_path=path)
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive())
                self.assertEqual(received, [self.create])
            finally:
                listener.close()

    def test_socket_down_is_failure_without_fallback(self):
        with self.assertRaises(client.ClientError):
            client.call(self.create, socket_path=self.root / "absent")

    def test_world_writable_runtime_asset_is_refused(self):
        file = self.root / "unsafe.py"
        file.write_text("pass")
        file.chmod(0o666)
        with self.assertRaises(broker.BrokerError):
            broker.protected_path(file, regular=True)

    def test_runtime_requires_isolation_and_no_site(self):
        with self.assertRaises(broker.BrokerError):
            broker.validate_runtime()

    def test_acl_allow_or_unknown_metadata_is_refused_by_both_validators(self):
        for mod, error in ((broker, broker.BrokerError), (installer, ValueError)):
            for output, allowed in (("drwx------ root wheel /fixture\n", True),
                                    ("drwx------+ root wheel /fixture\n 0: group:everyone deny delete\n", True),
                                    ("drwx------+ root wheel /fixture\n 0: user:501 allow add_file,delete_child\n", False),
                                    ("drwx------+ root wheel /fixture\n truncated ACL\n", False)):
                with mock.patch.object(mod.sys, "platform", "darwin"), \
                        mock.patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
                    if allowed:
                        mod.reject_unsafe_acl("/fixture")
                    else:
                        with self.assertRaises(error):
                            mod.reject_unsafe_acl("/fixture")

    @unittest.skipUnless(sys.platform == "darwin", "actual macOS ACL fixture")
    def test_actual_extended_acl_is_detected_in_disposable_file(self):
        file = self.root / "acl-fixture"
        file.write_text("fixture")
        subprocess.run(["/bin/chmod", "+a", "user:" + pwd.getpwuid(os.getuid()).pw_name + " allow write", str(file)], check=True)
        try:
            with self.assertRaises(broker.BrokerError):
                broker.reject_unsafe_acl(file)
            with self.assertRaises(ValueError):
                installer.reject_unsafe_acl(file)
        finally:
            subprocess.run(["/bin/chmod", "-N", str(file)], check=True)

    def test_stage_contains_exact_manifest_and_isolated_launchd_arguments(self):
        package = installer.stage(self.root / "package")
        content, manifest = installer.payloads(package)
        self.assertEqual(set(content), set(broker.CODE_FILES))
        self.assertEqual(set(manifest), set(broker.CODE_FILES))
        plist = plistlib.loads((package / (installer.LABEL + ".plist")).read_bytes())
        self.assertEqual(plist["ProgramArguments"][:4], ["/usr/bin/python3", "-I", "-S", "-B"])
        self.assertNotIn(str(HERE), json.dumps(plist))
        self.assertEqual(plist["UserName"], "root")
        self.assertTrue((package / "install.py").is_file())
        self.assertTrue((package / "policy.example.json").is_file())

    def test_tampered_package_fails_hash_validation(self):
        package = installer.stage(self.root / "package")
        (package / broker.CODE_FILES[1]).write_text("tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            installer.payloads(package)

    def test_install_refuses_without_root_isolated_invocation(self):
        with self.assertRaises(ValueError):
            installer.install(self.root / "absent", self.root / "policy")

    def test_installation_artifacts_in_disposable_namespace_without_activation(self):
        package = installer.stage(self.root / "package")
        (self.root / "approved").mkdir()
        policy_source = self.root / "policy-input.json"
        policy_source.write_text(json.dumps(self.policy))
        launchd = self.root / "LaunchDaemons"
        launchd.mkdir()
        destination = self.root / "installed"
        overrides = {"INSTALL_ROOT": destination, "POLICY_PATH": destination / "policy.json",
                     "CLIENT_CONFIG_PATH": self.root / "public/client.pending.json",
                     "SOCKET_ROOT": self.root / "sockets", "PLIST_PATH": launchd / "broker.plist",
                     "PRIVATE_ROOT": self.root / "vault", "ACTIVE_ROOT": self.root / "active"}
        # Simulate only the privileged checks. Every output path is a disposable
        # fixture; this proves packaging shape, not actual root ownership.
        with mock.patch.multiple(installer, **overrides), \
                mock.patch.object(installer.os, "geteuid", return_value=0), \
                mock.patch.object(installer.sys, "platform", "darwin"), \
                mock.patch.object(installer.sys, "flags", types.SimpleNamespace(isolated=1, no_site=1)), \
                mock.patch.object(installer, "protected", side_effect=lambda p: Path(p).resolve()):
            unrelated = self.root / "unrelated"
            unrelated.mkdir(mode=0o755)
            before = unrelated.stat().st_mode
            for disallowed in ("/", str(unrelated)):
                wrong = dict(self.policy, private_root=disallowed)
                policy_source.write_text(json.dumps(wrong))
                with self.assertRaisesRegex(ValueError, "dedicated"):
                    installer.install(package, policy_source)
                self.assertEqual(unrelated.stat().st_mode, before)
                self.assertFalse(destination.exists(), "refusal must precede installation writes")
            policy_source.write_text(json.dumps(self.policy))
            first = installer.install(package, policy_source)
            second = installer.install(package, policy_source)
        self.assertEqual(first["release"], second["release"])
        self.assertFalse(first["activated"])
        self.assertEqual(installer.payloads(Path(first["release"])), installer.payloads(package))
        public = json.loads(overrides["CLIENT_CONFIG_PATH"].read_text())
        self.assertEqual(public["repositories"], {"repo": str(self.root / "approved")})
        self.assertEqual(public["socket"], str(self.root / "sockets/broker.sock"))
        self.assertEqual(overrides["CLIENT_CONFIG_PATH"].stat().st_mode & 0o777, 0o644)
        self.assertEqual(overrides["POLICY_PATH"].stat().st_mode & 0o777, 0o600)
        self.assertTrue(overrides["PLIST_PATH"].is_file())
        self.assertFalse((self.root / "public/client.json").exists(), "installation must not enable managed mode")
        self.assertFalse((self.root / "sockets/broker.sock").exists())

    def test_runtime_manifest_and_relative_import_paths_cannot_be_bypassed(self):
        package = installer.stage(self.root / "package")
        flags = types.SimpleNamespace(isolated=1, no_site=1)
        with mock.patch.object(broker.os, "geteuid", return_value=0), \
                mock.patch.object(broker.sys, "flags", flags), \
                mock.patch.object(broker.sys, "path", ["relative/user/imports"]), \
                mock.patch.object(broker, "protected_path", side_effect=lambda p, **kw: Path(p).resolve()):
            with self.assertRaisesRegex(broker.BrokerError, "relative"):
                broker.validate_runtime()
        (package / broker.CODE_FILES[1]).write_text("tampered")
        with mock.patch.object(broker.os, "geteuid", return_value=0), \
                mock.patch.object(broker.sys, "flags", flags), \
                mock.patch.object(broker.sys, "path", []), \
                mock.patch.object(broker, "__file__", str(package / broker.CODE_FILES[0])), \
                mock.patch.object(broker, "protected_path", side_effect=lambda p, **kw: Path(p).resolve()):
            with self.assertRaisesRegex(broker.BrokerError, "hash mismatch"):
                broker.validate_runtime()


if __name__ == "__main__":
    unittest.main(verbosity=2)
