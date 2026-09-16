# SPDX-License-Identifier: AGPL-3.0-only
"""Versioned neutral import of obligations. No legacy database or command replay.

Only normal ECS domain events are written. The append-only import receipt records
intent before domain mutation so an interrupted application can reconcile by key.
Other domain types are explicitly unsupported until their adapter is supplied.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
from datetime import datetime, timezone

from ecs_core import EventStore, ValidationError, canonical_json, prepare_private_dir, PERSON_ID

SCHEMA = 1
FIELDS = {"type", "id", "digest", "entity_id", "person_id", "visibility", "created_at",
          "observed_at", "provenance", "evidence", "related", "supersedes", "authority", "confidence", "payload"}


def digest(value):
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def item_digest(item):
    return digest({key: value for key, value in item.items() if key != "digest"})


def identity(source, item):
    return digest({"system": source["system"], "namespace": source["namespace"], "id": item["id"]})


def text(value, label):
    if not isinstance(value, str) or not value.strip() or len(value) > 4000:
        raise ValueError(f"{label} must be a nonempty bounded string")
    return value


def receipt_state(root):
    file = Path(root) / "imports" / "receipts.jsonl"
    if not file.exists():
        return {}, {}
    items, batches = {}, {}
    with file.open() as handle:
        for line in handle:
            # A torn receipt is not silently discarded. Restore/review the
            # journal before continuing; the domain event remains independently durable.
            row = json.loads(line)
            if row["kind"] == "batch":
                batches[row["batch_id"]] = row
            else:
                items[row["key"]] = row
    return items, batches


def append_receipt(root, row):
    file = Path(root) / "imports" / "receipts.jsonl"
    descriptor = os.open(file, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
    try:
        data = (canonical_json(row) + "\n").encode()
        with os.fdopen(descriptor, "ab", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)


def validate_envelope(envelope):
    if not isinstance(envelope, dict) or set(envelope) != {"schema", "batch_id", "source", "items"}:
        raise ValidationError("import needs schema, batch_id, source and items")
    if type(envelope["schema"]) is not int or envelope["schema"] != SCHEMA:
        raise ValidationError("unsupported import schema; no records were imported")
    text(envelope["batch_id"], "batch_id")
    source = envelope["source"]
    if not isinstance(source, dict) or set(source) != {"system", "namespace", "revision", "layout"}:
        raise ValidationError("source requires explicit system, namespace, revision and layout")
    for key in source:
        text(source[key], f"source.{key}")
    if not isinstance(envelope["items"], list) or len(envelope["items"]) > 100:
        raise ValidationError("import batches contain at most 100 items")


def preview(root, envelope, target):
    """Read-only, including on a completely absent destination."""
    validate_envelope(envelope)
    if not isinstance(target, dict) or set(target) != {"entity_id", "thread_id", "person_id"}:
        raise ValidationError("an explicit target entity, thread and person is required")
    for field in target:
        text(target[field], f"target.{field}")
    if target["person_id"] != PERSON_ID:
        raise ValidationError("this store does not support the requested person")
    prior, batches = receipt_state(root)
    batch = batches.get(envelope["batch_id"])
    batch_digest = digest({"envelope": envelope, "target": target})
    if batch and batch["digest"] != batch_digest:
        raise ValidationError("batch ID reused with different content or target")
    source = envelope["source"]
    results = []
    ids = [item.get("id") for item in envelope["items"] if isinstance(item, dict)]
    for number, item in enumerate(envelope["items"]):
        row = {"index": number, "disposition": "invalid", "reason": "", "missing_evidence": []}
        try:
            if not isinstance(item, dict) or set(item) != FIELDS:
                raise ValueError("item is missing required metadata or has unsupported fields")
            text(item["id"], "id")
            if ids.count(item["id"]) != 1:
                raise ValueError("source record ID appears more than once in this batch")
            row["source_id"] = item["id"]
            if item["type"] != "obligation":
                row.update(disposition="unsupported", reason="this adapter imports obligations only; use the owning domain adapter")
                results.append(row)
                continue
            if item["person_id"] != target["person_id"] or item["entity_id"] != target["entity_id"]:
                raise ValueError("item and explicit destination scope disagree")
            if item["visibility"] not in {"ceo_private", "rich", "worker"}:
                raise ValueError("unknown ECS visibility; no widening is inferred")
            for key in ("created_at", "observed_at"):
                stamp = item[key]
                if stamp is not None:
                    parsed = datetime.fromisoformat(text(stamp, key).replace("Z", "+00:00"))
                    if parsed.tzinfo is None:
                        raise ValueError(f"{key} requires a timezone or null for unknown")
            if not isinstance(item["provenance"], dict) or set(item["provenance"]) != {"ref"}:
                raise ValueError("provenance requires an explicit ref")
            text(item["provenance"]["ref"], "provenance.ref")
            if item["authority"] not in {"self", "internal", "external", "unknown"}:
                raise ValueError("unknown authority")
            if type(item["confidence"]) not in (int, float) or not 0 <= item["confidence"] <= 1:
                raise ValueError("confidence must be between zero and one")
            if not isinstance(item["evidence"], list) or len(item["evidence"]) > 100:
                raise ValueError("evidence must be a bounded list of references")
            for evidence in item["evidence"]:
                if not isinstance(evidence, dict) or set(evidence) != {"ref", "available"} or type(evidence["available"]) is not bool:
                    raise ValueError("evidence requires ref and explicit availability")
                text(evidence["ref"], "evidence.ref")
                if not evidence["available"]:
                    row["missing_evidence"].append(evidence["ref"])
            if not isinstance(item["related"], list) or not all(isinstance(ref, str) for ref in item["related"]):
                raise ValueError("related must be source IDs")
            if item["supersedes"] is not None:
                row.update(disposition="unsupported", reason="supersession needs a reviewed domain operation; old records remain unchanged")
                results.append(row)
                continue
            if item["digest"] != item_digest(item):
                raise ValueError("item digest does not match its content")
            payload = item["payload"]
            if not isinstance(payload, dict) or set(payload) != {"title", "details", "status"}:
                raise ValueError("obligation payload requires title, details and original status")
            text(payload["title"], "title")
            if not isinstance(payload["details"], str) or len(payload["details"]) > 8000:
                raise ValueError("details must be bounded text")
            text(payload["status"], "original status")
            key = identity(source, item)
            row.update(key=key, target_id="import-" + key, disposition="importable")
            old = prior.get(key)
            if old:
                if old["digest"] != item["digest"] or old["target"] != target:
                    row.update(disposition="conflicting", reason="source identity was already mapped with different content or scope")
                elif old["kind"] == "applied":
                    row.update(disposition="already_imported", reason="durable receipt already exists")
                else:
                    row.update(reason="unfinished intent will reconcile through its existing domain idempotency key")
            mappings = []
            for ref in item["related"]:
                related_key = identity(source, {"id": ref})
                related = prior.get(related_key)
                if not related or related["kind"] != "applied" or related["target"] != target or related["item"]["visibility"] != item["visibility"]:
                    row.update(disposition="unresolved", reason="related records must first have durable mappings in the same destination scope")
                else:
                    mappings.append({"source_id": ref, "target_id": related["target_id"]})
            row["related_mappings"] = mappings
        except (ValueError, TypeError, KeyError) as error:
            row.update(disposition="invalid", reason=str(error))
        results.append(row)
    return {"schema": SCHEMA, "batch_id": envelope["batch_id"], "digest": batch_digest,
            "items": results, "executing": False}


def apply(root, envelope, binding):
    from app import fence
    target = {"person_id": PERSON_ID, "entity_id": binding["entity_id"], "thread_id": binding["thread_id"]}
    validate_envelope(envelope)
    store = EventStore(Path(root))
    fence(store, binding)
    directory = Path(root) / "imports"
    prepare_private_dir(directory)
    fd = os.open(directory / ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = preview(root, envelope, target)
        prior, batches = receipt_state(root)
        batch = batches.get(envelope["batch_id"])
        imported_at = batch["imported_at"] if batch else datetime.now(timezone.utc).isoformat()
        append_receipt(root, {"kind": "batch", "batch_id": envelope["batch_id"], "digest": result["digest"],
                              "imported_at": imported_at, "status": "applying"})
        for row in result["items"]:
            if row["disposition"] != "importable":
                continue
            item = envelope["items"][row["index"]]
            intent = {"kind": "intent", "key": row["key"], "digest": item["digest"], "target": target,
                      "target_id": row["target_id"], "source": envelope["source"], "item": item,
                      "imported_at": imported_at}
            append_receipt(root, intent)
            try:
                fence(store, binding)
                event_key = "neutral-import:" + row["key"] + ":" + item["digest"]
                existing = store.existing_event(event_key)
                if existing is None:
                    store.append("continuity.item_opened", entity_id=binding["entity_id"],
                        thread_id=binding["thread_id"], session_id=binding["session_id"],
                        active_context_revision=binding["revision"], source_ref=item["provenance"]["ref"],
                        idempotency_key=event_key, actor_kind="importer", actor_id="neutral-import-v1",
                        payload={"item_id": row["target_id"], "item_type": "open_loop", "title": item["payload"]["title"],
                            "status": "pending", "visibility": item["visibility"],
                            "details": item["payload"]["details"] + "\nImported historical work. Pending reconciliation and a current mandate. Original status: " + item["payload"]["status"] +
                                "\nSource metadata: " + canonical_json({"created_at": item["created_at"], "observed_at": item["observed_at"],
                                    "evidence": item["evidence"], "related": row["related_mappings"], "authority": item["authority"], "confidence": item["confidence"]})})
                elif existing["entity_id"] != binding["entity_id"] or existing["thread_id"] != binding["thread_id"]:
                    raise ValidationError("domain receipt belongs to another scope")
                append_receipt(root, {**intent, "kind": "applied"})
                row["disposition"] = "imported"
            except Exception as error:
                row.update(disposition="failed", reason=str(error))
        result["complete"] = all(row["disposition"] in {"imported", "already_imported"} for row in result["items"])
        append_receipt(root, {"kind": "batch", "batch_id": envelope["batch_id"], "digest": result["digest"],
            "imported_at": imported_at, "status": "complete" if result["complete"] else "partial", "results": result["items"]})
        return result
