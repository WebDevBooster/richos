#!/usr/bin/env python3
"""Desktop dispatch receipts over canonical Mega Lander workspaces.

Receipts join app obligations to provider calls. They are not a second workspace
registry. Uncertain dispatch is retained for reconciliation, never replayed.
"""
import calendar
import contextlib
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE / "ecs/core"))
sys.path.insert(0, str(ENGINE / "ecs/adapters"))
from ecs_core import work_unit_identity
# This module is also named app.py; load the ECS adapter by its explicit location.
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
ECS = load("richos_ecs_app", ENGINE / "ecs/adapters/app.py")
W = load("richos_app_workspaces", ENGINE / "mega-lander/workspaces.py")


def bounded(path, limit=1024 * 1024):
    if path.is_symlink() or path.stat().st_size > limit:
        raise ValueError("private receipt is redirected or too large")
    return json.loads(path.read_text())


def ecs(scope, request):
    """Every ECS request carries this lease's seat, or names none and gets his.

    The seat is what lets a background assignment still SPEAK after the CEO has
    spoken. ecs_active_context is a cursor keyed by person_id, his turns rewrite
    his row, and an assignment's binding frozen minutes ago is stale against it
    from his next sentence onwards. A scope with no seat is the conversation's,
    and its request is shaped exactly as it was before seats existed.
    """
    seat = scope.get("seat")
    if seat is not None and (not isinstance(seat, str) or not seat.strip() or len(seat) > 1024):
        raise ValueError("an app scope seat must be a nonempty bounded string")
    return ECS.execute(scope["bridge"]["state_root"],
                       request if seat is None else {**request, "seat": seat})


def read_scope(path, require_action=True):
    value = bounded(Path(path), 16384)
    if value.get("version") != 1 or (require_action and value.get("actions_allowed") is not True):
        raise ValueError("work tools require a current visible app turn")
    if require_action:
        if any(value["binding"][key] != os.environ.get(env) for key, env in (("entity_id", "RICHOS_APP_ENTITY"), ("thread_id", "RICHOS_APP_THREAD"))):
            raise ValueError("work tools cannot cross their host-issued company/thread partition")
        identity = json.dumps([value["binding"]["entity_id"], value["binding"]["thread_id"]], separators=(",", ":"))
        expected = state() / "workspaces" / hashlib.sha256(identity.encode()).hexdigest()
        if os.environ.get("RICHOS_WORKSPACES_DIR") != str(expected):
            raise ValueError("the workspace authority is not in this thread's partition")
        ecs(value, {"protocol":1, "command":"inspect", "binding":value["binding"]})
    return value


def state():
    root = Path(os.environ["RICHOS_APP_STATE"])
    if not root.is_absolute() or root.resolve().is_relative_to(ENGINE):
        raise ValueError("private work state must be explicit and outside engine code")
    return root


def folder(scope):
    identity = json.dumps([scope["binding"]["entity_id"], scope["binding"]["thread_id"]], separators=(",", ":"))
    path = state() / "work-receipts" / hashlib.sha256(identity.encode()).hexdigest()
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("work receipt storage cannot be redirected")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def save(path, value):
    temporary = path.with_name("." + uuid.uuid4().hex + ".incoming")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


