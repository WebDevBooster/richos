# Escalation: zach-opus-perfwatch1: no committed admission exists for a PHYSICAL phone, and perf.py's Android seeding (also keepdata3's staged version) uninstalls the app

- id: `esc-20261002T084952Z-58b2be1f`
- raised: 2026-10-02T08:49:53Z
- from: zach-opus-perfwatch1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-perfwatch1` (branch `cc/zach-opus-perfwatch1`)
- head: `0ba39f9c604b459f9a8392178859b3c12acf5d62`
- state: **proceeding**
- for: lead

## The question

Two premises in the brief are false on cc/zach-sonnet-vinputs1 (0ba39f9c6). (1) There is no committed device admission for a wired phone: testdevices.py leases only simulators and emulators, native-work.py admits CPU only, and phone-android.py, phone-ios.py and perf.py take no per-phone lease, so nothing tells my watcher that an agent holds a phone. Should a per-phone lease (one flock file per phone that every phone tool takes for its whole session) be built, and by whom? Until then the watcher treats a phone as busy while any process outside its own tree names that phone (serial, UDID or CoreDevice id) or runs a phone tool, and requires 10 quiet minutes before it starts; an agent idle between two phone commands for longer than that is NOT seen. (2) perf.py android --seed-twin uninstalls the app (android.py seed_release), and andy-sonnet-keepdata3's staged StateKeeper also uninstalls in both seed and restore, which your 2026-10-01 CEO rule forbids. The no-uninstall path needs a debuggable twin signed with the SAME key as the installed release, installed over it with install -r, and the user data saved and restored through the twin's run-as. My watcher hands perf.py a guarded adb that refuses uninstall, pm clear and install without -r, and stops the whole run at the first refusal, so until keepdata3 changes its design every automatic Android run will refuse and escalate instead of measuring. Is keepdata3 being told the same rule? (3) The iPhone's seeded measurement on a phone exists only on cc/isaac-opus-launch1, not on main: until it lands every automatic iPhone run reports could not measure.

## What was already tried

Searched richos (main, every cc/* branch head, engine/scripts/lib, app/scripts/qa, mobile/) for a physical-phone lease or admission; read keepdata3's staged diff in its workspace (read-only) and launch1's README diff.

## Proceeding meanwhile

Building the watcher on autocheck's post-merge and post-commit on main, with the guarded adb, the process-based busy check, the escalation and good-run ledger, and the fake-phone tests; the one real Android run follows when andy-sonnet-seen1 releases the phone.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261002T084952Z-58b2be1f`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261002T084952Z-58b2be1f --disposition "<what you decided or did>"
