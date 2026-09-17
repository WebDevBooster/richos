# SPDX-License-Identifier: AGPL-3.0-only
"""Durable per-turn checkpoints independent of the assistant's visible reply."""
from __future__ import annotations

import hashlib
import json
import uuid

from ecs_core import EventStore, PERSON_ID, SECRET_VALUE_PATTERNS, ScopeError, ValidationError, canonical_json, _validate_text
from ecs_extract import MAX_STATEMENTS_PER_TURN, Statement, TurnScope, apply_statements


def checkpoint_template(store: EventStore, *, session: str, person_id: str = PERSON_ID) -> dict:
    """Read a write fence only for the caller-named session. Never auto-save.

    ``person_id`` is WHOSE cursor the fence is read from -- the conversation
    thread's own seat, or the legacy single cursor when no seat is named. It
    defaults to the literal this file used to hard-code, so every caller that
    predates seats reads exactly the row it always read.
    """
    context = store.current_context(person_id)
    if not context or context["session_id"] != session or not context["turn_id"]:
        raise ScopeError("no active turn for the requested session; do not borrow another session's context")
    return {"context": {"session": session, "turn": context["turn_id"],
                        "revision": context["revision"], "request_id": uuid.uuid4().hex},
            "checkpoint": {"statements": []}}


def resolve_request(document: dict, **flags) -> tuple[dict, dict]:
    """Accept an explicit envelope or legacy flags, never silently infer a fence."""
    from_template = isinstance(document, dict) and ("context" in document or "checkpoint" in document)
    if from_template:
        if set(document) != {"context", "checkpoint"} or not isinstance(document["context"], dict):
            raise ValidationError("checkpoint envelope requires context and checkpoint only")
        fence = document["context"]
        if set(fence) != {"session", "turn", "revision", "request_id"}:
            raise ValidationError("context requires session, turn, revision and request_id")
        if any(value is not None and value != fence[key] for key, value in flags.items()):
            raise ValidationError("checkpoint flags conflict with the saved context; regenerate after checking the current turn")
        request = document["checkpoint"]
    else:
        fence, request = flags, document
    if (type(fence.get("revision")) is not int or fence["revision"] < 1
            or any(not isinstance(fence.get(key), str) or not fence[key].strip()
                   for key in ("session", "turn", "request_id"))):
        raise ValidationError("checkpoint needs explicit session, turn, revision and request_id; use checkpoint-template --session <this-session-id>")
    return request, fence


def material_checkpoints(conn, entity: str, thread: str, turns: set[str]) -> dict:
    """Latest explicit checkpoint per turn; ordinary reply prose cannot erase it.

    Conversely, a later malformed block must not be masked by an earlier valid
    receipt. A subsequent successful repair restores the recorded status.
    """
    result = {}
    for event in conn.execute(
        "SELECT event_type, payload_json FROM ecs_events WHERE entity_id=? AND thread_id=? "
        "AND event_type IN ('turn.checkpointed', 'turn.extracted') ORDER BY sequence", (entity, thread),
    ):
        row = json.loads(event["payload_json"])
        turn = row["turn_id"]
        if turn not in turns:
            continue
        structured = event["event_type"] == "turn.checkpointed"
        if not structured and (row["source_kind"] != "rich_reply" or not (row["block_present"] or row["rejected"])):
            continue
        valid = row["rejected"] == 0 and (row["applied"] > 0 or row.get("no_changes", False))
        result[turn] = {"status": "recorded" if valid else "rejected",
                        "source": "structured" if structured else "reply"}
    return result


def checkpoint_health(store: EventStore, entity: str, thread: str, turn: str) -> dict:
    """Check the persisted receipt, never the assistant's claim to have saved."""
    conn = store.connect()
    try:
        return material_checkpoints(conn, entity, thread, {turn}).get(turn, {"status": "missing", "source": "none"})
    finally:
        conn.close()