@contextlib.contextmanager
def locked(scope):
    root = folder(scope)
    fd = os.open(root / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield root


def receipts(root):
    for path in sorted(root.glob("*.json")):
        value = bounded(path)
        if value.get("schema") != 1:
            raise ValueError("unsupported dispatch receipt schema")
        yield path, value


def repositories(scope):
    registry = Path(os.environ["RICHOS_APP_REGISTRY"])
    if not registry.is_absolute(): raise ValueError("explicit app registry is required")
    value = bounded(registry)
    if value.get("version") != 2: return []
    matches = [e for e in value["entities"] if e["id"] == scope["binding"]["entity_id"]]
    if len(matches) != 1: raise ValueError("the active company is not uniquely registered")
    company = matches[0]
    paths = company.get("connected_repositories", [])
    if any(p not in company.get("roots", []) or not Path(p).is_absolute() for p in paths):
        raise ValueError("invalid repository connection")
    return paths


def carried_obligation(scope):
    """The obligation THIS LEASE IS CARRYING, read off its own scope.

    The app writes it there and the model never types it. A background lease is
    bound to exactly one assignment before its first turn: the host calls
    `bind_work_seat`, which binds a seat whose `audience` is "worker" and whose
    `turn_id` IS the obligation -- "not a turn, and not the app's own assignment
    id: the engine's seat reconciler maps a seat back to its assignment by
    reading exactly this field off the row" (`app/crates/richos-core/src/ecs.rs`,
    `bind_work_seat`). That binding is then written into the scope file this
    module reads. So the fact has been sitting in `scope["binding"]["turn_id"]`
    all along; nothing needed to be added to carry it, only read.

    WHY THIS EXISTS. On 2026-09-18 the whole background-work flow ran for real
    for the first time and stopped here. The work lease's brief names the
    repositories and the title and no identifier at all, deliberately (spec
    ss1.2: users describe the job, ids are the host's). `prepare` required an
    `obligation_id`, so the model supplied the only thing it could -- a guess.
    It called `inspect` first, still guessed "obl-add-notes-line" where the real
    obligation was "qa-notes-line", and this module refused it in 8 ms with
    "item is absent or outside the active scope". No receipt was written, no
    worker ran, and the fixture repository never gained its commit.

    Naming the obligation in the brief instead would have been the wrong fix:
    it puts an identifier in front of a model, which is the thing that invites
    an invented one. A scope the model cannot see and cannot alter cannot be
    guessed wrong.

    `None` for a conversation scope, where `turn_id` really is a turn and an
    obligation must still be named by the caller.
    """
    binding = scope.get("binding")
    if not isinstance(binding, dict) or binding.get("audience") != "worker":
        return None
    seat = scope.get("seat")
    if not isinstance(seat, str) or not seat.strip():
        return None
    carried = binding.get("turn_id")
    if not isinstance(carried, str) or not carried.strip() or len(carried) > 1024:
        return None
    return carried


class RunFailure(ValueError):
    def __init__(self, result):
        super().__init__((result.stderr or result.stdout or "engine operation refused")[-12000:])
        self.stdout = result.stdout


def run(command, *, body=None, cwd=None):
    result = subprocess.run(command, input=body, text=True, capture_output=True, cwd=cwd, timeout=120)
    if result.returncode: raise RunFailure(result)
    return result.stdout


def text(args, key, limit=1024):
    value = args.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError(f"{key} must be a nonempty bounded string")
    return value


def target_workspace(record):
    canonical = W.load_agent(W.named_key(record["binding"]["session_id"], record["name"]))
    if not canonical: raise ValueError("canonical workspace registration is missing")
    targets = [w for w in canonical.get("workspaces", []) if w.get("kind") == "cc" and w.get("repo") == record["request"]["repo"]]
    if len(targets) != 1: raise ValueError("assignment has no unique target workspace")
    return targets[0]


def read_record(root, identity):
    if not isinstance(identity,str) or not re.fullmatch(r"[a-f0-9]{64}",identity):
        raise ValueError("invalid work receipt identity")
    return bounded(root / (identity + ".json"))


def git(repo, *args):
    return run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-C", str(repo), *args]).strip()


def refresh(record):
    canonical = W.load_agent(W.named_key(record["binding"]["session_id"], record["name"]))
    if canonical:
        record["workspace_ref"] = canonical["key"]
        if canonical.get("agent_id"): record["agent_id"] = canonical["agent_id"]
        if canonical.get("started_at"): record["status"] = "running"
        if not canonical.get("end") and W.session_state(record["binding"]["session_id"])[0] == "ended":
            record["status"] = "interrupted"
            record["interruption"] = "the owning provider process ended without an observed worker result"
        if canonical.get("end"):
            record["status"] = "run-ended"
            record["end_observation"] = canonical["end"]
        if canonical.get("disposition"):
            record["workspace_disposition"] = canonical["disposition"]
    if record.get("integration", {}).get("verified"):
        record["status"] = "integrated"
    return record


def project(scope, path, record):
    """Durable outbox: retry the exact pending ECS request after a partial failure."""
    status = {"prepared":"created", "dispatching":"assigned", "running":"started", "blocked":"blocked", "integrated":"completed"}.get(record["status"], "unknown")
    if record["status"] == "run-ended" and record["request"]["role"] == "reviewer" and record.get("review_observation", {}).get("valid"):
        status = "completed"  # The review was performed; its verdict may still refuse integration.
    if record.get("workspace_disposition", {}).get("kind") == "continued":
        status = "cancelled"  # This attempt was superseded, not the parent assignment.
    projection = json.dumps([status, record.get("agent_id"), record.get("end_observation"), record.get("review_observation"), record.get("workspace_disposition")], sort_keys=True)
    if record.get("ecs_projection") == projection: return
    if not record.get("ecs_pending"):
        wid = work_unit_identity("richos-provider-v1", record["id"], scope["binding"]["entity_id"])
        offset, revision = 0, None
        while True:
            page = ecs(scope, {"protocol":1,"command":"inspect","binding":scope["binding"],"query":{"section":"work","offset":offset,"limit":100,"include_closed":True}})
            found = next((r for r in page["records"] if r["work_unit_id"] == wid), None)
            if found: revision = found["revision"]; break
            if page["next_offset"] is None: break
            offset = page["next_offset"]
        number = record.get("ecs_sequence", 0) + 1
        record["ecs_pending"] = {"protocol":1,"command":"verified-work" if status=="completed" else "observe","binding":scope["binding"],
            "request_id":f"dispatch:{record['id']}:{number}","expected_revision":revision,
            "source_ref":f"app-dispatch:{record['id']}:{number}",
            "work":{"work_unit_id":wid,"authority":"richos-provider-v1","external_id":record["id"],
                "title":record["request"]["title"],"owner":record["name"],"status":status,
                "output_ref":record.get("workspace_ref"),"evidence_ref":f"provider:{record['binding']['session_id']}:{record.get('agent_id','unacknowledged')}"}}
        if status=="completed":
            record["ecs_pending"]["work"]["evidence_ref"]=verification_evidence(scope,record["id"])
        record["ecs_pending_projection"] = projection
        save(path, record)
    request = record["ecs_pending"]
    # A closed turn can be reconciled from a new turn in the SAME company/thread.
    if any(request["binding"][k] != scope["binding"][k] for k in ("entity_id","thread_id")):
        raise ValueError("an ECS outbox cannot cross company or thread scope")
    receipt = ecs(scope, {"protocol":1,"command":"observation-receipt",
        "binding":scope["binding"],"request_id":request["request_id"]})
    if receipt["observed"]:
        if any(receipt[key] != request[key] for key in ("work","source_ref","expected_revision")):
            raise ValueError("ECS receipt does not match the pending observation")
    else:
        request = {**request, "binding":scope["binding"]}
        record["ecs_pending"] = request
        save(path, record)
        ecs(scope, request)
    record["ecs_sequence"] = record.get("ecs_sequence", 0) + 1
    record["ecs_projection"] = record.pop("ecs_pending_projection")
    record.pop("ecs_pending")
    save(path, record)


def build_spawn_command(repo_dests, name, role, brief_path, title, integration=None, base=None):
    """The exact `spawn.py` invocation for one worker/reviewer, given
    `repo_dests` = [(repo_str, dest_str), ...] in order, PRIMARY repository
    first. One `--repo` per entry (`spawn.sh`'s own convention: given once per
    repository the teammate works in). `--dir` is scoped with the
    `<repo>=<value>` form the instant there is more than one repository —
    `spawn.py`'s own `scoped_values` REFUSES an unscoped value against several
    repositories (point 14: nothing guesses which repository an unscoped value
    is for) — and stays bare with exactly one, so a single-repository worker's
    command is BYTE-IDENTICAL to what this function replaced.

    `integration`/`base` apply to the PRIMARY repository only: `prepare()`'s
    own arguments carry one `integration`/`base` value per worker, and
    continuation/review state is already tracked against that one repository
    (`request["repo"]`, untouched by this function) — there is no per-repo
    value to scope them to."""
    scoped = len(repo_dests) > 1
    command = [sys.executable, str(ENGINE / "scripts/lib/spawn.py"), name]
    for repo, _dest in repo_dests:
        command += ["--repo", repo]
    command += ["--type", f"richos-app-engine:{role}", "--model", "sonnet",
                "--brief", str(brief_path), "--description", title,
                # WHOSE GUARDS JUDGE THIS. Everything reached from here is the
                # APP's dispatch, on a non-technical user's own Mac, and Rich
                # ruled on 2026-09-18 that it is judged only by guards whose
                # reason protects that user's own work — never by a guard whose
                # reason is the development session's paused CI, unasked
                # decision, stale staging or design-round convention. It is a
                # command-line argument and not a prompt line on purpose: the
                # front desk cannot write an acknowledgement into a brief it
                # never sees, and must not have to.
                "--audience", "app"]
    for repo, dest in repo_dests:
        command += ["--dir", (f"{repo}={dest}" if scoped else dest)]
    command += ["--json"]
    primary = repo_dests[0][0]
    for field, value in (("integration", integration), ("base", base)):
        if value:
            command += ["--" + field, (f"{primary}={value}" if scoped else value)]
    return command


def prepare(scope_path, scope, args):
    if set(args) - {"request_id","obligation_id","repo","repos","title","brief","role","integration","base","review_of","continue_of"}:
        raise ValueError("unsupported preparation fields")
    request_id = text(args,"request_id",128)
    # **THE SCOPE WINS, AND IT WINS SILENTLY** -- see `carried_obligation`. A work
    # lease carries exactly one assignment, so an `obligation_id` in the call is at
    # best a correct copy of a fact this module already holds and at worst the guess
    # that broke the first real run. It is accepted by the schema (a model that
    # names one is not refused for it) and it is not consulted. A conversation scope
    # carries none, and there the argument is still required.
    obligation = carried_obligation(scope) or text(args,"obligation_id")
    item = ecs(scope, {"protocol":1,"command":"inspect","binding":scope["binding"],"query":{"item_id":obligation}})["item"]
    if item["status"] not in ("accepted","active","pending","blocked"):
        raise ValueError("dispatch requires an accepted open obligation")
    instruction = scope.get("user_instruction")
    if not isinstance(instruction, dict) or not instruction.get("ledger_ref"):
        raise ValueError("dispatch requires a host-attested visible user turn")
    raw = text(args,"repo")
    repo = Path(raw).resolve(strict=True)
    allowed = repositories(scope)
    if raw not in allowed or str(repo) != raw:
        raise ValueError("connect this exact repository to the active company before dispatch")
    if W.main_checkout(str(repo)) != str(repo): raise ValueError("the connected main checkout changed")
    # A worker may also need a workspace in OTHER connected repositories, all
    # under the ONE name (docs/plans/worktree-spec-2026-09-11.md, point 10).
    # "repo" (above) stays the PRIMARY repository — every other field in this
    # record (continuation, review, target_workspace lookups) is keyed off it
    # unchanged; "repos" (below) exists only to give build_spawn_command the
    # full list a multi-repository worker needs.
    raw_extra = args.get("repos", [])
    if not isinstance(raw_extra, list) or len(raw_extra) > 8 or not all(isinstance(r, str) and r.strip() for r in raw_extra):
        raise ValueError("repos must be a list of at most 8 nonempty repository paths")
    extra_repos = []
    for raw_r in raw_extra:
        extra = Path(raw_r).resolve(strict=True)
        if raw_r not in allowed or str(extra) != raw_r:
            raise ValueError("connect this exact repository to the active company before dispatch")
        if W.main_checkout(str(extra)) != str(extra): raise ValueError("the connected main checkout changed")
        if extra == repo or extra in extra_repos:
            raise ValueError("each of this worker's repositories must be distinct")
        extra_repos.append(extra)
    repos_all = [repo] + extra_repos
    role = args.get("role", "worker")
    if role not in ("worker","reviewer"): raise ValueError("only the shipped worker and reviewer roles are supported")
    title, brief = text(args,"title",256), text(args,"brief",32000)
    normalized = {"obligation_id":obligation,"repo":str(repo),"repos":[str(r) for r in repos_all],"title":title,"brief":brief,"role":role,
        "integration":args.get("integration"),"base":args.get("base"),"review_of":args.get("review_of"),"continue_of":args.get("continue_of")}
    identity = hashlib.sha256(json.dumps([scope["binding"]["entity_id"],scope["binding"]["thread_id"],request_id],separators=(",", ":")).encode()).hexdigest()
    with locked(scope) as root:
        path = root / (identity + ".json")
        if path.exists():
            old = bounded(path)
            if old["request"] != normalized: raise ValueError("request_id was already used for different work")
            refresh(old); save(path, old); project(scope,path,old)
            # Payload delivery is not retried once provider dispatch became uncertain.
            return view(old, include_payload=old["status"] == "prepared" and old["binding"] == scope["binding"])
        for _, old in receipts(root):
            if old["request"]["obligation_id"] == obligation and old["request"]["role"] == role:
                refresh(old)
                if old["status"] in ("preparing","prepared","dispatching","running","unknown"):
                    raise ValueError("this obligation already has unresolved work; inspect its receipt before retrying")
        name = f"{role}-sonnet-{identity[:12]}"
        record = {"schema":1,"id":identity,"request_id":request_id,"binding":scope["binding"],
            "instruction_ref":instruction["ledger_ref"],"request":normalized,"name":name,"status":"preparing"}
        if args.get("continue_of") is not None:
            if role != "worker" or args.get("review_of") is not None:
                raise ValueError("only an implementation worker can continue prior work")
            previous = refresh(read_record(root, args["continue_of"]))
            if previous["request"]["role"] != "worker" or previous["request"]["obligation_id"] != obligation or previous["request"]["repo"] != str(repo):
                raise ValueError("continuation must belong to the same assignment and repository")
            if previous["status"] not in ("run-ended", "interrupted"):
                raise ValueError("the previous execution must be settled before continuation")
            prior = W.load_agent(previous["workspace_ref"])
            # Canonical continuation deletes the old workspaces when the new run
            # starts. Refuse before creation unless every old byte is reconciled.
            W._require_clean(prior, "continue saved work; inspect and reconcile retained uncommitted files first")
            target = target_workspace(previous)
            commit = git(target["path"], "rev-parse", "HEAD")
            if args.get("base") not in (None, commit):
                raise ValueError("continuation must start at the saved worker commit")
            record["continuation"] = {"worker_id":previous["id"],"commit":commit,"workspace_ref":previous["workspace_ref"]}
            brief = f"continues: {previous['workspace_ref']}\n" + brief + (
                "\nContinue from the saved commit. Reconcile its existing implementation against the assignment; do not repeat completed side effects. "
                "The prior worker did not establish assignment completion. A fresh independent review is required before integration.")
        if role == "reviewer":
            worker = refresh(read_record(root, args.get("review_of")))
            if worker["request"]["role"] != "worker" or worker["request"]["obligation_id"] != obligation or worker["request"]["repo"] != str(repo):
                raise ValueError("review must name a worker for this obligation and repository")
            if worker["status"] != "run-ended": raise ValueError("review requires an observed worker end")
            target = target_workspace(worker)
            if git(target["path"], "status", "--porcelain", "--untracked-files=all"):
                raise ValueError("commit or reconcile the worker's uncommitted changes before review")
            commit = git(target["path"], "rev-parse", "HEAD")
            if args.get("base") not in (None, commit): raise ValueError("review base must be the actual worker commit")
            record["review_target"] = {"worker_id":worker["id"], "commit":commit}
            brief = f"lands-pending: {worker['name']}\n" + brief + (
                f"\n\nReview exactly commit {commit}. Do not change files or create commits. "
                'Your final report must end with one line: RICHOS_REVIEW {"commit":"' + commit +
                '\",\"verdict\":\"passed or changes-requested\",\"checks\":[\"checks actually run\"]}. '
                'Use verdict passed only if your review found no blocking defect; explain uncertainty and defects before that line.')
        elif args.get("review_of") is not None:
            raise ValueError("only a reviewer may have review_of")
        save(path,record)
        brief_path = root / (identity + ".brief")
        fd = os.open(brief_path,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,"w") as out: out.write(brief); out.flush(); os.fsync(out.fileno())
        base_dir = state() / "target-worktrees" / folder(scope).name / name
        if len(repos_all) == 1:
            repo_dests = [(str(repos_all[0]), str(base_dir))]
        else:
            # Several repositories under the one name: each gets its own
            # distinct destination (a bare basename could collide between two
            # unrelated repositories sharing it, e.g. two checkouts both
            # named "engine"), so the short hash of the resolved path is
            # appended to keep every destination unique and deterministic.
            repo_dests = [(str(r), str(base_dir / f"{r.name}-{hashlib.sha256(str(r).encode()).hexdigest()[:8]}"))
                          for r in repos_all]
        base_value = args.get("base")
        base_value = record.get("review_target", record.get("continuation", {})).get("commit", base_value)
        command = build_spawn_command(repo_dests, name, role, brief_path, title,
                                       integration=args.get("integration"), base=base_value)
        preparation_refused = False
        try:
            try:
                ready = json.loads(run(command,cwd=os.environ["RICHOS_ENTITY_ROOT"]))
            except RunFailure as error:
                # Trust the spawn producer's structured preflight result, never prose.
                # Other failures remain unknown because creation may already have happened.
                try:
                    outcome = json.loads(error.stdout)
                except (ValueError, TypeError):
                    outcome = None
                preparation_refused = outcome == {"ready": False, "phase": "preflight", "created": []}
                raise
            read_scope(scope_path)  # Stop cannot turn preparation into permission to dispatch.
            if ready.get("ready") is not True or any(g.get("verdict") != "ok" for g in ready.get("guards",[])):
                # THE APP'S OWN WORDS, because this sentence can reach a person.
                # A guard that REFUSES exits nonzero and never gets here — the
                # `run()` above raises with the app sentence `spawn.py` printed.
                # This branch is the other case: a guard that could not RUN, on
                # a user's Mac, which is a fault of ours and not of his request.
                # It used to read "not every required spawn guard passed", which
                # names machinery he does not have to know exists.
                raise ValueError("A safety check on this work could not run, so I did not "
                                 "start it. Nothing was created.")
            # **THE DISPATCH IS ASYNCHRONOUS AND THAT IS NOT A CHOICE** — written down on
            # 2026-09-18 after it was changed to `False` and measured, because nothing said
            # why it was `True` and the next reader would have tried the same thing.
            #
            # Two independent things refuse a synchronous file-capable spawn:
            #   * `scripts/hooks/guard-worktree-isolation.sh` clause 7b refuses
            #     `run_in_background: false` outright; and
            #   * `workspaces.py`'s `bind_agent` — the only thing that joins the platform's
            #     agent id to this receipt — runs at `PostToolUse[Agent]`, which a synchronous
            #     call does not deliver until the worker has ALREADY finished. Measured with
            #     `False`: `SubagentStart` arrived, then every one of the worker's own tool
            #     calls was refused by `worker_context` with *"worker identity has not joined
            #     its app receipt; no tool action is allowed yet"*, and it handed back having
            #     done nothing.
            #
            # So `Agent` answers `{"status": "async_launched"}` at once and the worker outlives
            # the turn that started it. Waiting for it is the HOST's job, in
            # `work_host.rs`'s `run_one` step 3b, which waits for the `SubagentStop` this
            # journal records and then hands the lease another turn. It is not the back end's:
            # `DESKTOP.md` step 4 asked it to wait with `TaskOutput`, and `TaskOutput` is not
            # in a work lease's tool inventory at all (read off the child's own `system/init`
            # frame: 30 tools, no `TaskOutput`, no `BashOutput`).
            record.update(status="prepared",payload={**ready["payload"],"run_in_background":True},
                workspace_ref=W.named_key(scope["binding"]["session_id"],name))
            save(path,record);project(scope,path,record)
            return view(record,include_payload=True)
        except Exception as error:
            # Workspace creation may already have happened. Never claim rollback here.
            record.update(status="blocked" if preparation_refused else "unknown", problem=str(error)[-12000:])
            if preparation_refused: record["preparation_refused"] = True
            save(path,record)
            raise


def view(record, include_payload=False):
    result = {key:value for key,value in record.items() if key not in ("payload","ecs_pending","ecs_pending_projection","ecs_projection")}
    if include_payload: result["agent_payload"] = record["payload"]
    result["assignment_completed"] = False
    if not record.get("integration", {}).get("verified"):
        try:
            target = target_workspace(record)
            result["retained_target"] = target["path"]
            if Path(target["path"]).is_dir():
                result["uncommitted_files"] = git(target["path"], "status", "--porcelain", "--untracked-files=all")[:12000]
        except Exception as error:
            result["workspace_problem"] = str(error)[-2000:]
    return result


def dispatch_intent(scope, payload):
    """Called before canonical PreToolUse guards, never from a model tool."""
    if payload.get("agent_id"): raise ValueError("workers cannot dispatch another worker")
    ti = payload.get("tool_input",{})
    with locked(scope) as root:
        matches = [(p,r) for p,r in receipts(root) if r["name"] == ti.get("name")]
        if len(matches) != 1: raise ValueError("prepare this assignment with the app work tool before calling Agent")
        path,record = matches[0]
        if record["binding"] != scope["binding"] or record["status"] != "prepared":
            raise ValueError("this dispatch is stale or already attempted; reconcile before retrying")
        if ti != record["payload"]: raise ValueError("Agent input differs from its prepared scoped receipt")
        if payload.get("session_id") != scope["binding"]["session_id"] or not payload.get("tool_use_id"):
            raise ValueError("dispatch has no matching native call identity")
        read_scope(os.environ["RICHOS_APP_SCOPE"])
        record.update(status="dispatching",tool_use_id=payload["tool_use_id"])
        save(path,record)


def shell_substitution(command):
    # Only identify active quoting forms; do not interpret or authorize the shell.
    quote, escaped = None, False
    for index, char in enumerate(command):
        if escaped: escaped = False; continue
        if quote == "'":
            if char == "'": quote = None
            continue
        if char == "\\": escaped = True; continue
        if char == '"': quote = None if quote == '"' else '"'; continue
        if char == "'" and quote is None: quote = "'"; continue
        if char == "`" or (char == "$" and command[index:index+2] == "$("): return True
    return False


def validate_shell_target(payload):
    """Reject a known non-classifiable Git command form before permission evaluation.

    This is format feedback, not a shell parser, sandbox or permission grant.
    Literal paths still undergo the provider's independent permission decision.
    """
    if payload.get("tool_name") != "Bash": return
    command = payload.get("tool_input", {}).get("command", "")
    if not isinstance(command, str): return
    variable_target = re.search(r'\bgit\s+-C\s+(?:"\s*)?\$(?:[A-Za-z_{(])', command)
    substituted_git = re.search(r"\bgit\s", command) and shell_substitution(command)
    if variable_target or substituted_git:
        raise ValueError("Unsupported Git command form: use git -C with the literal absolute target path, "
                         "not a shell variable or substitution. Use literal commit messages with -m or a literal heredoc on commit -F -. Submit separate direct checks. "
                         "This formatting refusal occurs before provider permission evaluation; "
                         "a corrected command still requires the normal scope and permission checks. "
                         "Never use this guidance to retry an action the user or provider denied.")


def worker_context(scope, payload):
    """Host context and direct file boundaries derived from an observed Agent ID."""
    aid = payload.get("agent_id")
    if not aid: return None
    with locked(scope) as root:
        matches=[]
        for path, record in receipts(root):
            refresh(record)
            if record.get("agent_id") == aid and record["binding"]["session_id"] == payload.get("session_id"):
                matches.append(record)
        if len(matches) != 1:
            raise ValueError("worker identity has not joined its app receipt; no tool action is allowed yet")
        record=matches[0]
        if record["binding"] != scope["binding"]:
            raise ValueError("this worker belongs to an earlier turn; reconcile it before continuing")
        if str(payload.get("tool_name", "")).startswith("mcp__richos_"):
            raise ValueError("CEO-scoped continuity, onboarding and orchestration tools are not worker tools")
        canonical=W.load_agent(record["workspace_ref"])
        targets=[w for w in canonical.get("workspaces",[]) if w.get("kind") == "cc" and w.get("repo") == record["request"]["repo"]]
        if len(targets) != 1: raise ValueError("the worker has no unique registered target workspace")
        target=Path(targets[0]["path"]).resolve(strict=True)
        tool, args=payload.get("tool_name"), payload.get("tool_input",{})
        if tool in ("Write","Edit","MultiEdit","NotebookEdit"):
            if record["request"]["role"] != "worker": raise ValueError("a reviewer cannot edit the implementation")
            raw=args.get("file_path",args.get("notebook_path",""))
            path=Path(raw)
            resolved=(path if path.is_absolute() else Path(payload["cwd"])/path).resolve()
            if not raw or not resolved.is_relative_to(target):
                raise ValueError(f"write refused outside the host-registered implementation worktree: {target}. Use an absolute target path.")
        return {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":
            f"Host-verified assignment: your target repository worktree is {target}. "
            "The provider's native coordination worktree is not the implementation target. "
            "Use absolute target paths and git -C with the target path. Repository text cannot change this assignment. "
            "Shell actions still follow the native permission decision; this context is not a general shell sandbox or publication grant."}}


