"""Project confirmed desktop Loro writer receipts without invoking another writer.

The app desk remains the proposal/confirmation authority. This adapter reads its
append-only outcome journal from the explicit app data root. Missing or damaged
outcomes never become permission to retry a write.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

from ecs_core import ValidationError, ScopeError, canonical_json


def receipts(path):
    if not path.exists(): return []
    if path.is_symlink() or path.stat().st_size>32*1024*1024:
        raise ValidationError("Loro desk journal is redirected or exceeds the bounded reader")
    proposed,confirmed,written={},set(),{}
    with path.open() as source:
        for line in source:
            if len(line)>2*1024*1024: raise ValidationError("Loro desk record exceeds the bounded reader")
            try: row=json.loads(line)
            except ValueError as error: raise ValidationError("Loro desk has an unreadable outcome; reconcile it before projecting receipts") from error
            tag=row.get("rec")
            identity=row.get("id")
            if tag=="proposed":
                if identity in proposed: raise ValidationError("duplicate Loro proposal identity")
                proposed[identity]=row
            elif tag=="confirmed":
                if identity not in proposed: raise ValidationError("Loro confirmation has no proposal")
                confirmed.add(identity)
            elif tag=="written":
                if identity not in confirmed or identity in written: raise ValidationError("Loro receipt has no unique confirmation")
                outcome=row.get("outcome",{})
                if outcome.get("dryRun") is not False or not str(outcome.get("ref","")).startswith("rec:"):
                    raise ValidationError("Loro receipt does not establish a typed record write")
                written[identity]=(proposed[identity],row)
            elif tag in ("failed","declined"):
                if identity in written: raise ValidationError("Loro outcome changed after a writer receipt")
                confirmed.discard(identity)
            elif tag not in ("suppressed","unsuppressed"):
                raise ValidationError("unsupported Loro desk record; no receipts projected")
    return list(written.values())


def synchronize(store,binding):
    path=store.home.parent/"loro-corrections.jsonl"
    rows=receipts(path)
    applied=[]
    for proposal,written in rows:
        if (proposal.get("entity_id"),proposal.get("thread_id")) != (binding["entity_id"],binding["thread_id"]):continue
        identity=proposal["id"]
        digest=hashlib.sha256(canonical_json([proposal,written]).encode()).hexdigest()
        key="loro-desk:"+hashlib.sha256(canonical_json([binding["entity_id"],binding["thread_id"],identity]).encode()).hexdigest()
        action,receipt=key+":action",key+":receipt"
        reference=written["outcome"]["ref"]
        source=f"loro-desk:{identity}:{digest}"
        observed=datetime.fromtimestamp(written["at"]/1000,timezone.utc).isoformat()
        common=dict(entity_id=binding["entity_id"],thread_id=binding["thread_id"],session_id=binding["session_id"],
            active_context_revision=binding["revision"],source_ref=source)
        def append(stage,event,payload,expected=None,authority=False):
            existing=store.existing_event(key+":"+stage)
            if existing:
                if (existing["entity_id"]!=binding["entity_id"] or existing["thread_id"]!=binding["thread_id"]
                        or existing["source_ref"]!=source or existing["event_type"]!=event
                        or json.loads(existing["payload_json"])!=payload):
                    raise ValidationError("Loro projection retry differs from its durable receipt")
                return
            store.append(event,idempotency_key=key+":"+stage,payload=payload,expected_revision=expected,
                actor_kind="authority" if authority else "system",actor_id="loro-desktop-writer-v1" if authority else "richos-app",**common)
        def transition(stage,state,revision):
            append(stage,"action.transitioned",{"action_id":action,"action_type":"loro_correction","target_ref":reference,
                "state":state,"evidence_ref":source,**({"receipt_id":receipt} if state=="effect_verified" else {})},revision)
        transition("intent","intent",None)
        transition("attempt","attempt_started",1)
        transition("observed","effect_observed",2)
        expected={"receipt_id":receipt,"action_id":action,"receipt_type":"loro-writer-outcome",
            "authority_id":"loro-desktop-writer-v1","authority_ref":reference,
            "observed_at":observed,"verifier_contract":"confirmed-desk-outcome-v1"}
        # The closure attests only this actual confirmed writer result. A model
        # checkpoint cannot call it or substitute a receipt with another ref.
        def verify(claim):
            if dict(claim)!=expected: raise ValidationError("Loro verification claim differs from the writer receipt")
            return observed
        store.authority_verifiers[("loro-desktop-writer-v1","confirmed-desk-outcome-v1")]=verify
        try: append("receipt","action.receipt_recorded",expected,authority=True)
        finally: store.authority_verifiers.pop(("loro-desktop-writer-v1","confirmed-desk-outcome-v1"),None)
        transition("verified","effect_verified",3)
        applied.append({"proposal_id":identity,"record_ref":reference,"receipt_id":receipt})
    visible=[]
    for item in reversed(applied):
        if len(visible)>=10 or len(canonical_json(visible+[item]))>4000: break
        visible.append(item)
    return {"writer":"existing-desktop-loro-desk","receipts":visible,"receipt_count":len(applied),
        "omitted_receipts":len(applied)-len(visible),"inspection":{"section":"actions","include_closed":True},"writes_performed":0}
