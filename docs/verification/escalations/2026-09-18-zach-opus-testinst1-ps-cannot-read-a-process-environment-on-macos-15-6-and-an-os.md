# Escalation: ps cannot read a process environment on macOS 15.6, and an osascript quit by name would quit the CEO's own app

- id: `esc-20260918T085142Z-9986192d`
- raised: 2026-09-18T08:51:42Z
- from: zach-opus-testinst1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-testinst1` (branch `cc/zach-opus-testinst1`)
- head: `e1af0f99ff4883faa39bb9006a8f5bbea12bed12`
- state: **proceeding**
- for: lead

## The question

None blocking — confirm you want the corrected design: identify a test instance by lsof-readable cwd/executable/open-files positively under a reaper-declared scratch root (deny-by-default), and quit it pid-targeted via System Events rather than by app name or bundle id.

## What was already tried

Measured on this Mac: (1) 'ps eww -o command=' and 'ps -E -o command=' return argv ONLY, no environment, for a direct child of the invoking shell owned by the same uid (macOS 15.6 / Darwin 24.6.0) -- so the brief's 'read HOME from the process' is unavailable at any privilege I have; 'lsof -a -p PID -d cwd,txt -Fn' DOES work without root and returns absolute cwd and executable path. (2) The bundled app's binary is ALSO named richos-tauri (RichOS.app/Contents/MacOS/richos-tauri, tauri.conf.json productName=RichOS, identifier com.richos.app), and the .7 walk recorded argv as the RELATIVE './RichOS.app/Contents/MacOS/richos-tauri' -- so neither process name, bundle id, nor argv distinguishes a test instance from the CEO's installed app, and an 'osascript tell application id com.richos.app to quit' could quit HIS app. (3) The brief's never-touch paths do not exist: there is no /Applications/RichOS.app and no ~/myrichos-nightly-*; the installed app is at ~/Applications/RichOS.app and the nightly dir is ~/.richos-nightly. (4) richos-qa-* is in no engine allowlist -- it was a subdirectory of the session scratchpad, already covered by SCRATCH_CLAUDE_ROOTS, not a $TMPDIR pattern.

## Proceeding meanwhile

Building the corrected design: one shared definition module deriving the scratch root set from the reaper's own config keys, deny-by-default identification (quit only what is POSITIVELY shown scratch-rooted, so the installed app is protected by construction rather than by an enumerated list), pid-targeted graceful quit then SIGTERM/SIGKILL with verification, wired into workspaces.py _delete and the reaper's apply() choke point, failures feeding the existing durable-failure/MASSIVE ALERT path.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T085142Z-9986192d`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T085142Z-9986192d --disposition "<what you decided or did>"
