# The garbage mechanism, round 2 — deny-by-default, a garbage alarm, and a pid that is not a liveness test

**Date:** 2026-09-18
**Agent:** zach-opus-garbage2 (Infrastructure Engineer)
**Branch:** `cc/zach-opus-garbage2`
**Base:** richos main `47b79358`
**Closes:** the defeats in `docs/verification/2026-09-18-garbage-mechanism-attacked.md`
(frank-opus-garbage1), escalation `esc-20260918T091550Z-8d175065`
**Ruling:** CEO §54 — *"ROCK-SOLID, UNBREAKABLE, UNDEFEATABLE mechanisms that always guarantees
that garbage like this will be always cleaned up afterwards. Or if the clean-up fails or impossible
for some reason, then Rich must get a MASSIVE ALERT about it and get on with manually deleting the
garbage if it fails to be deleted automatically."*

Every number below is a command's output taken on this machine. Where something could not be
established it says so. Every fixture was built under this session's own scratchpad with a sandbox
`TMPDIR`, a sandbox `CLAUDE_CONFIG_DIR` and a sandbox config file; the real `$TMPDIR`, the real
ledger, the real state files and the two launchd jobs were never written. §10 shows the teardown.

---

## 1. Fix 3(a) — a VERIFICATION, not a change. D5 is already closed on main.

Frank's D5 is the one defeat that runs the wrong way: the allocator arm deleting a tree a live
process is reading. `zach-opus-testinst1` closed it at `00bb72c2` before this pass started, so the
job here was to re-run the reproduction against main and only touch the wall if it failed.

**It did not fail.** Frank's fixture, in shape byte for byte — a directory under the allocator root
named for a dead owner pid (99999998), with a live `tail -f` holding a file open inside it:

```
=== D5 REPRODUCTION, re-run against main 47b79358 ===
fixture:  .../tmp/richos-scratch/99999998-frank-openheld-a   (owner pid 99999998, dead)
holder :  tail -f .../99999998-frank-openheld-a/held.lock  (pid 26689, alive)
lsof sees it: 26689

--- scratch-reaper.sh --dry-run --verbose ---
KEEP              2.0 MB  .../richos-scratch/99999998-frank-openheld-a
                          why: pid 99999998 is ended, but a LIVE process holds a file open
                               inside this tree — the allocation being over does not make a
                               tree something is reading garbage

--- scratch-reaper.sh --apply ---
verdict: decided deletable=0 reclaimable=0 B kept=1 undecidable=0
applied: deleted=0 freed=0 B

RESULT: KEPT — the tree a live process is reading survived --apply
holder pid 26689 still running
```

**The positive control, in the same run** — because every assertion above also passes against an arm
that has simply stopped deleting anything:

```
--- POSITIVE CONTROL: holder killed, same tree, --apply again ---
  why: pid 99999998 is ENDED (owner of 'unrecorded', from the directory name) and nothing
       has touched this for 0 min; its TTL was 360 min
verdict: decided deletable=1 reclaimable=2.0 MB kept=0 undecidable=0
applied: deleted=1 freed=2.0 MB
CONTROL OK: with the holder gone the same allocation IS deleted
```

The wall lives at `scripts/lib/scratch-reaper.py:914-952` and its regression case is S19/S19b/S19c in
`scripts/scratch-reaper.test.sh`. Nothing in this pass changes it. The reproduction script is not
committed: it is thirty lines that build a fixture the suite already builds, and S19 is the durable
form of it.

**Also re-derived from `00bb72c2`, because the D5 fix rested on it:** `holder()` asks `lsof +D` for a
directory rather than `lsof -t -- <path>`. The old form asked who had the directory NODE open and
answered "nobody" about a tree a live process was writing into — the same defect one level down, in
the arm that exists to protect a live agent workspace. Confirmed present at `scratch-reaper.py:1320-1324`.
