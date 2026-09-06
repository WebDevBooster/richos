# Escalation: me/doctrine.source.md was already built and landed; writing it as briefed would have created the duplicate the design forbids

- id: `esc-20260906T162502Z-8dff4764`
- raised: 2026-09-06T16:25:02Z
- from: mark-opus-mrf1
- worktree: `/Users/alex/ab/richos-wt/mark-opus-mrf1` (branch `mark-opus-mrf1`)
- head: `65c0599c012d408980b91a5252a53f7ccc253d2a`
- state: **work-complete**
- for: lead

## The question

Should docs/plans/richos-central-folder-2026-09-06.md §1.2 and §6 be amended to say the person-layer template is DONE and lives at app/crates/richos-core/doctrine/inner-doctrine.md, so the next teammate briefed from that document does not write the second copy I was told to write?

## What was already tried

Verified before writing: the template exists at app/crates/richos-core/doctrine/inner-doctrine.md (3206 bytes, sha256 e7129b9ea0026acb4303...), doctrine.rs renders it to ~/Library/Application Support/com.richos.app/inner-doctrine.md, and that rendered file's first line reads template=sha256:e7129b9ea0026acb - digests match, so it is live today, not a draft. It already carries all six of the inner-doctrine document's §4.2 items plus the dialect clause, under the 4 KB budget. Sage wrote the central-folder design from 9f433ae before that landed, so the document is not wrong, it is overtaken. I wrote me/doctrine.source.md as a CHECKED POINTER instead (canonical + canonical-sha256, verified by check-myrichos.sh), because §1.3 rules that myrichos holds the only copy and §7 concedes staleness is a property of COPIES - a second copy of the product's governing instruction is the exact failure the design is about. doctrine.rs also records why the location was chosen on the merits: a file the app trusts must not be a file a person edits.

## Proceeding meanwhile

Everything else in the brief is complete and committed on mark-opus-mrf1: the folder, the six company.md files, the six guard fragments, the copied guards with drift manifests, and a verification record with three probes proving the pointer check can fail. Nothing in claude-orchestration-kit was read or written.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260906T162502Z-8dff4764`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260906T162502Z-8dff4764 --disposition "<what you decided or did>"
