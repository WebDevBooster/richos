# Deferred suggestions from the R7 review

These are improvements, not activation conditions. They were not implemented
while landing and activating the accepted correction. Earlier suggestions remain
in [IMPROVEMENTS.md](IMPROVEMENTS.md).

- Reduce the bounded wait for Claude's surviving idle inhibitor after a crash.
  Prove that the survivor is the inert system helper before excluding it from
  ownership blocking. A filename alone is insufficient. Other live survivors
  must still withhold transfer.
- During an inspection, detect that its native owner died and release the
  orphan's audit lock promptly. Preserve the inherited inspection lease and
  avoid overlapping an inspector that can still act. The review's proposal
  was not reproduced live and needs targeted evidence before implementation.
- Measure and reduce process-table polling cost for multiple owned sessions.
  A longer interval changes the recovery latency contract and its tests; it
  must not silently weaken the ownership check.

Source: [Sage's R7 review](../../reviews/sage-fable-r7-owned-outcome-2026-09-09.md).
