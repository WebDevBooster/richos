# Escalation: Android's + menu pickers are not wired on richos main either (brief premise: 'exactly as Android does')

- id: `esc-20260924T004516Z-7cf93e52`
- raised: 2026-09-24T00:45:16Z
- from: isaac-opus-store1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-store1` (branch `cc/isaac-opus-store1`)
- head: `976a9adde6f912ad1961d9ca11d9819c0140f4fd`
- state: **proceeding**
- for: lead

## The question

Should Andy also route UiEvent.AttachPick to AttachmentPicker (and add a camera path) for the Play review, the same blocker as iPhone item 2?

## What was already tried

Read native-android on main d17008c9: AttachPick only closes the menu (RichApp.kt:122); toAction() maps it to null (UiEvent.kt else -> null); AttachmentPicker.pickPhotos/pickFiles (platform/Attachments.kt:191-209) have no caller; there is no camera capture path. The Android CORE has the model (Action.Attach, RemoveAttachment, send with pendingAttachments -> one attachments message, RichCore.kt:94-102, 235-241, 331-349).

## Proceeding meanwhile

Porting Android's core model (pending attachments, attach/remove, send with the draft as caption, the Mac's limits) to the iOS core and wiring the three iPhone pickers to it.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260924T004516Z-7cf93e52`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260924T004516Z-7cf93e52 --disposition "<what you decided or did>"
