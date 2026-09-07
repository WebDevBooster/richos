#!/usr/bin/env python3
"""Read-only terminal branch cleanup planning, with an optional durable report journal.

An eligible plan is NOT deletion authority. Its ref, ownership and reflog
snapshots must be checked under lifecycle coordination by a future executor.
This module never updates Git refs, unregisters worktrees or removes files.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

HERE = Path(__file__).resolve().parent
OWNERSHIP_EVENTS = {"registered", "prepared"}
OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


def _module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / (name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _git(repo, *args):
    # Invocation state from a caller's own Git command must not retarget this
    # read to another repository or substitute an alternate object graph.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                              text=True, timeout=30, env=env)
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None


def _out(repo, *args):
    result = _git(repo, *args)
    return result.stdout.strip() if result is not None and result.returncode == 0 else None


def _time(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo is not None else None
    except (AttributeError, TypeError, ValueError):
        return None


def _path(value):
    return os.path.realpath(value) if isinstance(value, str) and value else None


def _ref(branch):
    if not isinstance(branch, str) or not branch:
        return None
    return branch if branch.startswith("refs/heads/") else "refs/heads/" + branch


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _file_snapshot(path):
    """Observe one stable regular file without following a substituted symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("not a regular file")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(fd)
        identity = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(os.lstat(path)):
            raise ValueError("file changed while being read")
        return {"path": str(path), "device": after.st_dev, "inode": after.st_ino,
                "size": after.st_size, "mtime_ns": after.st_mtime_ns,
                "ctime_ns": after.st_ctime_ns, "sha256": digest.hexdigest()}
    finally:
        os.close(fd)