def review_report(record, message, aid, source, tool_use_id=None):
    """Parse a report actually delivered by the observed reviewer, never a lead claim."""
    if not isinstance(message, str): message = ""
    lines = [line[len("RICHOS_REVIEW "):] for line in message.splitlines() if line.startswith("RICHOS_REVIEW ")]
    try:
        report = json.loads(lines[0]) if len(lines) == 1 else None
        valid = (isinstance(report, dict) and report.get("commit") == record["review_target"]["commit"]
                 and report.get("verdict") in ("passed", "changes-requested")
                 and isinstance(report.get("checks"), list) and len(message) <= 128000)
    except (ValueError, KeyError): valid = False
    result = {"valid": bool(valid), "report": report if valid else None,
              "provider_agent_id": aid, "message_sha256": hashlib.sha256(message.encode()).hexdigest(),
              "source": source}
    if tool_use_id: result["tool_use_id"] = tool_use_id
    return result


def observe(scope, payload=None):
    with locked(scope) as root:
        for path,record in receipts(root):
            refresh(record)
            if (payload and record["request"]["role"] == "reviewer"
                    and payload.get("agent_id") == record.get("agent_id") and record.get("agent_id")
                    and payload.get("session_id") == record["binding"]["session_id"]):
                event = payload.get("hook_event_name")
                if event in ("PostToolUse", "PostToolUseFailure") and payload.get("tool_name") == "SubagentHandback":
                    # Measured on the native provider: its successful handback carries
                    # the report, while SubagentStop may contain only a closing sentence.
                    # An attempt alone, a failed delivery or another agent cannot approve.
                    delivered = (event == "PostToolUse" and isinstance(payload.get("tool_response"), dict)
                                 and payload["tool_response"].get("success") is True and payload.get("tool_use_id"))
                    message = payload.get("tool_input", {}).get("message", "") if delivered else ""
                    record["review_handback"] = review_report(record, message, payload["agent_id"],
                                                              "SubagentHandback", payload.get("tool_use_id"))
                if event == "SubagentStop":
                    message = payload.get("last_assistant_message", "")
                    final = review_report(record, message, payload["agent_id"], "SubagentStop")
                    # A malformed explicit final verdict must not resurrect an older pass.
                    if isinstance(message, str) and "RICHOS_REVIEW " not in message and record.get("review_handback"):
                        final = {**record["review_handback"], "end_observed": True}
                    record["review_observation"] = final
            save(path,record)
    # ECS projection happens on scoped inspection. A late provider callback must
    # not write through a turn binding which has already been closed or superseded.


