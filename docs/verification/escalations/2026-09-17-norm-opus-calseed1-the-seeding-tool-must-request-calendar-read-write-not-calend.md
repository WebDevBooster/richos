# Escalation: The seeding tool must request calendar (read/write), not calendar.events — the brief's scope cannot create the second calendar

- id: `esc-20260917T100606Z-ab182050`
- raised: 2026-09-17T10:06:06Z
- from: norm-opus-calseed1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-calseed1` (branch `cc/norm-opus-calseed1`)
- head: `0c00cd873f502a65721b50ab772e2c903fc3f4f5`
- state: **work-complete**
- for: lead

## The question

Before the live seed: is it accepted that the consent screen Rich clicks says 'See, edit, share and permanently delete all the calendars you can access' (scope https://www.googleapis.com/auth/calendar), rather than the narrower calendar.events the brief named?

## What was already tried

Checked Google's own method reference against every call the brief requires. calendars.insert (the 'RichOS test' calendar the brief asks for, so multi-calendar sync is exercised) is authorized by calendar, calendar.app.created or calendar.calendars — NOT by calendar.events. calendars.get on primary, which is how connect verifies whose grant arrived (identity.js), is likewise not authorized by calendar.events. Two granular scopes (calendar.events + calendar.calendars) would be narrower but rest on a scope-table claim nobody here has run live, and a wrong guess costs a second consent screen.

## Proceeding meanwhile

Built and shipped with SEED_SCOPE = https://www.googleapis.com/auth/calendar, stated at the top of the command's output and in the README. The grant is held in its own keychain item (com.richos.workspace.google.seed) that no sync-path code reads, GOOGLE_SCOPES is untouched, identity is verified before anything is written, and --teardown revokes it at Google before deleting it locally. Changing the scope is a one-line change to SEED_SCOPE in lib/workspace/calendar-seed.js.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T100606Z-ab182050`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T100606Z-ab182050 --disposition "<what you decided or did>"
