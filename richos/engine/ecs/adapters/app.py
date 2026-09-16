# SPDX-License-Identifier: AGPL-3.0-only
"""Explicit app scope over the vendor-neutral ECS store. No cwd inference."""
from dataclasses import asdict
import hashlib
import json
from pathlib import Path

from ecs_core import EventStore, ScopeError, ValidationError, canonical_json
from ecs_checkpoint import checkpoint, checkpoint_receipt
from ecs_inspect import inspect_records

PROTOCOL_VERSION = 1
BINDING_FIELDS = ("entity_id", "thread_id", "session_id", "turn_id", "audience", "revision")


def required(document, key):
    value = document.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > 1024:
        raise ValidationError(f"{key} must be a nonempty bounded string")
    return value


def binding_of(row):
    return {key: row[key] for key in BINDING_FIELDS}


def fence(store, binding):
    if not isinstance(binding, dict) or set(binding) != set(BINDING_FIELDS):
        raise ScopeError("an explicit app entity/thread/session/turn/audience/revision binding is required")
    current = store.current_context()
    if current is None or binding_of(current) != binding:
        raise ScopeError("stale app binding; reconcile in its original scope before retrying")
    return current


def bind(store, request):
    scope = request.get("scope", {})
    if set(scope) != set(BINDING_FIELDS) - {"revision"}:
        raise ScopeError("bind requires explicit entity, thread, session, turn and audience")
    for key in scope:
        required(scope, key)
    source = required(request, "source_ref")
    request_id = required(request, "request_id")
    expected = request.get("expected_revision")
    if expected is not None and (type(expected) is not int or expected < 1):
        raise ValidationError("expected_revision must be a positive integer or null for first use")
    entity, thread, session = (scope[k] for k in ("entity_id", "thread_id", "session_id"))
    # Stable app identities are metadata. They are not claims about repository
    # ownership. The app repository registry owns those mappings separately.
    owner = f"app-entity:{entity}"
    common = dict(entity_id=entity, thread_id=thread, session_id=session,
                  actor_kind="app", actor_id="richos-app-v1", source_ref=source)
    for suffix, event, payload in (
        ("entity", "entity.registered", {"display_name": entity, "canonical_root": owner,
                                         "git_common_dir": owner, "status": "active"}),
        ("thread", "thread.created", {"title": thread}),
        ("session", "session.observed", {"vendor": "richos-app", "status": "active"}),
        ("active", "thread.activated", {"audience": scope["audience"], "turn_id": scope["turn_id"]}),
    ):
        store.append(event, **common, payload=payload,
                     expected_revision=expected if suffix == "active" else None,
                     idempotency_key=f"app-bind:{request_id}:{suffix}")
    current = store.current_context()
    if any(current[k] != value for k, value in scope.items()):
        raise ScopeError("binding was superseded; an old bind receipt cannot reactivate it")
    return {"binding": binding_of(current)}


