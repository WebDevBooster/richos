# Escalation: ENABLE_TOOL_SEARCH=false STILL WORKS on 2.1.277 — the warning that blamed it came from the WORK lease, so the 8-12 s cause is still unknown

- id: `esc-20260918T192742Z-93c267c3`
- raised: 2026-09-18T19:27:43Z
- from: echo-opus-toolsearch1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-toolsearch1` (branch `cc/echo-opus-toolsearch1`)
- head: `d67535a57df393cedd858b77ca233b46e66886b2`
- state: **proceeding**
- for: lead

## The question

The 8-12 s to 'On it!' has no established cause now that the deferral explanation is refuted: do you want me to keep the slice open and hunt the real cause (next suspects: the 4412 ms front-desk prime, the register round trip itself, and the webview render), or hand the timing hunt to someone else and land only the false-alarm fix?

## What was already tried

Re-derived the decision module from the shipped 2.1.277 binary at byte offsets 175107000..175113000: b7e() and Kg() are equivalent to 2.1.275's EYe()/Mg() modulo minifier renames, and the truthy/falsey helpers Oe/Eo are byte-identical to 2.1.275's Oe/To. Then probed /Users/alex/.local/bin/claude 2.1.277 directly -- the same binary Ray's run used (app.log line 23) -- with the app's own arg vector: unset gives 28 tools INCLUDING ToolSearch; ENABLE_TOOL_SEARCH=false gives 35 tools WITHOUT it; so does =0; and so do --permission-mode auto, the inline --settings JSON, and --strict-mcp-config. The knob holds in every shape. The warning in native.rs:1884 has no lease role, and tool_residency_env(LeaseRole::Work) is None by design, so a work lease legitimately offers ToolSearch and the message still asserts the variable 'is set for this lease'. In Ray's app.log the warning appears AFTER the register receipt was already said and immediately BEFORE the work lease's settlement line -- the conversation lease had already called the register on that turn.

## Proceeding meanwhile

Fixing the false alarm (the loudness layer will carry the lease role and say something true for each), updating the native.rs:172-210 derivation to name 2.1.277 with the evidence above, and re-measuring first_reply_timing_e2e on 2.1.277 to get a real number for his first words.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T192742Z-93c267c3`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T192742Z-93c267c3 --disposition "<what you decided or did>"
