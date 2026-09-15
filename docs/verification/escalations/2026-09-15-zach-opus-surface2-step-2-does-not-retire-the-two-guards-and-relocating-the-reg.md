# Escalation: Step 2 does not retire the two guards, and relocating the registrations is a re-plumb rather than a subtraction

- id: `esc-20260915T073159Z-15f725b7`
- raised: 2026-09-15T07:31:59Z
- from: zach-opus-surface2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-surface2` (branch `cc/zach-opus-surface2`)
- head: `bacae8e69c46c9af4936056c287393a5909f2061`
- state: **proceeding**
- for: lead

## The question

Do you want the registration surface MOVED (a re-plumb: rename the registry out of the plugin's conventional path, generate the adopting repo's settings from it, update ~40 consumers) or do you want the subtraction only (delete surface 2, which I am landing)?

## What was already tried

Measured all three premises live in this session, same OS process (pid 75476, started Sun 13 Sep 23:59:44). (1) HOT-RELOAD IS TRUE: a probe hook appended to /Users/alex/ab/femcboost/.claude/settings.local.json fired on the very next Bash call and on 20 calls after it. (2) THE PLUGIN SURFACE IS FROZEN: the same probe appended to engine/hooks/hooks.json fired zero times across two calls; the file was restored byte-identically (sha 1c53f4c8). (3) NO CROSS-SURFACE DEDUPE: registering the expanded form of a live plugin hook (shell-evidence.sh) on the settings surface produced TWO copies of its additionalContext on one call - so relocating the registrations while the plugin still registers them makes every guard run twice. install.sh's own header records this exact bug from the settings.json era ('every hook fired TWICE per matching tool event'). (4) THE TRANSFORM IS PURE: 74 of 76 entries reproduce exactly including timeouts, 75 of 76 ignoring one timeout - Sage's 75 holds. (5) THE RETIREMENT CLAIM IS FALSE: hook-registration-completeness.sh derives FOUR inventories by unanimity - hooks/hooks.json, .claude/settings.local.json, contract-integrity-probe.sh's BR_EXPECTED, engine-status.test.sh's ACKNOWLEDGED_SCRIPTS. Surface 2 is ONE of them. The other two are typed BY DELIBERATE DESIGN (contract-integrity-probe.sh L393-402 argues why BR_EXPECTED must not be derived), and deriving them is Sage's Step 1, not Step 2. So Step 2 takes the predicate from 4 inventories to 3 and retires NEITHER guard.

## Proceeding meanwhile

Landing the subtraction that is unambiguously right and that Sage's own table sanctions ('generate surface 2, or delete it'): deleting the hooks key from engine/.claude/settings.local.json and every typed reader of it. It governs zero working sessions (its commands are $CLAUDE_PROJECT_DIR-relative, so they resolve to paths that do not exist in any adopting repo), and in the only sessions where it DOES apply - engine-rooted ones - it re-creates the documented double-fire bug. Guard count is unchanged at 71 registered scripts; what falls is the number of files that must agree when one hook changes, 4 to 3.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260915T073159Z-15f725b7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260915T073159Z-15f725b7 --disposition "<what you decided or did>"
