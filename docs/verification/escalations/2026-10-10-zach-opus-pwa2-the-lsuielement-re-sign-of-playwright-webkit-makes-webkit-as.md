# Escalation: The LSUIElement re-sign of Playwright WebKit makes WebKit ask the macOS keychain for its WebCrypto master key, which may have put a keychain prompt on the CEO's screen since the 00:47Z nightly

- id: `esc-20261010T012424Z-81be1f1b`
- raised: 2026-10-10T01:24:24Z
- from: zach-opus-pwa2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-pwa2` (branch `cc/zach-opus-pwa2`)
- head: `b0771c1bff5a67a25305ba1583eed1ded472c8d5`
- state: **proceeding**
- for: lead

## The question

Is a keychain dialog (Playwright wants to use 'Playwright WebCrypto Master Key') on the CEO's screen right now? If so it should be answered Deny (never Always Allow); I will not touch his screen or the system SecurityAgent process.

## What was already tried

Measured: stack sample of the re-signed Playwright UI process is blocked in WebCore::defaultWebCryptoMasterKey -> SecItemCopyMatching -> SecKeychainItemCopyContent (the keychain item 'Playwright WebCrypto Master Key', created 2026-09-18 by the original signature, whose ACL does not trust the new ad-hoc cdhash). The system SecurityAgent process has been alive since about 00:47Z, which is when the nightly's first mobile-pwa run started. That is consistent with a prompt but does not prove one is visible; I cannot look at the screen.

## Proceeding meanwhile

Removing the re-sign patch, restoring the installed WebKit bundles to Playwright's originals, and proving mobile-pwa green.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261010T012424Z-81be1f1b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261010T012424Z-81be1f1b --disposition "<what you decided or did>"
