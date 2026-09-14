# Escalation: The ledger leak is open and its only fix site is out of my scope; L21 guards a different file

- id: `esc-20260914T015351Z-7f951af7`
- raised: 2026-09-14T01:53:51Z
- from: zach-opus-n7
- worktree: `/Users/alex/ab/richos-wt/zach-opus-n7` (branch `cc/zach-opus-n7`)
- head: `a620ac1e9ce7066054bfedd49189f5812df0a5c2`
- state: **proceeding**
- for: lead

## The question

Who may add one line (export RICHOS_WORKTREE_LEDGER) to engine/scripts/hooks/contract-integrity.test.sh, which my brief puts out of scope and a teammate is editing tonight?

## What was already tried

Read L21 (land-completeness.test.sh:492-578) and containers.test.py as briefed. BOTH guard RICHOS_WORKSPACES_DIR (the workspaces registry), NOT the ledger: containers.test.py:46 says 'ONLY RICHOS_WORKSPACES_DIR, AND DELIBERATELY NOT HOME'. worktree-ledger.py:184 DEFAULT_PATH = expanduser('~')/.claude/state/..., overridable ONLY by RICHOS_WORKTREE_LEDGER (ledger_path(), line 232-233). So no existing guard covers this class. Leak measured live: 3576 rows whose paths carry the mktemp prefix minted at contract-integrity.test.sh:841, newest 2026-09-13T22:11:02Z. That suite exports CLAUDE_CONFIG_DIR (line 209) but the ledger does not read CLAUDE_CONFIG_DIR -- demo.sh:139-142 records that experiment. demo.sh's own arm of this leak IS closed (631ddbdd, 2026-09-13 18:59Z; its last leaked row 16:58Z).

## Proceeding meanwhile

Census is done and I am building the backup + idempotent backlog cleaner and the docs/verification record. I am NOT touching contract-integrity.test.sh.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T015351Z-7f951af7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T015351Z-7f951af7 --disposition "<what you decided or did>"
