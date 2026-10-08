# Escalation: Dictation slice 3 walk: two steps need the tool to outlive the app, which only slice 5 makes true

- id: `esc-20261008T072600Z-d94d767e`
- raised: 2026-10-08T07:26:00Z
- from: echo-opus-dict3
- worktree: `/Users/alex/ab/richos-wt/echo-opus-dict3` (branch `cc/echo-opus-dict3`)
- head: `67cad59ec3e14921fb7090d3c46fdd2dc3c1fd5a`
- state: **proceeding**
- for: lead

## The question

Slice 3's walk (plan section 9) asks that after the app's window closes and the app quits, 'the tool and its item stay, and F1 still writes into TextEdit', and that the app's self-quit 'leaves the tool working' (M1). In slices 1 to 4 the tool is always the app's child and exits within a second of the app ending (plan section 6: 'This is also the only mode in slices 1 to 4'; richos src-tauri/src/dictation/tool.rs:151-157, getppid watch; proved by slice 1's ends-with-app step). So those two steps cannot pass until slice 5's LaunchAgent. I am building slice 3 to prove what is true now: closing the window with dictation on quits the app exactly as with dictation off, and the tool ends with it. The 'tool stays' half moves to slice 5's walk. Confirm, or say if slice 3 should instead make the child outlive its parent.

## What was already tried

Read plan rev 2 section 6 and 9 against tool.rs on richos main 67cad59ec; the child exits on getppid change by design (B2: a folder copy works only while RichOS is open).

## Proceeding meanwhile

Building the bar, the flight, the menu bar item, the window check and the rest of the slice 3 walk; the two steps are walked in their child-mode form and named as such in the handoff.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261008T072600Z-d94d767e`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261008T072600Z-d94d767e --disposition "<what you decided or did>"