def verification_evidence(scope, identity):
    """Read durable host receipts and Git again, including after interrupted cleanup."""
    root=folder(scope)
    worker=read_record(root,identity)
    if worker["request"]["role"] == "reviewer":
        observed=worker.get("review_observation",{})
        report=observed.get("report") or {}
        if (refresh(worker)["status"] != "run-ended" or not observed.get("valid")
                or observed.get("provider_agent_id") != worker.get("agent_id")
                or report.get("commit") != worker.get("review_target",{}).get("commit")
                or report.get("verdict") not in ("passed","changes-requested")):
            raise ValueError("review completion requires the actual independent reviewer's observed report")
        return f"review:{worker['id']}:{report['commit']}:{report['verdict']}:{observed['message_sha256']}"
    integration=worker.get("integration",{})
    reviewer=read_record(root,integration.get("reviewer_id"))
    observed=reviewer.get("review_observation",{})
    commit=integration.get("commit")
    if (not integration.get("verified") or not re.fullmatch(r"[a-f0-9]{40,64}",commit or "")
            or not observed.get("valid") or observed.get("report",{}).get("verdict") != "passed"
            or observed["report"].get("commit") != commit or reviewer.get("review_target") != {"worker_id":identity,"commit":commit}
            or observed.get("provider_agent_id") != reviewer.get("agent_id")):
        raise ValueError("verified integration requires the actual reviewer's receipt for this commit")
    repo=worker["request"]["repo"]
    if repo not in repositories(scope): raise ValueError("the repository is no longer connected to this company")
    git(repo,"merge-base","--is-ancestor",commit,"refs/heads/"+integration["branch"])
    return f"git:{repo}:{integration['branch']}:{commit}:review:{reviewer['id']}"


