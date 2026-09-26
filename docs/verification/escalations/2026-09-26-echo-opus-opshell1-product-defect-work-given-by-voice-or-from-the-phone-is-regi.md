# Escalation: Product defect: work given by voice or from the phone is registered but not started until he next types in that thread

- id: `esc-20260926T083231Z-23865924`
- raised: 2026-09-26T08:32:31Z
- from: echo-opus-opshell1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-opshell1` (branch `cc/echo-opus-opshell1`)
- head: `22dd86a4e1d10e10413b08ec090fb925d52241bc`
- state: **proceeding**
- for: lead

## The question

Who fixes this in the product, and may the voice and phone turn boundaries adopt registered work on every install (today only the typed send does)?

## What was already tried

Confirmed by reading every adoption site: WorkHost::adopt_registered is called only from send_message (richos/app/src-tauri/src/main.rs, the typed path's turn boundary). The voice submit closure and the phone drain (phone/bridge.rs) never call it, and nothing else enqueues Registered work (no timer, no boot sweep: remember_binding enqueues nothing). So on a product install a register call made in a spoken or phone turn sits Registered until a typed message on that thread adopts it. Not changed: the brief says nothing may change his current app.

## Proceeding meanwhile

On an OPERATOR install only, the voice boundary and the phone drain now adopt (commit 0038d011), because desk-voice is a listed mouth and a phone assignment must get its refusal. The product paths are byte-for-byte unchanged.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T083231Z-23865924`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T083231Z-23865924 --disposition "<what you decided or did>"
