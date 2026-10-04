# Escalation: isaac-opus-logo1: the brief's public launch log lines conflict with release-policy rule L1 (no Logger in the iPhone app)

- id: `esc-20261004T114313Z-4f05a346`
- raised: 2026-10-04T11:43:13Z
- from: isaac-opus-logo1
- worktree: `/Users/alex/ab/richos-wt/isaac-opus-logo1` (branch `cc/isaac-opus-logo1`)
- head: `29f47d5e8099d155c6e973a7a8402306dd4f7ee8`
- state: **proceeding**
- for: lead

## The question

May the iPhone app keep ONE logging file, App/Platform/LaunchLog.swift (static step names and integer milliseconds only, nothing else can be passed), as a named exemption to rule L1 of richos/mobile/security/release_policy.py? Yes: land both commits. No: drop the exemption commit and the LaunchLog commit; the quiet-first-screen fix stands alone and stays measurable only through system lines (kernel Sandbox spawn, SwiftUI scene creation).

## What was already tried

The brief (step 3) asks for launch steps in the unified log at public level, readable with rios device syslog. The commit was refused: native-release-policy L1 forbids print/NSLog/os_log/Logger anywhere under native-ios/App (security review 2026-09-23; autocheck.test.py records an earlier Logger refused on 2026-10-01). os_signpost is allowed by L1 but is NOT carried by idevicesyslog: measured on the test iPhone at 11:42Z, a launch of the test copy kept 2505 RichOSNative/dev.richos.connect lines and none of the app's existing signposts (useful-content, input-ready).

## Proceeding meanwhile

Proceeding: LaunchLog moves to its own file; a separate commit exempts exactly that path in release_policy.py (a Logger anywhere else still fails, with a self-test negative control). The quiet-first-screen fix and its test are independent of this and go in their own commit. Rich can drop the two log commits without touching the fix.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261004T114313Z-4f05a346`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261004T114313Z-4f05a346 --disposition "<what you decided or did>"