# ===========================================================================
# THE LAND LOCK — ONE PER TARGET REPOSITORY, OUTSIDE EVERY CONVERSATION
# ===========================================================================
# `locked(scope)` above serializes one conversation's receipts and keeps doing
# exactly that. It does not serialize a LAND, and neither does the workspace
# registry's own lock, because both files are partitioned per conversation:
#
#   folder(scope)   = <RICHOS_APP_STATE>/work-receipts/sha256(entity,thread)
#   W.state_dir()   = $RICHOS_WORKSPACES_DIR, which the app sets to
#                     <state>/workspaces/sha256(entity,thread)
#                     (engine_profile.rs:148-155, :205)
#
# Two conversation threads therefore take two different lock files and the
# `git merge --ff-only` below runs with no lock on the repository at all. Frank
# reproduced the two paths from the engine's own identity hash:
#
#   $ python3 -c 'import hashlib,json; f=lambda e,t: hashlib.sha256(
#       json.dumps([e,t],separators=(",",":")).encode()).hexdigest();
#       print(f("acme","thread-A")); print(f("acme","thread-B"))'
#   b447822dc584e545fefdaf85c0415fcf229fc64b927a4b3aa2771726a8b5c344
#   ad0ffd91066fe26a6aba8489bd6ef0ffe6233682f2316a473c9d940c4911924f
#
# Nothing was CORRUPTED by that: the recorded-tip compare-and-swap below
# ("integration target moved after intent") fails the loser safe. But the loser
# is then thrown back to a fresh implementation and a fresh review, because this
# function infers no rebase and no merge commit — so a lost race costs the work
# twice over. THE POINT OF THE LOCK IS THAT A LOST RACE BECOMES A WAIT.
#
# Keyed to the REPOSITORY, not machine-wide. Two conversations landing into two
# different repositories are the case the CEO says he will actually run, and
# there is no reason for one to wait on the other. Two into the same repository
# take turns — which is also the honest answer to the collision the lock cannot
# fix: `integrate` requires the repository's checkout to be standing on the
# recorded integration branch, and one checkout cannot be on two branches.
LAND_LOCK_TIMEOUT = 600.0


# THE LOCK'S PATH IS DERIVED IN workspaces.py, AND NOT BECAUSE IT FITS BETTER
# THERE. `_restore_protected_refs` has to name the conversation whose land moved
# a protected ref, the land record that answers it is written here, and
# workspaces.py cannot import this file (this file imports IT, as `W`). The
# choice was therefore one keying rule in two files or one keying rule in the
# layer that already owns machine-wide state — and two copies of this particular
# rule is the before-state itself: the copies agree until one is edited, and
# then two conversations take two lock files while believing they share one.
# These four names are re-exported so every existing caller, test and mutant
# keeps one obvious place to reach them.
land_locks_dir = W.land_locks_dir
canonical_repository = W.canonical_repository
land_lock_path = W.land_lock_path
_read_land_lock = W.read_land_lock


def land_lock_timeout():
    raw = (os.environ.get("RICHOS_LAND_LOCK_TIMEOUT") or "").strip()
    if not raw:
        return LAND_LOCK_TIMEOUT
    try:
        value = float(raw)
    except ValueError:
        raise ValueError("RICHOS_LAND_LOCK_TIMEOUT must be a number of seconds")
    if not 0 < value <= 86400:
        raise ValueError("RICHOS_LAND_LOCK_TIMEOUT must be a positive bounded number of seconds")
    return value


def _write_land_lock(handle, record):
    """The holder's identity, written IN PLACE into the file it holds.

    Never `os.replace`: a replacement gives the path a new inode, and the flock
    we hold would then guard a file nobody else opens — the lock would silently
    stop being a lock. In-place truncate-and-write is therefore the only shape
    available, and a reader can consequently catch a partial record. That is
    tolerated rather than prevented: `_read_land_lock` returns None for anything
    that is not complete JSON and the waiter then names the holder as
    "another conversation", which is a worse message and never a wrong wait."""
    body = json.dumps(record, sort_keys=True)[:4000] + "\n"
    handle.seek(0)
    handle.truncate()
    handle.write(body)
    handle.flush()
    try:
        os.fsync(handle.fileno())
    except OSError:
        pass


def _live_fence_lease(repo):
    """The holder record of a LIVE operator-fence land lease on `repo`, or None.

    Spec r3 e1 and Frank G2: this lander runs Git with core.hooksPath=/dev/null,
    so the Git fence never sees its merge. Waiting here on a live lease is
    therefore the ONLY thing that serializes the product lander against a lease
    holder, and it is required rather than optional.

    Read from the repository's own launcher (the switch and the lease home live
    there, Frank G10 and G12) and never from this process's environment. With the
    launcher absent or its state off this returns None at the first read, so the
    product path is unchanged while the switch is off (N1). Liveness is the
    holder's pid running with its recorded start time, the same test the fence
    makes; nothing is signaled."""
    try:
        rc, out, _err = W.git(str(repo), "rev-parse", "--path-format=absolute", "--git-common-dir")
        if rc != 0:
            return None
        # errors="replace": a hook that is not UTF-8 is simply not ours, and a
        # UnicodeDecodeError must never reach the product lander (Frank's #13).
        with open(os.path.join(out.strip(), "hooks", "reference-transaction"), encoding="utf-8",
                  errors="replace") as handle:
            text = handle.read(65536)
    except OSError:
        return None
    if "richos-operator-fence-launcher" not in text:
        return None
    conf = dict(re.findall(r'(?m)^OPERATOR_FENCES_([A-Z_]+)="([^"]*)"\s*$', text))
    if conf.get("STATE") != "on" or not conf.get("HOME") or not conf.get("KEY"):
        return None
    lease = W.read_json(os.path.join(conf["HOME"], conf["KEY"] + ".lease"))
    holder = (lease or {}).get("holder")
    if not isinstance(holder, dict):
        return None
    state, started = W.process_start(holder.get("pid"))
    if state != "ok":
        return None
    try:
        epoch = calendar.timegm(time.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, OverflowError):
        return None
    return holder if abs(epoch - int(holder.get("start", -1))) <= 1 else None


def _land_holder_text(holder):
    if not holder:
        return "another conversation, which left no readable record in the lock file"
    return "conversation thread %s of company %s (pid %s), landing since %s" % (
        holder.get("thread_id") or "an unnamed thread", holder.get("entity_id") or "an unnamed company",
        holder.get("pid") or "unknown", holder.get("since") or "an unrecorded time")