def checkpoint(store: EventStore, request: dict, *, session: str, turn: str,
               revision: int, request_id: str, person_id: str = PERSON_ID) -> dict:
    context = store.current_context(person_id)
    if (not context or context["session_id"] != session or context["turn_id"] != turn
            or context["revision"] != revision):
        raise ScopeError("checkpoint context changed; use the current session, turn and revision")
    if not isinstance(request, dict) or set(request) - {"statements", "no_changes", "reason"}:
        raise ValidationError("checkpoint accepts statements, no_changes and reason only")
    values = request.get("statements", [])
    no_changes = request.get("no_changes", False)
    if (not isinstance(values, list) or len(values) > MAX_STATEMENTS_PER_TURN
            or type(no_changes) is not bool):
        raise ValidationError("invalid checkpoint statements or no_changes")
    if no_changes:
        if values or not isinstance(request.get("reason"), str) or not request["reason"].strip():
            raise ValidationError("no_changes requires a reason and no statements")
    elif not values:
        raise ValidationError("empty checkpoint needs explicit no_changes and a reason")
    statements = []
    for number, value in enumerate(values, 1):
        if (not isinstance(value, dict) or set(value) != {"verb", "fields"}
                or not isinstance(value["verb"], str) or not isinstance(value["fields"], dict)
                or not all(isinstance(k, str) and isinstance(v, str) for k, v in value["fields"].items())):
            raise ValidationError("each statement needs verb and fields with string keys and values")
        _validate_text(value["verb"], "statement.verb", 40)
        statements.append(Statement(value["verb"], value["fields"], number,
                                    canonical_json({"request": request_id, "statement": value})))
    digest = hashlib.sha256(canonical_json(request).encode()).hexdigest()
    key = f"checkpoint:{session}:{turn}:{request_id}"
    prior = store.existing_event(key)
    if prior is not None:
        payload = json.loads(prior["payload_json"])
        if payload["request_sha256"] != digest:
            raise ValidationError("checkpoint request ID reused with different content")
        return checkpoint_receipt(store, session=session, turn=turn,
                                  request_id=request_id, person_id=person_id)

    payload = dict(turn_id=turn, request_id=request_id, request_sha256=digest,
                   statements=len(statements), applied=0, rejected=0,
                   no_changes=no_changes, reason=request.get("reason", ""))
    from ecs_core import _required, _validate_payload_text
    _required(payload, "request_id")
    _validate_payload_text(payload)
    # The statements this turn applies are CONVERSATIONAL_EVENTS, and _reduce
    # fences each one against the row belonging to the EVENT'S OWN person. On a
    # per-thread seat the hard-coded literal compared this thread's revision
    # against a row belonging to another thread -- or to no row at all -- which is
    # the work seat's bug (ecs_core.py:391 defaulting person_id) with the CEO on
    # both sides of it.
    scope = TurnScope(context["entity_id"], context["thread_id"], session, turn,
                      f"structured-checkpoint:{session}:{turn}:{request_id}",
                      context["person_id"])
    outcomes = apply_statements(store, statements, scope, active_revision=revision)
    payload["rejected"] = sum(o.status == "rejected" for o in outcomes)
    payload["applied"] = len(outcomes) - payload["rejected"]
    payload["outcomes"] = [dict(index=i, verb=o.statement.verb, status=o.status,
                                record_id=o.record_id, detail=safe_detail(o.detail))
                           for i, o in enumerate(outcomes, 1)]
    store.append("turn.checkpointed", entity_id=context["entity_id"],
                 thread_id=context["thread_id"], session_id=session,
                 source_ref=scope.source_ref, idempotency_key=key,
                 active_context_revision=revision, payload=payload,
                 actor_kind="extractor", actor_id="ecs-structured-checkpoint-v1")
    return receipt_result(payload, duplicate=False)


def safe_detail(detail: str) -> str:
    for pattern in SECRET_VALUE_PATTERNS:
        detail = pattern.sub("[redacted]", detail)
    return "".join(c for c in detail if ord(c) >= 32 or c in "\n\t")[:2000]


def receipt_result(payload: dict, *, duplicate: bool) -> dict:
    outcomes = payload.get("outcomes")
    return dict(payload, duplicate=duplicate, accepted=payload["rejected"] == 0,
                details_available=outcomes is not None,
                rejections=[o["detail"] for o in outcomes if o["status"] == "rejected"]
                if outcomes is not None else None)


def checkpoint_receipt(store: EventStore, *, session: str, turn: str, request_id: str,
                       person_id: str = PERSON_ID) -> dict:
    """Read a receipt without replaying statements or borrowing its old write fence."""
    prior = store.existing_event(f"checkpoint:{session}:{turn}:{request_id}")
    context = store.current_context(person_id)
    if (prior is None or not context or prior["entity_id"] != context["entity_id"]
            or prior["thread_id"] != context["thread_id"]):
        raise ScopeError("receipt is absent or outside the active scope")


    conn = store.connect()
    try:
        # The activation this receipt was written under is THIS seat's, in this
        # thread. Unscoped, the newest activation before the receipt could belong
        # to another conversation thread entirely -- with one cursor that could
        # only ever be his own previous turn, and with a seat per thread it is
        # whichever front desk happened to speak in between.
        activation = conn.execute(
            "SELECT payload_json FROM ecs_events WHERE event_type='thread.activated' "
            "AND person_id=? AND entity_id=? AND thread_id=? "
            "AND sequence < ? ORDER BY sequence DESC LIMIT 1",
            (context["person_id"], prior["entity_id"], prior["thread_id"], prior["sequence"])
        ).fetchone()
    finally:
        conn.close()
    audience = json.loads(activation["payload_json"]).get("audience") if activation else None
    levels = {"worker": 0, "rich": 1, "ceo": 2}
    if audience not in levels or levels[context["audience"]] < levels[audience]:
        raise ScopeError("receipt belongs to a more restricted audience")
    return receipt_result(json.loads(prior["payload_json"]), duplicate=True)
