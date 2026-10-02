# Escalation: zach-opus-cores2: the watchdog launchd runs is older than main and stops any owned process above 3 cores at any host load; measuring Android at more than one JVM processor needs the new controller deployed

- id: `esc-20261002T020715Z-c974fa31`
- raised: 2026-10-02T02:07:15Z
- from: zach-opus-cores2
- worktree: `/Users/alex/ab/richos-wt/zach-opus-cores2` (branch `cc/zach-opus-cores2`)
- head: `f4eb61fbd8b5d8c3aa413c92f114362f78302b0d`
- state: **proceeding**
- for: lead

## The question

May I run cpu_guard_live_deploy.py deploy from my branch (cc/zach-opus-cores2) once its watchdog change is committed and its tests pass, so the after-measurement runs under the controller that judges a build by its grant? Or will you deploy it after landing, with me measuring the one-processor-plus-warm-daemon case meanwhile?

## What was already tried

Read the live state. launchd runs /Volumes/E1TB/state/richos/cpu-guard/runtime/cpu_guard.py sha256 5d2bfbbd (cpu_guard_live.py as of 8e9cad40, deployed from zach-opus-buildguard1). It does NOT have P5-22 (7bd2efeb6, 2026-09-30, on main): the live watchdog stops any owned process above 3 cores for 10 s whatever the host load, not only above 80 percent. cpu_guard_live_deploy.py deploy would also refuse today: it accepts only the 9154bf51 legacy controller or the candidate as the running file, and the running file is the earlier candidate. My brief says do not deploy, so I have not touched the live controller.

## Proceeding meanwhile

Building item 1 in BOTH controllers (cpu_guard.py and cpu_guard_live.py, as the live file's own docstring requires), the deploy script accepting the previously recorded deploy, the grant in native-work, and item 2 (released per-workspace Gradle daemon, reaped at land/discard), with tests red on main. Measuring before, and after at whatever grant is safe under the live controller (one JVM processor plus warm daemon), and stating the host load.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T020715Z-c974fa31`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T020715Z-c974fa31 --disposition "<what you decided or did>"
