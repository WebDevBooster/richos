# Escalation: Test VM guest: accessibility reads fail with 'TCC grant did not take', so walks cannot open popups or read the screen

- id: `esc-20261006T134433Z-7bddb6e8`
- raised: 2026-10-06T13:44:33Z
- from: echo-opus-fbcopy
- worktree: `/Users/alex/ab/richos-wt/echo-opus-fbcopy` (branch `cc/echo-opus-fbcopy`)
- head: `9cc2121073f1a5be9f91754af489337dc914d12f`
- state: **work-complete**
- for: lead

## The question

Who reprovisions the test VM guest's accessibility grant (testvm/setup.sh --reprovision, as the harness's own message says) so the feedback walk can be re-run once on items 4 to 7?

## What was already tried

One run-walk.py run at 13:38-13:42Z with bundle 1.2.0-dev.bc26e3a45 (cc/echo-opus-fbcopy bc26e3a45) and testvm/fbcopy-walk.sh. Every ax.sh tree read returned {"error": "guest_deadline", ...} with 'TCC grant did not take, re-run testvm/setup.sh --reprovision'. Screenshots (shot.sh) worked: they show on the real app the quick settings menu with no Splash screen row (item 7) and the greeting and onboarding text without dashes (item 3). The clicks into the phone popup and the gear popover did not land, so items 4, 5, 6 and the gear half of 7 were not seen on the real app (all are proven in the WebKit suites). The guest was cleaned up by run-walk.py: app quit, VM stopped, clone deleted. Reprovisioning a shared guest is not mine to do.

## Proceeding meanwhile

Reporting with the partial real-app check stated as partial. The walk now reports UNKNOWN when a read fails (commit on the branch), so a re-run will say plainly whether the guest is fixed.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261006T134433Z-7bddb6e8`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261006T134433Z-7bddb6e8 --disposition "<what you decided or did>"
