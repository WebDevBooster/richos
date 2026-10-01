# Escalation: D3 still open: the iPhone reproduction never ran, waiting 90 min for the CEO at the phone (follows esc-20261001T113833Z-c9ac3ed0)

- id: `esc-20261001T130736Z-8a8b192b`
- raised: 2026-10-01T13:07:36Z
- from: isaac-opus-d3c
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-d3c` (branch `cc/isaac-opus-d3c`)
- head: `f0e6d76b6c7b88ec2d84a7b60eb8469c76ee8e34`
- state: **stopped**
- for: lead

## The question

When can the CEO be at the test iPhone for one Touch ID approval? The rest of D3 (the phone's log of the failing try, the cause, the fix and the phone check) depends on running on the phone, and every run is forecast to ask for that approval.

## What was already tried

Raised esc-20261001T113833Z-c9ac3ed0 at 11:38Z (proceeding) and sent the doorbell; no acknowledgement by 13:08Z. Without the phone: (1) the route is not the cause: 12 of 12 requests held across a paused lab through the managed Connect route came back 0.3 s after the lab was continued, including POSTs written onto an idle route connection; (2) the app's own core and URLSession, headless on this Mac (new tool lab-phone), delivered 5 of 5 in-flight fresh-launch tries while hidden, exactly once. So the failing case points at the phone itself (UIKit background time, suspension, the radio) or at phone-only timing, which only the phone's log can show. The lease evidence (try 1's token was spent, not refunded) shows the request was in flight at Home.

## Proceeding meanwhile

Committed on cc/isaac-opus-d3c: 84f1ec3af (the app writes a content-free account of each send around Home to the phone's log, so the next run's syslog says why; its signed build is already published in the physical store, key a5adcc5b644239ece36e596d, so a run starts without a build) and f0e6d76b6 (lab-phone tool and its suite). Stopping and cleaning up; a fresh run needs about 2 minutes of setup (connect lab-enable, lab mac --manual, pairing) plus the CEO at the phone.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261001T130736Z-8a8b192b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261001T130736Z-8a8b192b --disposition "<what you decided or did>"
