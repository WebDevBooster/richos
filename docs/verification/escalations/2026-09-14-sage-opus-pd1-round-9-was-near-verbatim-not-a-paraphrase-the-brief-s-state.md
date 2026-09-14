# Escalation: Round 9 was near-verbatim, not a paraphrase — the brief's stated blocker for non-collusive assignment is false

- id: `esc-20260914T202758Z-061a21ed`
- raised: 2026-09-14T20:27:58Z
- from: sage-opus-pd1
- worktree: `/Users/alex/ab/richos-wt/sage-opus-pd1` (branch `cc/sage-opus-pd1`)
- head: `4c202fa3664effe0d91d0e40847ea88810f4096e`
- state: **work-complete**
- for: lead

## The question

Should the record's own account of round 9 be corrected where it implies the lead paraphrased, given quote-detection would in fact have fired on it?

## What was already tried

Measured both passages with difflib.SequenceMatcher, punctuation-normalized: 59 of 90 distinct words shared, longest exact shared span 196 characters, 351 of 778 characters in spans of 40+ chars. The lifecycle failure record agrees (section 10o: 'Near-verbatim'). The brief's candidate-2 rationale says 'whether the brief's quoting can be detected at all when the lead paraphrases, which is what happened in round 9' — that is false.

## Proceeding meanwhile

Did not stop: the false premise sat inside a candidate the brief explicitly declared was not the design, and correcting it STRENGTHENED the refutation rather than blocking it. Non-collusive assignment is still refuted, on the better ground that any mechanism penalizing quotation rewards paraphrase, and paraphrase is recorded failure type W. Work complete and committed on cc/sage-opus-pd1.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260914T202758Z-061a21ed`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260914T202758Z-061a21ed --disposition "<what you decided or did>"