def plan(transactions, ledger_records, integration_refs, *, input_errors=()):
    """Plan exact terminal members. integration_refs maps repo paths to full
    local main/master refs; absence is a retained decision, never a HEAD guess.
    Inputs must represent complete snapshots, not filtered recent history.
    """
    transactions = list(transactions)
    ledger_records = list(ledger_records)
    errors = list(input_errors)
    canonical_cache = {}

    def canonical(repo):
        path = _path(repo)
        if not path:
            return None
        if path not in canonical_cache:
            common = _out(path, "rev-parse", "--git-common-dir")
            canonical_cache[path] = _path(os.path.join(path, common)) if common else None
        return canonical_cache[path]

    policy = {}
    for repo, ref in integration_refs.items():
        common = canonical(repo)
        if common and ref in ("refs/heads/main", "refs/heads/master"):
            if common in policy and policy[common] != ref:
                errors.append("conflicting integration policy for " + common)
            policy[common] = ref
        else:
            errors.append("unreadable repository or invalid integration policy: " + str(repo))
    valid_transactions = []
    for tx in transactions:
        if not isinstance(tx, dict) or tx.get("record") != "transaction" or not isinstance(tx.get("members"), list):
            errors.append("malformed transaction history")
        elif any(not isinstance(m, dict) for m in tx["members"]):
            errors.append("malformed transaction member")
        else:
            valid_transactions.append(tx)
    for record in ledger_records:
        if not isinstance(record, dict) or not isinstance(record.get("event"), str):
            errors.append("malformed ownership history")
        elif record["event"] in OWNERSHIP_EVENTS and not (record.get("repo") or record.get("worktree")):
            errors.append("ownership record has no repository or workspace identity")
    valid_records = [r for r in ledger_records if isinstance(r, dict)]
    retire = _module("workspace-retire")
    rows = []
    for tx in valid_transactions:
        if not tx.get("terminal"):
            continue
        for index, member in enumerate(tx["members"]):
            row = {"session_id": tx.get("session_id"), "agent_id": tx.get("agent_id"),
                   "member_index": index, "repo": member.get("repo"), "path": member.get("path"),
                   "class": member.get("class"), "member_state": member.get("state"),
                   "ref": _ref(member.get("branch")), "recorded_tip": member.get("head"),
                   "eligible": False, "execution_authorized": False}
            rows.append(row)

            def retain(reason):
                row["reason"] = reason

            if errors:
                retain("input-history-unreadable")
                continue
            terminal = tx.get("terminal")
            terminal_time = _time(terminal.get("ts")) if isinstance(terminal, dict) else None
            sealed_time = _time(tx.get("sealed_ts"))
            if (tx.get("sealed") is not True
                    or not isinstance(tx.get("session_id"), str) or not tx["session_id"]
                    or not isinstance(tx.get("agent_id"), str) or not tx["agent_id"]
                    or terminal_time is None or sealed_time is None or terminal_time < sealed_time):
                retain("terminal-identity-incomplete")
                continue
            if not isinstance(member.get("path"), str) or not os.path.isabs(member["path"]):
                retain("member-identity-incomplete")
                continue
            repo, ref, tip = member.get("repo"), row["ref"], member.get("head")
            if not ref or not isinstance(tip, str) or not OID.fullmatch(tip):
                retain("terminal-branch-or-tip-missing")
                continue
            common = canonical(repo)
            row["common_git_dir"] = common
            if not common:
                retain("repository-unreadable")
                continue
            if _out(repo, "check-ref-format", ref) is None:
                retain("invalid-branch-ref")
                continue
            integration = policy.get(common)
            if not integration:
                retain("integration-policy-missing")
                continue
            row["integration_ref"] = integration
            if ref == integration:
                retain("integration-branch")
                continue

            def overlaps(other_repo, other_branch, other_path):
                if _path(other_path) == _path(member["path"]):
                    return True
                same_repo = canonical(other_repo) == common if other_repo else False
                same_repo = same_repo or (_path(other_repo) == _path(repo))
                if same_repo and not other_branch and not other_path:
                    return True  # An incomplete same-repository owner cannot be dismissed.
                return same_repo and _ref(other_branch) == ref

            conflicts = []
            owner = (tx["session_id"], tx["agent_id"])
            for other in valid_transactions:
                for oi, om in enumerate(other["members"]):
                    if other is tx and oi == index:
                        continue
                    if not overlaps(om.get("repo"), om.get("branch"), om.get("path")):
                        continue
                    other_time = _time(other.get("sealed_ts"))
                    other_terminal = other.get("terminal")
                    ended = _time(other_terminal.get("ts")) if isinstance(other_terminal, dict) else None
                    # Only a fully identified earlier, already terminal generation
                    # can coexist with this exact owner's recorded membership.
                    if (other.get("sealed") is not True or not other.get("session_id") or not other.get("agent_id") or other_time is None
                            or ended is None or ended < other_time or ended >= sealed_time or other_time >= sealed_time):
                        conflicts.append("competing-live-or-unknown-transaction")
            for record in valid_records:
                if record.get("event") not in OWNERSHIP_EVENTS:
                    continue
                if not overlaps(record.get("repo"), record.get("branch"), record.get("worktree")):
                    continue
                recorded = _time(record.get("ts"))
                record_owner = (record.get("session_id"), record.get("agent_id"))
                same_prepared = (record.get("event") == "prepared" and not record.get("agent_id")
                                 and record.get("session_id") == owner[0]
                                 and record.get("teammate") == tx.get("teammate")
                                 and bool(record.get("teammate"))
                                 and _path(record.get("worktree")) == _path(member["path"]))
                if recorded is None or recorded > terminal_time:
                    conflicts.append("later-or-undated-ownership")
                    continue
                if record_owner == owner or (same_prepared and recorded <= sealed_time):
                    continue
                if not all(isinstance(identity, str) and identity for identity in record_owner):
                    conflicts.append("competing-live-or-unknown-owner")
                    continue
                prior = [old for old in valid_transactions
                         if old.get("sealed") is True and _time(old.get("sealed_ts")) is not None
                         and (old.get("session_id"), old.get("agent_id")) == record_owner
                         and isinstance(old.get("terminal"), dict)
                         and _time(old["terminal"].get("ts")) is not None
                         and _time(old["terminal"]["ts"]) >= _time(old["sealed_ts"])
                         and recorded <= _time(old["terminal"]["ts"]) < sealed_time
                         and any(_path(om.get("path")) == _path(record.get("worktree"))
                                 and bool(record.get("worktree"))
                                 and canonical(om.get("repo")) == canonical(record.get("repo")) == common
                                 and _ref(om.get("branch")) == _ref(record.get("branch")) == ref
                                 for om in old["members"])]
                if not prior or recorded >= sealed_time:
                    conflicts.append("competing-live-or-unknown-owner")
            row["ownership_snapshot"] = {"transactions_sha256": _digest(transactions),
                                          "ledger_sha256": _digest(ledger_records)}
            if conflicts:
                retain(sorted(set(conflicts))[0])
                row["ownership_vetoes"] = sorted(set(conflicts))
                continue
            # Use the new fail-closed registry reader against the explicit repo.
            # Its Git boundary is replaced with this module's sanitized reader.
            original_git = retire._git
            retire._git = _git
            try:
                registry_gate = retire._branch_registry_gate(repo, ref[len("refs/heads/"):])
            finally:
                retire._git = original_git
            if registry_gate:
                retain(registry_gate["reason_code"])
                continue
            current = _git(repo, "symbolic-ref", "-q", "HEAD")
            if current is None or current.returncode not in (0, 1):
                retain("current-branch-unreadable")
                continue
            if current.returncode == 0 and current.stdout.strip() == ref:
                retain("branch-checked-out")
                continue
            branch_tip = _out(repo, "rev-parse", "--verify", "--quiet", ref)
            if branch_tip is None:
                absent = _git(repo, "show-ref", "--verify", "--quiet", ref)
                retain("branch-absent" if absent is not None and absent.returncode == 1 else "branch-unreadable")
                continue
            row["observed_tip"] = branch_tip
            if branch_tip != tip:
                retain("branch-moved")
                continue
            integration_tip = _out(repo, "rev-parse", "--verify", "--quiet", integration)
            if not integration_tip or not OID.fullmatch(integration_tip):
                retain("integration-unreadable")
                continue
            row["integration_tip"] = integration_tip
            direct_refs = True
            for checked_ref in (ref, integration):
                symbolic = _git(repo, "symbolic-ref", "-q", checked_ref)
                if symbolic is None or symbolic.returncode != 1:
                    retain("symbolic-or-unreadable-ref")
                    direct_refs = False
                    break
            if not direct_refs:
                continue
            merged = _git(repo, "merge-base", "--is-ancestor", tip, integration_tip)
            if merged is None or merged.returncode not in (0, 1):
                retain("merge-evidence-unreadable")
                continue
            if merged.returncode:
                retain("unmerged")
                continue
            try:
                row["generation"] = {"status": "observed", "reflog": _file_snapshot(Path(common) / "logs" / ref),
                                     "proves_ownership_generation": False}
            except (OSError, ValueError):
                row["generation"] = {"status": "unavailable", "proves_ownership_generation": False}
                retain("branch-generation-unavailable")
                continue
            if (_out(repo, "rev-parse", "--verify", "--quiet", ref) != tip
                    or _out(repo, "rev-parse", "--verify", "--quiet", integration) != integration_tip):
                retain("refs-changed-during-planning")
                continue
            row.update(eligible=True, reason="eligible-plan-only")
    return {"version": 1, "mode": "planning-only", "execution_authorized": False,
            "created_at": datetime.now(timezone.utc).isoformat(), "errors": sorted(set(errors)),
            "eligible": sum(row["eligible"] for row in rows),
            "retained": sum(not row["eligible"] for row in rows), "members": rows,
            "limits": ["No branch deletion or worktree removal is performed.",
                       "Reflog snapshots do not prove absence of earlier same-tip name reuse.",
                       "Concurrent attachment and reuse require executor-side lifecycle coordination."]}


