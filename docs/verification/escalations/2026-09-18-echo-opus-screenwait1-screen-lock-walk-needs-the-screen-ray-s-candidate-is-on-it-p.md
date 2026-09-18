# Escalation: Screen-lock walk needs the screen: Ray's candidate is on it (pid 76497), and pmset only locks if the Mac requires a password after sleep

- id: `esc-20260918T103553Z-ab12930a`
- raised: 2026-09-18T10:35:53Z
- from: echo-opus-screenwait1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-screenwait1` (branch `cc/echo-opus-screenwait1`)
- head: `ec620488cfa6251556b6fdb9a851e436054972ae`
- state: **proceeding**
- for: lead

## The question

When is the screen free for roughly 3 minutes so I can lock/unlock it once for the dated record, and is this Mac set to require a password immediately after sleep? If it is not, pmset displaysleepnow will prove CGDisplayIsAsleep but will NOT produce a lock, and the lock half of the walk needs a human at the desk.

## What was already tried

Measured the reader on the UNLOCKED screen already, so the primitive is proven against a real GUI session without touching the screen: CGSessionCopyCurrentDictionary returns an 11-entry dictionary, kCGSSessionOnConsoleKey present, CGSSessionScreenIsLocked ABSENT (absence is the unlocked reading), CGDisplayIsAsleep(main)=false, one full read 298.4us over 2000 reads. What is NOT established without a lock is that the key appears, and as a CFBoolean true, when locked.

## Proceeding meanwhile

Building the whole slice against a fake screen source: the core state machine, the durable waiting-for-the-screen state, the recovery re-arm, the back-end tool and the status read. Unit tests do not need the real screen; only the dated record's live walk does.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260918T103553Z-ab12930a`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260918T103553Z-ab12930a --disposition "<what you decided or did>"