def execute(state_root, request):
    if not isinstance(request, dict) or type(request.get("protocol")) is not int or request.get("protocol") != PROTOCOL_VERSION:
        raise ValidationError("unsupported ECS app protocol")
    command = required(request, "command")
    root = Path(state_root)
    if not root.is_absolute():
        raise ValidationError("ECS app state root must be explicit and absolute")
    if command == "hello":
        migrations = Path(__file__).resolve().parents[1] / "migrations"
        identity = hashlib.sha256()
        for file in sorted(migrations.glob("*.sql")):
            identity.update(file.name.encode())
            identity.update(file.read_bytes())
        return {"protocol": PROTOCOL_VERSION, "event_schema": 1,
                "migration_digest": identity.hexdigest(), "state_root": str(root),
                "commands": ["current", "bind", "checkpoint", "receipt", "brief", "inspect", "observe", "verified-work", "observation-receipt", "import-preview", "import-apply", "sync-loro-receipts", "complete-obligation"]}
    if command == "import-preview":
        from import_records import preview
        return preview(root, request.get("envelope"), request.get("target"))
    store = EventStore(root)
    if command == "current":
        current = store.current_context()
        return {"binding": binding_of(current) if current is not None else None}
    if command == "bind":
        return bind(store, request)
    binding = request.get("binding")
    context = fence(store, binding)
    if command == "sync-loro-receipts":
        from loro_receipts import synchronize
        result = synchronize(store, binding)
    elif command == "import-apply":
        from import_records import apply
        return apply(root, request.get("envelope"), binding)
    elif command == "checkpoint":
        document = request.get("checkpoint")
        if not isinstance(document, dict):
            raise ValidationError("checkpoint must be an object")
        # A model-authored checkpoint cannot certify external work. Cancellation
        # or rejection is still an explicit operational transition. Verified
        # completion must arrive through an app authority adapter.
        for statement in document.get("statements", []):
            if isinstance(statement, dict):
                fields = statement.get("fields", {})
                if isinstance(fields,dict) and fields.get("class") == "wiki_loro":
                    raise ValidationError("durable knowledge corrections must use the app's Loro proposal/confirmation desk; ECS consumes its writer receipt")
                if isinstance(fields, dict) and (fields.get("status") == "completed" or
                        (statement.get("verb") == "close" and "status" not in fields)):
                    raise ValidationError("completion needs an app verification receipt, not a checkpoint claim")
        result = checkpoint(store, document, session=context["session_id"], turn=context["turn_id"],
                            revision=context["revision"], request_id=required(request, "request_id"))
    elif command == "receipt":
        result = checkpoint_receipt(store, session=required(request, "session_id"),
                                    turn=required(request, "turn_id"), request_id=required(request, "request_id"))
    elif command == "brief":
        budget = request.get("budget_chars", 6000)
        if type(budget) is not int or not 900 <= budget <= 24000:
            raise ValidationError("brief budget must be between 900 and 24000 characters")
        result = {"text": store.compile_checkpoint(context["entity_id"], context["thread_id"],
                   expected_active_revision=context["revision"], session_id=context["session_id"], budget_chars=budget),
                  "inspection": inspect_records(store)}
    elif command == "inspect":
        query = request.get("query", {})
        if not isinstance(query, dict) or set(query) - {"section", "offset", "limit", "sequence", "item_id", "query", "include_closed"}:
            raise ValidationError("unsupported inspection fields")
        result = inspect_records(store, **query)
    elif command == "observation-receipt":
        event = store.existing_event(f"app-observe:{required(request, 'request_id')}")
        if event is None:
            result = {"observed": False}
        else:
            if event["entity_id"] != context["entity_id"] or event["thread_id"] != context["thread_id"]:
                raise ScopeError("observation receipt belongs to another scope")
            result = {"observed": True, "work": json.loads(event["payload_json"]),
                      "source_ref": event["source_ref"], "expected_revision": event["expected_revision"]}
    elif command == "complete-obligation":
        # Host-only: every final implementation must have actual review, Git and
        # cleanup evidence. A model checkpoint cannot certify this transition.
        import importlib.util
        spec=importlib.util.spec_from_file_location("richos_completed_work",Path(__file__).resolve().parents[2]/"mega-lander/app.py")
        work=importlib.util.module_from_spec(spec);spec.loader.exec_module(work)
        identity=required(request,"completion_id")
        receipt=work.verify_completion({"binding":binding},identity)
        payload={"item_id":receipt["obligation_id"],"status":"completed","evidence_ref":receipt["evidence_ref"]}
        key="app-complete:"+identity
        existing=store.existing_event(key)
        if existing:
            if (existing["entity_id"] != context["entity_id"] or existing["thread_id"] != context["thread_id"]
                    or json.loads(existing["payload_json"]) != payload or existing["source_ref"] != receipt["source_ref"]
                    or existing["expected_revision"] != receipt["expected_revision"]):
                raise ScopeError("completion receipt does not match its original scope or evidence")
        else:
            store.append("continuity.item_closed",entity_id=context["entity_id"],thread_id=context["thread_id"],
                session_id=context["session_id"],active_context_revision=context["revision"],
                actor_kind="authority_adapter",actor_id="richos-provider-v1",source_ref=receipt["source_ref"],
                idempotency_key=key,expected_revision=receipt["expected_revision"],payload=payload)
        result={"obligation_closed":True,"obligation_id":receipt["obligation_id"],"evidence_ref":receipt["evidence_ref"]}
    elif command in ("observe", "verified-work"):
        # Host-issued observations only. The app translates provider facts;
        # generic checkpoints cannot impersonate a task authority.
        payload = request.get("work")
        if not isinstance(payload, dict) or payload.get("authority") != "richos-provider-v1":
            raise ValidationError("unknown app task authority")
        if command == "verified-work":
            # This command is not exposed by the continuity MCP server. The app
            # work adapter must have a durable review/integration receipt and
            # Git must still prove the commit is in the recorded target branch.
            import importlib.util
            spec=importlib.util.spec_from_file_location("richos_verified_work",Path(__file__).resolve().parents[2]/"mega-lander/app.py")
            work=importlib.util.module_from_spec(spec);spec.loader.exec_module(work)
            evidence=work.verification_evidence({"binding":binding},payload.get("external_id"))
            if payload.get("status")!="completed" or payload.get("evidence_ref")!=evidence:
                raise ValidationError("completion does not match the verified Git receipt")
        elif payload.get("status") == "completed":
            raise ValidationError("provider completion is not verified assignment completion")
        result = asdict(store.append("work_unit.authority_completed" if command=="verified-work" else "work_unit.upserted", entity_id=context["entity_id"],
            thread_id=context["thread_id"], session_id=context["session_id"],
            active_context_revision=context["revision"], source_ref=required(request, "source_ref"),
            idempotency_key=f"app-observe:{required(request, 'request_id')}",
            expected_revision=request.get("expected_revision"),
            actor_kind="authority_adapter", actor_id="richos-provider-v1", payload=payload))
    else:
        raise ValidationError(f"unsupported ECS command: {command}")
    # A read racing a scope switch must not return the new scope's records to
    # the old caller. Mutations also carry the core's transactional fence.
    fence(store, binding)
    return result