def load_history():
    """Use the transaction iterator, but reject its silent malformed-file skips.
    Also check complete ownership JSONL, rather than accepting read_all's skips.
    """
    txmod = _module("worktree-transactions")
    ledgermod = _module("worktree-ledger")
    errors, parsed, snapshots = [], [], {}
    try:
        root = Path(txmod.tx_root())
        directories = {str(root): sorted(os.listdir(root))}
        for name in directories[str(root)]:
            session = root / name
            if name in ("terminal", "terminal-names"):
                continue
            if session.is_symlink():
                raise ValueError("symlink in transaction store: " + str(session))
            if not session.is_dir():
                continue
            directories[str(session)] = sorted(os.listdir(session))
            for filename in directories[str(session)]:
                if not filename.endswith(".json"):
                    continue
                file = session / filename
                snapshots[str(file)] = _file_snapshot(file)
                value = json.loads(file.read_text())
                if not isinstance(value, dict) or value.get("record") != "transaction":
                    raise ValueError("unexpected transaction record: " + str(file))
                parsed.append(value)
        transactions = list(txmod.iter_transactions())
        if sorted(map(_digest, parsed)) != sorted(map(_digest, transactions)):
            raise ValueError("transaction iterator omitted or changed records")
        for directory, names in directories.items():
            if sorted(os.listdir(directory)) != names:
                raise ValueError("transaction directory changed")
        for name, snapshot in snapshots.items():
            if _file_snapshot(name) != snapshot:
                raise ValueError("transaction history changed")
    except (OSError, ValueError, TypeError) as exc:
        errors.append("transaction history unreadable: " + str(exc))
        transactions = parsed
    records = []
    try:
        ledger = Path(ledgermod.ledger_path())
        snapshot = _file_snapshot(ledger)
        for line in ledger.read_text().splitlines():
            if line.strip():
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("non-object ledger record")
                records.append(record)
        if _file_snapshot(ledger) != snapshot:
            raise ValueError("ownership history changed")
    except (OSError, ValueError, TypeError) as exc:
        errors.append("ownership history unreadable: " + str(exc))
    return transactions, records, errors


def journal_report(report, path):
    """Append diagnostic evidence durably. A report never grants execution."""
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("a", encoding="utf-8") as out:
        fcntl.flock(out, fcntl.LOCK_EX)
        out.write(json.dumps(report, sort_keys=True) + "\n")
        out.flush()
        os.fsync(out.fileno())
    fd = os.open(destination.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integration", action="append", default=[], metavar="REPO=FULL_REF")
    parser.add_argument("--journal", help="append the planning report to this JSONL journal")
    args = parser.parse_args()
    policy = {}
    for value in args.integration:
        repo, sep, ref = value.rpartition("=")
        if not sep or not repo or ref not in ("refs/heads/main", "refs/heads/master"):
            parser.error("integration must be REPO=refs/heads/main or REPO=refs/heads/master")
        policy[repo] = ref
    transactions, records, errors = load_history()
    report = plan(transactions, records, policy, input_errors=errors)
    if args.journal:
        try:
            journal_report(report, args.journal)
        except OSError as exc:
            report["errors"].append("plan journal failed: " + str(exc))
    print(json.dumps(report, sort_keys=True))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