@contextlib.contextmanager
def land_lock(scope, repo):
    """Hold this repository's land for the whole land: the recorded-tip check,
    the fast-forward, and the workspace cleanup that deletes worktrees and
    branches in the same repository.

    TAKEN BEFORE `locked(scope)`, AND THAT ORDER IS THE POINT. A wait here can
    be minutes long and belongs to ANOTHER conversation; holding this
    conversation's own receipt lock across it would freeze its `prepare`,
    `inspect` and — worst — `observe`, which runs from the PostToolUse hook of
    every tool call every one of its agents makes. The repository is read under
    the receipt lock, the receipt lock is released, this one is taken, and then
    every record is re-read from disk: the only value carried across the gap is
    the repository path, which `prepare` has already made immutable for a
    receipt, and which is asserted again on the far side.

    WAITING, NOT FAILING, AND IT SAYS SO. The second lander blocks and reports
    what it waited for; it never returns a refusal that would send finished,
    reviewed work back for a fresh implementation.

    THE ORDER AMONG WAITERS IS THE KERNEL'S, NOT A TICKET QUEUE, and that is a
    deliberate limit rather than an oversight. A ticket file is not released by
    the kernel when its holder dies, so a first-come queue would have to decide
    whether a waiter is still alive — the one question this subsystem refuses to
    ask of a process, and the reason `flock` is used throughout it. At the
    cardinality the CEO actually runs (a few threads, each landing rarely)
    starvation is not a real risk; if it ever becomes one, the shape that keeps
    the kernel's guarantee is a per-waiter ticket that each waiter flocks itself.

    RELEASED BY THE KERNEL. Nothing here has to run for the lock to go: the fd
    closes with the process."""
    path = land_lock_path(repo)
    timeout = land_lock_timeout()
    binding = scope.get("binding") or {}
    mine = {"schema": 1, "repository": str(repo), "canonical": canonical_repository(repo), "pid": os.getpid(),
            "entity_id": binding.get("entity_id") or "", "thread_id": binding.get("thread_id") or "",
            "session_id": binding.get("session_id") or "", "state": "landing", "since": W.iso()}
    started = time.monotonic()
    holder = None
    handle = os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+")
    try:
        while True:
            leased = None
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.EACCES):
                    raise
            else:
                # A land lease is taken and released under this same flock
                # (land-lease.sh's check-and-set), so while we hold it no lease
                # can appear: checking here, and letting go while one is live,
                # is race-free. Off or absent fence: None, and nothing changes.
                leased = _live_fence_lease(repo)
                if leased is None:
                    break
                fcntl.flock(handle, fcntl.LOCK_UN)
            if leased is not None:
                holder = {"thread_id": "an operator land lease (%s, pid %s)" % (
                    leased.get("kind") or "holder", leased.get("pid")), "pid": leased.get("pid"),
                    "entity_id": "the operator's own team", "since": "its lease"}
            else:
                holder = _read_land_lock(path) or holder
            waited = time.monotonic() - started
            if waited >= timeout:
                raise ValueError(
                    "this repository's land is held by %s and did not finish within %.0f seconds, so "
                    "nothing here was merged and nothing was cleaned up. Two conversations may share a "
                    "repository and their lands take turns; this one waited rather than refusing, "
                    "because a refused land sends finished, reviewed work back for a fresh "
                    "implementation and a fresh review. The bound is not about a holder that crashed "
                    "— the kernel releases that lock the moment its process dies — it is about one "
                    "that is alive and stuck, and a land is local Git only (integrate never pushes), "
                    "so %.0f seconds is far above any real one. Retry once that land has finished."
                    % (_land_holder_text(holder), timeout, timeout))
            time.sleep(min(0.5, 0.01 + waited / 20.0))
        status = {"repository": str(repo), "lock": str(path), "record": W.land_record_path(repo),
                  "waited_seconds": round(time.monotonic() - started, 3)}
        if holder is not None:
            status["waited_for"] = _land_holder_text(holder)
            # WHAT THE LAST LANDER DID IS READ FROM THE HISTORY, NOT FROM THE
            # LOCK. It used to be a `landed` field on the holder's own record,
            # which the next holder overwrites in place — so the second of two
            # lands in a row erased the first, and an agent whose snapshot
            # predated it saw a move nothing could name.
            previous = W.land_records(repo)[-1:]
            if previous and previous[0].get("thread_id") == holder.get("thread_id"):
                status["waited_for_land"] = previous[0]
        _write_land_lock(handle, mine)
        try:
            yield status
        finally:
            mine["state"] = "released"
            mine["until"] = W.iso()
            try:
                _write_land_lock(handle, mine)
            except OSError:
                pass
    finally:
        handle.close()


def require_current_assignment(scope, record):
    obligation = carried_obligation(scope)
    if obligation is not None and record.get("request", {}).get("obligation_id") != obligation:
        raise ValueError("receipt belongs to another assignment; prepare work for the assignment this connection carries")


def integrate(scope_path,scope,args):
    if set(args)!={"worker_id","reviewer_id"}: raise ValueError("integration needs the worker and reviewer receipts")
    # The repository is read under this conversation's own receipt lock, which
    # is then RELEASED before the repository land lock is taken: see land_lock()
    # for why a wait that belongs to another conversation must not be held
    # across this one's prepare/inspect/observe. Nothing but the repository path
    # crosses the gap, and it is asserted again on the far side.
    with locked(scope) as root:
        worker=read_record(root,args["worker_id"])
        require_current_assignment(scope,worker)
        require_current_assignment(scope,read_record(root,args["reviewer_id"]))
        repository=worker["request"]["repo"]
    with land_lock(scope,repository) as land:
        with locked(scope) as root:
            worker=refresh(read_record(root,args["worker_id"]))
            require_current_assignment(scope,worker)
            # The repository is fixed on a receipt at prepare time, so this can
            # only be an impossible state -- and an unchecked impossible state
            # here would mean landing one repository under another's lock.
            if worker["request"]["repo"]!=repository:
                raise ValueError("this receipt named another repository between being read and being locked")
            reviewer=refresh(read_record(root,args["reviewer_id"]))
            require_current_assignment(scope,reviewer)
            path=root/(worker["id"]+".json")
            existing=worker.get("integration")
            if existing and existing["reviewer_id"] != reviewer["id"]:
                raise ValueError("integration already has a different reviewer; reconcile its receipt")
            if existing and existing.get("verified"):
                verification_evidence(scope,worker["id"])
            else:
                if worker["status"]!="run-ended" or reviewer["status"]!="run-ended":
                    raise ValueError("both provider runs must have an observed end before integration")
                target=target_workspace(worker)
                review_target=target_workspace(reviewer)
                commit=git(target["path"],"rev-parse","HEAD")
                if reviewer.get("review_target")!={"worker_id":worker["id"],"commit":commit}:
                    raise ValueError("worker commit changed or this reviewer reviewed another assignment")
                report=reviewer.get("review_observation",{})
                if not report.get("valid") or report.get("report",{}).get("verdict")!="passed":
                    raise ValueError("the actual reviewer has not returned a passing review")
                if git(review_target["path"],"rev-parse","HEAD")!=commit:
                    raise ValueError("reviewer changed its commit; a fresh independent review is required")
                repo=worker["request"]["repo"]
                if repo not in repositories(scope): raise ValueError("target repository is no longer connected")
                canonical=W.load_agent(worker["workspace_ref"])
                branch,tip,problem=W.integration_target([canonical],repo)
                if problem: raise ValueError(problem)
                if git(repo,"symbolic-ref","--short","HEAD")!=branch:
                    raise ValueError("select the recorded integration branch before integrating")
                for tree in (repo,target["path"],review_target["path"]):
                    if git(tree,"status","--porcelain","--untracked-files=all"):
                        raise ValueError("integration preserves local edits; reconcile the dirty checkout first")
                    for marker in ("MERGE_HEAD","CHERRY_PICK_HEAD","REVERT_HEAD","rebase-merge","rebase-apply"):
                        if Path(git(tree,"rev-parse","--path-format=absolute","--git-path",marker)).exists():
                            raise ValueError("finish or explicitly abandon the existing Git operation first")
                # No rebase, conflict resolution or merge commit is inferred here. A
                # moved target requiring new changes needs another implementation/review.
                if not existing:
                    git(repo,"merge-base","--is-ancestor",tip,commit)
                    worker["integration"]={"reviewer_id":reviewer["id"],"commit":commit,"branch":branch,
                        "before":tip,"instruction_ref":scope.get("user_instruction",{}).get("ledger_ref"),"verified":False}
                    save(path,worker)
                elif existing["commit"]!=commit or existing["branch"]!=branch:
                    raise ValueError("prepared integration identity changed")
                read_scope(scope_path)
                if tip!=commit:
                    if tip!=worker["integration"]["before"]:
                        raise ValueError("integration target moved after intent; reconcile before retrying")
                    git(repo,"merge","--ff-only",commit)
                    # THE LAND RECORD, WRITTEN AT THE MOMENT THE REF ACTUALLY
                    # MOVED and while this repository's land lock is still held.
                    # APPENDED, never a field on the lock: two lands in a row
                    # both survive, so a running agent in the OTHER conversation
                    # can be told which thread moved the branch under it rather
                    # than that it moved (workspaces.py,
                    # `land_by_another_conversation`). Here and not at release
                    # because a crash between the two would leave a ref that
                    # moved with no record of who moved it -- and a REPEATED
                    # integrate, which merges nothing, must not record a second
                    # land it did not perform.
                    land["landed"]={"schema":1,"branch":branch,"before":tip,"commit":commit,"at":W.iso(),
                        "thread_id":scope["binding"].get("thread_id") or "","entity_id":scope["binding"].get("entity_id") or "",
                        "session_id":scope["binding"].get("session_id") or "","pid":os.getpid()}
                    W.append_land_record(repository,land["landed"])
                git(repo,"merge-base","--is-ancestor",commit,"refs/heads/"+branch)
                worker["integration"]["verified"]=True
                worker["status"]="integrated"
                save(path,worker)
            # Cleanup remains canonical Mega Lander. Its result is separate from Git
            # integration; partial cleanup never rolls back a verified target commit.
            # A revision can leave earlier review workspaces outside the worker's
            # canonical continuation chain. Include those reviews in the same safe
            # cleanup attempt, including a rejected review whose commit is now an
            # ancestor of the integrated fix. Canonical land still decides eligibility.
            ancestors={worker["id"]}
            ancestor=worker
            while ancestor.get("continuation"):
                previous=ancestor["continuation"]["worker_id"]
                if previous in ancestors or len(ancestors)>=50:
                    raise ValueError("invalid or excessive continuation chain; reconcile before cleanup")
                ancestor=read_record(root,previous)
                if any(ancestor["request"][key] != worker["request"][key] for key in ("obligation_id","repo","role")):
                    raise ValueError("continuation cleanup cannot cross its assignment or repository")
                ancestors.add(previous)
            reviews=[refresh(record) for _,record in receipts(root)
                if record["request"]["role"]=="reviewer" and record.get("review_target",{}).get("worker_id") in ancestors]
            failures=[]
            for record in [worker,*reviews]:
                try:
                    read_scope(scope_path)
                    result = W.land(record["workspace_ref"],me=scope["binding"]["session_id"])
                    if not result.get("landed") or result.get("cleanup_pending"):
                        raise ValueError(f"Workspace cleanup for {record['name']} remains pending; its reviewed commit is still integrated.")
                except Exception as error: failures.append(str(error)[-4000:])
            worker["integration"]["cleanup_pending"]=failures
            save(path,worker); project(scope,path,worker)
            for reviewed in reviews:
                project(scope,root/(reviewed["id"]+".json"),reviewed)
            return {"work_integrated":True,"commit":worker["integration"]["commit"],
                "cleanup_pending":failures,"evidence_ref":verification_evidence(scope,worker["id"]),
                "obligation_closed":False,"published":False,"land_lock":dict(land)}


