# Escalation: The app-path in-flight sweep already exists and is silent for exactly the land shape

- id: `esc-20260917T190305Z-93ef5a14`
- raised: 2026-09-17T19:03:05Z
- from: norm-opus-landlock1
- worktree: `/Users/alex/ab/richos-wt/norm-opus-landlock1` (branch `cc/norm-opus-landlock1`)
- head: `46c2892dddf0a1f158759f94a0e78a92b687841e`
- state: **work-complete**
- for: lead

## The question

Should the protected-ref check report a fast-forward it can now attribute to a DIFFERENT conversation, given that it deliberately reports no fast-forward at all today and that turning it on unconditionally would notify every running agent on every one of Rich's terminal lands?

## What was already tried

Job item 3 of the land-lock brief, settled by command. (1) The terminal mechanism cannot be wired to the app path: guard-inflight-notify.sh exits unless tool_name is Bash (scripts/hooks/guard-inflight-notify.sh:286) and unless the parsed subcommand is push (:326), and integrate never pushes -- its own tool description says 'No push, rebase or conflict resolution' (mega-lander/app.py:1080). Its second fact, WHO WAS TOLD, is a PostToolUse[SendMessage] witness, and there is no mailbox between the front desk and the back end at all. (2) The app path already HAS a per-repository, non-mailbox equivalent, and it is thread B's own rather than thread A's -- the only shape the partition permits, since thread A cannot write into thread B's RICHOS_WORKSPACES_DIR. _restore_protected_refs (mega-lander/workspaces.py:2649+) compares each agent's own per-call ref snapshot against the SHARED repository, so it sees a move whoever made it; it runs on the app path via scripts/app-engine-hook.py:73 -> workspaces.py hook -> observe_created_refs. (3) THE GAP: it passes a descendant fast-forward over in silence (workspaces.py:2774, 'a descendant carrying none of the agent's work: the lead's land'), and the project's own test asserts that silence -- workspaces.test.py test_point_08, 'And his land is not even reported'. An integrate land IS a fast-forward descendant, so after thread A lands, thread B's agents in that repository are not told.

## Proceeding meanwhile

The land lock itself is built, tested and committed (3 commits on cc/norm-opus-landlock1); the lock file now records who landed what, which is what would make a per-conversation attribution possible. I did NOT change the silence: it is a forensically-litigated function, turning it on unconditionally reproduces the 'piles of noise to agents in flight' the CEO rejected on 2026-09-02, and Sage's finding 4 calls this a rule rather than a new mechanism.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T190305Z-93ef5a14`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T190305Z-93ef5a14 --disposition "<what you decided or did>"
