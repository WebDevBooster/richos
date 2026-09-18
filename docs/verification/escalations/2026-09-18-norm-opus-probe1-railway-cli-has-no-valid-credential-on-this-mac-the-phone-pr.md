# Escalation: Railway CLI has no valid credential on this Mac — the phone probe is built but cannot be hosted

- id: `esc-20260918T095409Z-e7d1c0d0`
- raised: 2026-09-18T09:54:09Z
- from: norm-opus-probe1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-probe1` (branch `cc/norm-opus-probe1`)
- head: `47b79358a5b41101cd3438aae5479981d5a2eea5`
- state: **proceeding**
- for: lead

## The question

Which non-interactive Railway credential do you want: (a) the CEO runs 'railway login --browserless' once to restore the shared ~/.railway/config.json OAuth session, or (b) he creates a Railway project token in the dashboard and it is exported as RAILWAY_TOKEN — (b) needs no browser handoff and is scoped to one project?

## What was already tried

'railway whoami' exits 1 with 'Unauthorized. Please run railway login again.' No RAILWAY variable is set in the environment (zero matches). ALSO, a false premise in my brief: it says femcboost/scripts/deploy-lib.sh shows 'how the existing deploys authenticate (token in the environment, not an interactive login)'. That file contains no Railway code at all. scripts/deploy-avelor-staging.sh lines 124-147 state the OPPOSITE: auth is a machine-wide INTERACTIVE OAuth session in ~/.railway/config.json, and its own 2026-07-31 incident note says restoring it requires a HUMAN to complete a fresh interactive login because no script can self-serve past a revoked OAuth session.

## Proceeding meanwhile

Building the entire probe (static page, manifest, service worker, Web Audio 16 kHz recorder, zero-dependency RFC 8291 + RFC 8292 push sender) and doing every desktop verification locally over HTTPS with a self-signed certificate. Everything except the public HTTPS origin will be committed and deployable with one command the moment a credential exists.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T095409Z-e7d1c0d0`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T095409Z-e7d1c0d0 --disposition "<what you decided or did>"
