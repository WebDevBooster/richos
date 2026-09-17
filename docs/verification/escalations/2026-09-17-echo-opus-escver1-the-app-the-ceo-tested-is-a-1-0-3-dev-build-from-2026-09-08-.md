# Escalation: The app the CEO tested is a 1.0.3 dev build from 2026-09-08, not v1.0.2

- id: `esc-20260917T081214Z-b466c998`
- raised: 2026-09-17T08:12:14Z
- from: echo-opus-escver1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-escver1` (branch `cc/echo-opus-escver1`)
- head: `133aea8a9ab930668a67f46517eef550bb0e3056`
- state: **work-complete**
- for: lead

## The question

Should a non-release build carry a pre-release version (nightly.py's pattern, e.g. 1.2.0-dev.<sha>) so a development copy can never be handed over as a release — and does the CEO know the app at ~/Applications/RichOS.app is not the v1.0.2 he was testing?

## What was already tried

Measured the bundle rather than the repository. PlistBuddy on ~/Applications/RichOS.app/Contents/Info.plist reports CFBundleShortVersionString=1.0.3, bundle mtime Sep 8 12:01:46 2026. The 1.0.3 string entered the tree at 7bd1e727 (2026-09-07, prepare version 1.0.3), which set Cargo.toml to the next UNRELEASED stable version as nightly.py requires. Only v1.0.0, v1.0.1 and v1.0.2 tags exist; latest.json says 1.0.2. So updates.rs printed the bundle's own version honestly and the bundle was never a release. Items 1 and 4 are landed and tested; the version display and a build-time identity check are pinned.

## Proceeding meanwhile

Items 1 and 4 are complete and committed on cc/echo-opus-escver1. Not landing the dev-version stamping: it changes the live release path on a day a nightly shipped and a QA walk is running, and it cannot be verified without a full signed build.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T081214Z-b466c998`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T081214Z-b466c998 --disposition "<what you decided or did>"
