# Escalation: splitmobile: the 'phone-side PWA' suite tests bytes the Mac app ships, so it stays in the desktop build

- id: `esc-20260926T045111Z-5e08eecc`
- raised: 2026-09-26T04:51:11Z
- from: zach-opus-splitmobile1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-splitmobile1` (branch `cc/zach-opus-splitmobile1`)
- head: `209b99a71baff2bb2dbb4d101d2ff0a03a04e6f7`
- state: **proceeding**
- for: lead

## The question

The brief lists the phone-side PWA among phone-only suites. richos/web/web-app is compiled into the Mac executable (app/src-tauri/build.rs:51 embed_phone; src/phone/assets.rs), and mobile-pwa.test.sh plus mobile-headless.test.sh are the only nightly suites that exercise it (their covers rows name web/web-app/app.js, sw.js, lib/voice.js, lib/connection.js). Keeping both in the desktop build: is that acceptable?

## What was already tried

Read build.rs, phone/assets.rs, mobile/test/proof-driver.mjs pwa branch, mobile/cli/pwa-worker.mjs (serves the unmodified PWA from richos/web/web-app).

## Proceeding meanwhile

Classifying mobile-pwa and mobile-headless as desktop (Mac ships them). The 13 phone-app-only suites leave the desktop build. Both simulator suites that made the gate 1415 s (native-ios-app with A8, native-ios-ui) leave it either way.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260926T045111Z-5e08eecc`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260926T045111Z-5e08eecc --disposition "<what you decided or did>"
