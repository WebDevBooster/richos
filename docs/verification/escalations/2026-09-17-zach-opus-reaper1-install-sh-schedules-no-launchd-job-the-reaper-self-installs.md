# Escalation: install.sh schedules no launchd job — the reaper self-installs, so Rich must run scratch-reaper.sh --install once

- id: `esc-20260917T085505Z-5b37bfe2`
- raised: 2026-09-17T08:55:05Z
- from: zach-opus-reaper1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-reaper1` (branch `cc/zach-opus-reaper1`)
- head: `25c1d795556d96e6ff9861be98590d371f0c1495`
- state: **work-complete**
- for: lead

## The question

After landing, run <main>/richos/engine/scripts/scratch-reaper.sh --install from the MAIN checkout — or decide that install.sh should start scheduling it, which contradicts its current deliberate policy. Which?

## What was already tried

Re-derived the brief's premise: scripts/hooks/install.sh installs NO launchd job. Its only launchd code REMOVES com.richos.worktree-reconciler, with a written rationale that a scheduled deleter the workspace spec does not name is not left running quietly. com.richos.ci-surface-watch is installed by ci-surface-watch.sh --install, not by install.sh (grep for the label: it appears only in ci-surface-watch.sh, the SessionStart notice and two test files). I followed the real precedent: scratch-reaper.sh --install generates the plist with the same worktree/temp-directory refusal.

## Proceeding meanwhile

Everything else in the brief is committed on cc/zach-opus-reaper1. The SessionStart notice reports the job as NOT INSTALLED until somebody runs --install, so the gap is visible rather than silent.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T085505Z-5b37bfe2`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T085505Z-5b37bfe2 --disposition "<what you decided or did>"
