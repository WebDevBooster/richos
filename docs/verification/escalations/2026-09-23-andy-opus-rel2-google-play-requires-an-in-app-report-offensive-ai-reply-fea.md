# Escalation: Google Play requires an in-app 'report offensive AI reply' feature RichConnect does not have

- id: `esc-20260923T221536Z-1212750e`
- raised: 2026-09-23T22:15:36Z
- from: andy-opus-rel2
- worktree: `/Users/alex/ab/richos-wt/andy-opus-rel2` (branch `cc/andy-opus-rel2`)
- head: `52ac3b048e76a3b1cd33b0e89c8ad5ecf38cd30a`
- state: **proceeding**
- for: lead

## The question

Google Play's AI-Generated Content policy (support.google.com/googleplay/android-developer/answer/13985936) puts 'text-to-text conversational generative AI chatbots, in which interacting with the chatbot is a central feature' in scope and requires 'in-app user reporting or flagging features that allow users to report or flag offensive content to developers without needing to exit the app'. RichConnect has none (searched native-android app/ and core/ for report/flag: only unrelated hits). Who builds it, and where do reports go (a report reaches the developer, so it needs an endpoint of ours, e.g. on the existing Connect Worker; that is a privacy and §57 question for the CEO)? Needed before the first Play submission; the same question likely applies to iOS review.

## What was already tried

Read the policy page; grep of the Android app and core; no record in richos-hq docs/ or wiki/ mentions it.

## Proceeding meanwhile

Finishing signing, bundle, icon and listing drafts; the drafts name this as an open blocker.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260923T221536Z-1212750e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260923T221536Z-1212750e --disposition "<what you decided or did>"