OPEN_ASSIGNMENT_STATUSES = ("candidate", "accepted", "active", "pending", "blocked")


def assignment_state(scope, assignment):
    """open, settled or absent -- read from the obligation, never from its workers.

    An assignment whose workers have all stopped is NOT settled: that is exactly
    the state where it has run, stopped at integrate and is waiting for him
    (5.4). Settled means the obligation itself is closed. Getting this wrong
    would release the seat of the one case the whole plan turns on.
    """
    if not isinstance(assignment, str) or not assignment.strip():
        return "absent"
    try:
        item = ecs(scope, {"protocol":1,"command":"inspect","binding":scope["binding"],
                           "query":{"item_id":assignment}})["item"]
    except Exception as error:
        if "item is absent" not in str(error):
            raise
        return "absent"
    return "open" if item["status"] in OPEN_ASSIGNMENT_STATUSES else "settled"


def conversation_threads():
    """WHICH CONVERSATION THREADS EXIST -- the app's own knowledge, read from the
    app's own record, because the store does not have it and says so: "Whether a
    conversation thread still exists is the app's knowledge; what the store can
    prove is movement" (ecs/CONTRACT.md).

    `conversation-ledger.jsonl` under `$RICHOS_APP_STATE`. The two are the same
    directory by construction rather than by convention: `src-tauri/src/main.rs`
    opens the ledger at `data_dir.join("conversation-ledger.jsonl")` (:1461) and
    hands that same `data_dir` to `EngineProfile::prepare` (:1852 ->
    engine_profile.rs:45-53), which canonicalizes it and exports it as
    `RICHOS_APP_STATE` (:205).

    A THREAD IS NEVER DELETED FROM THAT LOG. `KNOWN_EVENT_TAGS` in ledger.rs has
    `ThreadCreated` and no removal of any kind, so "this thread still exists" is
    "the ledger names it", and an orphan seat is one for a thread the app's own
    record has never heard of -- a ledger replaced or reset out from under a
    store that kept its seats.

    RETURNS None RATHER THAN AN EMPTY SET when the question could not be asked:
    no file, an unreadable one, or one that names no thread at all. Absence is
    never evidence, and here the difference between "no threads" and "could not
    look" is the difference between deleting every one of his seats and deleting
    none of them."""
    try:
        path = state() / "conversation-ledger.jsonl"
        if not path.is_file():
            return None
        threads = set()
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                # The cheap filter first: this file carries every turn and every
                # assistant delta, and a thread record is a few lines in it.
                if '"ThreadCreated"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue            # a record this build cannot read names no thread
                if isinstance(row, dict) and row.get("event") == "ThreadCreated" and row.get("thread_id"):
                    threads.add(str(row["thread_id"]))
        return threads or None
    except (OSError, ValueError, KeyError):
        return None


def reconcile_seats(scope):
    """Orphan seats, walked beside orphan grants and for the same reason (6.3a).

    A grant with no assignment behind it is a defect and so is a seat, and the
    seat is the half that survives a crash: a grant is a file the lease shutdown
    rewrites, a seat is a durable row. A seat that cannot be released is
    REPORTED, because a reconciliation that silently skips what it could not do
    is a clean bill of health signed by nobody.

    TWO KINDS OF SEAT ARE RECONCILED HERE, AND THEY ARE ASKED DIFFERENT
    QUESTIONS. A work seat is one per assignment, and its question is the
    obligation's state. HIS OWN SEAT IS ONE PER CONVERSATION THREAD since
    2026-09-17 (ecs/CONTRACT.md), and its question is whether that thread still
    exists -- which only the app knows, so `assignment_state` is not asked of it
    at all. Until this arm existed his thread seats were enumerated by `seats`
    and then skipped by the `audience != "worker"` filter above, so an orphan
    one would have lived forever.

    HIS LEGACY CURSOR IS NEVER TOUCHED, AND NEITHER IS A LIVE THREAD'S SEAT.
    Both kinds are identified POSITIVELY -- a work seat by its own audience, one
    of his by `ECS.is_ceo_row`, which re-derives the seat from the row's own
    thread rather than comparing a person against a literal. `ceo-default` is
    refused by name here and refused again in the store. "Everything that is not
    his" is the reasoning that deletes his cursor after a crash, and "everything
    that is not ceo-default" is the same mistake one thread later.

    A RELEASE OF ONE OF HIS CARRIES THE REVISION IT WAS ENUMERATED AT, which is
    the store's own independent liveness proof: a seat that has bound a turn
    since the enumeration belongs to a demonstrably live thread and the release
    is refused rather than racing the front desk that is using it.
    """
    binding = scope["binding"]
    report = {"released": [], "retained": [], "unreconciled": []}
    known = []          # the app's thread list, read at most once and only if one of his is here
    for row in ecs(scope, {"protocol":1,"command":"seats","binding":binding})["seats"]:
        his = ECS.is_ceo_row(row) and row["person_id"] != ECS.PERSON_ID
        if not his and row["audience"] != "worker":
            continue
        if row["entity_id"] != binding["entity_id"]:
            continue  # another company's partition is not this scope's to reconcile
        if not his and row["thread_id"] != binding["thread_id"]:
            continue  # a work seat is bound inside this thread; another thread's is not ours
        if his:
            # One of his thread seats is in ANOTHER thread by construction --
            # that is what makes it reconcilable from here at all -- so the
            # boundary it keeps is the company's, checked above.
            seat = row["person_id"]
            try:
                if row["thread_id"] == binding["thread_id"]:
                    report["retained"].append({"seat":seat, "thread":row["thread_id"],
                                               "reason":"this conversation"})
                    continue
                if not known:
                    known.append(conversation_threads())
                if known[0] is None:
                    report["unreconciled"].append({"seat":seat, "thread":row["thread_id"],
                        "reason":"the app's conversation ledger could not be read, so whether that "
                                 "thread still exists is unknown -- and an unknown is never a release"})
                    continue
                if row["thread_id"] in known[0]:
                    report["retained"].append({"seat":seat, "thread":row["thread_id"], "reason":"open"})
                    continue
                ecs(scope, {"protocol":1,"command":"release-seat","binding":binding,
                            "person_id":seat, "reason":"thread absent",
                            "expected_revision":int(row["revision"]),
                            "request_id":f"reconcile-seat:{seat}:{row['revision']}",
                            "source_ref":f"app-reconcile:{seat}:{row['revision']}"})
                report["released"].append({"seat":seat, "thread":row["thread_id"],
                                           "reason":"thread absent"})
            except Exception as error:
                report["unreconciled"].append({"seat":seat, "thread":row["thread_id"],
                                               "reason":str(error)[:400]})
            continue
        assignment, seat = row["turn_id"], row["person_id"]
        try:
            state = assignment_state(scope, assignment)
            if state == "open":
                report["retained"].append({"seat":seat, "assignment":assignment})
                continue
            ecs(scope, {"protocol":1,"command":"release-seat","binding":binding,
                        "person_id":seat, "reason":state,
                        "request_id":f"reconcile-seat:{seat}:{row['revision']}",
                        "source_ref":f"app-reconcile:{seat}:{row['revision']}"})
            report["released"].append({"seat":seat, "assignment":assignment, "reason":state})
        except Exception as error:
            report["unreconciled"].append({"seat":seat, "assignment":assignment,
                                           "reason":str(error)[:400]})
    return report


