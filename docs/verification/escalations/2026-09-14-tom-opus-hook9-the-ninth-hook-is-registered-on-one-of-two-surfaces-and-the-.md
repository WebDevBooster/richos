# Escalation: The ninth hook is registered on ONE of two surfaces, and the engine already had a tool that said so

- id: `esc-20260914T203940Z-12fd3914`
- raised: 2026-09-14T20:39:40Z
- from: tom-opus-hook9
- worktree: `/Users/alex/ab/richos-wt/tom-opus-hook9` (branch `cc/tom-opus-hook9`)
- head: `403772380b9f1507d6077190cbdd82a7d5572ed2`
- state: **proceeding**
- for: lead

## The question

Nothing needed to unblock — but the brief's defect-1 account is wrong in a way that changes the fix: is deriving CANONICAL_AGENT_CHAIN from hooks.json (making Layer C a cross-surface seated-vs-plugin check) the intended scope, given BR_EXPECTED and BR_AGENT_WANT must stay typed to avoid becoming tautological?

## What was already tried

Reproduced everything. (1) engine/.claude/settings.local.json wires 8 Agent hooks; engine/hooks/hooks.json wires 9 — c495a7b9 registered guard-brief-scope.sh on the plugin surface ONLY, so the ninth guard does not fire in this repo's own sessions at all. (2) The quoted CI line is NOT from the probe run against the repo: in run 34887348320, probe step 5 printed a GREEN Layer C over 8; the red '9 entries wired, expected 8' comes from demo.sh beat 7, whose sandbox seats the chain FROM hooks.json. (3) 'run scripts/hooks/install.sh' is confirmed a dead remedy by reading install.sh: it validates two config keys, migrates a stale settings.json and mints .sha256 sidecars; it never writes a hook stanza. (4) engine/scripts/hook-registration-completeness.sh --root .. --baseline c495a7b9^ --explain exits 1 and names 4 owed places across 3 files, including CANONICAL_AGENT_CHAIN by name; the guard that calls it, guard-hook-registration-commits.sh, is registered and did not stop the land. (5) That CI run has 6 red units, not 2: by-reference, unevaluated-payload, engine-status, session-evidence, brief-scope, plus demo.

## Proceeding meanwhile

Deriving CANONICAL_AGENT_CHAIN from hooks.json, replacing the BR_AGENT_WANT full-sequence string with derived membership plus typed order invariants, seating the ninth hook, fixing 4b on its merits, and adding a tenth-hook case.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T203940Z-12fd3914`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T203940Z-12fd3914 --disposition "<what you decided or did>"
