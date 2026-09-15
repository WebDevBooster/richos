# Escalation: One CI red cannot be fixed by any commit in this repository: glib GHSA-wrw7-89jp-8q8g needs an alert disposition, which is a risk acceptance

- id: `esc-20260915T115755Z-59863ef7`
- raised: 2026-09-15T11:57:55Z
- from: zach-opus-ciall1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-ciall1` (branch `cc/zach-opus-ciall1`)
- head: `06ddca2471dbd8ef53037b1e7b84ac2f30e02b3b`
- state: **work-complete**
- for: ceo

## The question

Dismiss Dependabot alert #1 (glib, medium, GHSA-wrw7-89jp-8q8g) as not-used, or leave dependabot-updates permanently red until Tauri bumps gtk-rs?

## What was already tried

Read the failing run's log (33901300900): security_update_not_possible, latest-resolvable 0.18.5, lowest-non-vulnerable 0.20.0. Traced glib in app/src-tauri/Cargo.lock to twelve gtk-rs 0.18 crates that are Tauri v2's LINUX backend. Confirmed no Linux packaging job exists in any workflow: packaging-ci runs on macos-latest, windows-companion-ci on Windows. So the vulnerable code is in a lock file and compiled into nothing any user receives, and no commit here can make 0.20 resolve. I have written .github/dependabot.yml so the update surface is declared rather than inherited from GitHub's defaults, and declared the workflow's budget and evidence, but I deliberately did NOT dismiss the alert: dismissing a security alert on a public repository is a risk acceptance, not a build fix, and it stops being true the day someone adds a Linux target.

## Proceeding meanwhile

Everything else in the brief is done and committed. This is the only remaining red that no change in the repository can clear.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T115755Z-59863ef7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T115755Z-59863ef7 --disposition "<what you decided or did>"