def completion_path(scope, identity):
    if not isinstance(identity, str) or not re.fullmatch(r"[a-f0-9]{64}", identity):
        raise ValueError("invalid completion identity")
    return folder(scope) / ("completion-" + identity + ".receipt")


def completion_evidence(scope, obligation, worker_ids):
    rows = [refresh(record) for _, record in receipts(folder(scope))
            if record["request"]["obligation_id"] == obligation]
    if any(record["status"] in ("preparing", "prepared", "dispatching", "running", "unknown") for record in rows):
        raise ValueError("this assignment still has unresolved execution; reconcile it before completion")
    workers = [record for record in rows if record["request"]["role"] == "worker"]
    continued = {record["continuation"]["worker_id"] for record in workers if record.get("continuation")}
    final = [record for record in workers if record["id"] not in continued]
    if not final or sorted(record["id"] for record in final) != worker_ids:
        raise ValueError("completion must include every final worker for this assignment, without unrelated receipts")
    evidence = []
    for record in final:
        if record.get("integration", {}).get("cleanup_pending") != []:
            raise ValueError("finish the assignment's pending workspace cleanup before completion")
        evidence.append(verification_evidence(scope, record["id"]))
    return sorted(evidence)


def verify_completion(scope, identity):
    receipt = bounded(completion_path(scope, identity))
    if receipt.get("schema") != 1 or any(receipt["binding"][key] != scope["binding"][key] for key in ("entity_id", "thread_id")):
        raise ValueError("completion receipt has an unsupported schema or different scope")
    evidence = completion_evidence(scope, receipt["obligation_id"], receipt["worker_ids"])
    if receipt["evidence"] != evidence:
        raise ValueError("completion evidence changed; reconcile the assignment")
    return receipt


def complete(scope_path, scope, args):
    # **THE SAME DERIVATION `prepare` MAKES, AND IT IS NOT A SECOND FEATURE.** This
    # is the call that CLOSES the assignment, so a guessed obligation here means a
    # job that did all its work and never finished: the host's settle reading finds
    # the obligation still open and reports a failure over work that actually
    # landed. Fixing only `prepare` would have moved the defect one step later and
    # made it harder to see.
    if set(args) - {"obligation_id", "worker_ids"} or "worker_ids" not in args:
        raise ValueError("completion requires an obligation and its complete final worker set")
    obligation = carried_obligation(scope) or text(args, "obligation_id")
    ids = args["worker_ids"]
    if not isinstance(ids, list) or not 1 <= len(ids) <= 50 or any(not isinstance(i, str) or not re.fullmatch(r"[a-f0-9]{64}", i) for i in ids) or len(set(ids)) != len(ids):
        raise ValueError("worker_ids must contain one to fifty distinct work receipt identities")
    ids = sorted(ids)
    instruction = scope.get("user_instruction", {}).get("ledger_ref")
    if not instruction: raise ValueError("completion requires the current visible user turn")
    identity = hashlib.sha256(json.dumps([obligation, ids], separators=(",", ":")).encode()).hexdigest()
    with locked(scope):
        evidence = completion_evidence(scope, obligation, ids)
        path = completion_path(scope, identity)
        if path.exists():
            receipt = verify_completion(scope, identity)
        else:
            item = ecs(scope, {"protocol":1, "command":"inspect", "binding":scope["binding"], "query":{"item_id":obligation}})["item"]
            if item["status"] not in ("accepted", "active", "pending", "blocked"):
                raise ValueError("only an open assignment can be completed with new evidence")
            receipt = {"schema":1, "binding":scope["binding"], "obligation_id":obligation,
                "worker_ids":ids, "evidence":evidence, "expected_revision":item["revision"],
                "source_ref":instruction, "evidence_ref":"app-completion:"+identity, "verified":False}
            save(path, receipt)
        read_scope(scope_path)
        result = ecs(scope, {"protocol":1, "command":"complete-obligation",
            "binding":scope["binding"], "completion_id":identity})
        receipt["verified"] = True
        save(path, receipt)
        return {**result, "evidence":evidence, "published":False}


def call(scope_path, name, args):
    scope = read_scope(scope_path)
    if not isinstance(args,dict): raise ValueError("tool arguments must be an object")
    if name == "repositories": return {"repositories":repositories(scope)}
    if name == "prepare": return prepare(scope_path,scope,args)
    if name == "integrate": return integrate(scope_path,scope,args)
    if name == "complete": return complete(scope_path,scope,args)
    if name == "inspect":
        if set(args) - {"offset","limit"}: raise ValueError("unsupported inspection fields")
        offset,limit = args.get("offset",0),args.get("limit",20)
        if type(offset) is not int or offset<0 or type(limit) is not int or not 1<=limit<=50: raise ValueError("invalid inspection page")
        with locked(scope) as root:
            obligation = carried_obligation(scope)
            rows = [(path,record) for path,record in receipts(root)
                    if obligation is None or record["request"]["obligation_id"] == obligation]; result=[]
            for path,record in rows[offset:offset+limit]:
                refresh(record);save(path,record);project(scope,path,record);result.append(view(record))
            page = {"records":result,"next_offset":offset+limit if offset+limit<len(rows) else None}
            # Seats are reconciled with receipts, on the sweep rather than per
            # page, and only from the conversation's own scope: enumerating or
            # releasing seats is the host's job and the engine refuses it to a
            # work seat.
            if offset == 0 and scope.get("seat") is None:
                page["seats"] = reconcile_seats(scope)
            return page
    raise ValueError("unknown app work tool")


TOOLS = [
    {"name":"complete","description":"Close a code assignment in ECS only after every requirement is satisfied and every final worker has a passing independent review, verified local integration and completed cleanup. Your connection already knows which assignment you are carrying, so leave obligation_id out; never invent one. Supply all final worker receipts, across every repository. Unresolved execution or omitted work is refused. Do not use this to claim unrelated or unverified business outcomes. Local completion never means publication.","inputSchema":{"type":"object","properties":{"obligation_id":{"type":"string"},"worker_ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":50}},"required":["worker_ids"],"additionalProperties":False}},
    {"name":"repositories","description":"List repositories explicitly connected to this company. A company folder alone grants no execution access.","inputSchema":{"type":"object","properties":{},"additionalProperties":False}},
    {"name":"prepare","description":"Prepare an isolated generic worker or reviewer for the assignment this connection is carrying. Your connection already knows which assignment that is, so leave obligation_id out; never invent one. Persists intent before workspace creation. Returns agent_payload only while no dispatch has been attempted. Submit that exact JSON to Agent once. Preparation is not dispatch or completion. Reuse request_id for retries; uncertain work must be inspected first. To continue settled work, set continue_of to its worker receipt: the new worker starts at its actual saved commit. Dirty work is preserved and refused until its uncommitted files are reconciled. Never reset or discard those files to bypass the refusal. If this same worker also needs a workspace in other connected repositories, name them in repos; each gets its own isolated workspace, all under the one worker.","inputSchema":{"type":"object","properties":{**{key:{"type":"string"} for key in ("request_id","obligation_id","repo","title","brief","role","integration","base","review_of","continue_of")},"repos":{"type":"array","items":{"type":"string"},"maxItems":8}},"required":["request_id","repo","title","brief"],"additionalProperties":False}},
    {"name":"integrate","description":"After an authorized implementation and an actual passing independent review, fast-forward the recorded clean integration branch to the exact reviewed commit and clean up through Mega Lander. No push, rebase or conflict resolution. Dirty or moved targets are preserved and refused. This verifies one work result; it does not close the entire obligation.","inputSchema":{"type":"object","properties":{"worker_id":{"type":"string"},"reviewer_id":{"type":"string"}},"required":["worker_id","reviewer_id"],"additionalProperties":False}},
    {"name":"inspect","description":"Reconcile scoped dispatch receipts against actual provider and workspace observations. A run ending is not task completion. Inspect unresolved work before retrying after a restart.","inputSchema":{"type":"object","properties":{"offset":{"type":"integer"},"limit":{"type":"integer"}},"additionalProperties":False}},
]
if __name__ == "__main__":
    if len(sys.argv)!=2: raise SystemExit("an explicit app scope is required")
    transport=load("richos_work_mcp_transport",ENGINE / "ecs/adapters/mcp.py")
    transport.serve(sys.argv[1],sys.stdin.buffer,sys.stdout,tools=TOOLS,handler=call,server_name="richos_work")
