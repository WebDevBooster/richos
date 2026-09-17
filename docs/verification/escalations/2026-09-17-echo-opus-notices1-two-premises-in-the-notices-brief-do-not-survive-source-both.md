# Escalation: Two premises in the notices brief do not survive source; both fixes landed against the real mechanism

- id: `esc-20260917T225154Z-a11992d7`
- raised: 2026-09-17T22:51:54Z
- from: echo-opus-notices1
- worktree: `/Users/alex/ab/richos-wt/echo-opus-notices1` (branch `cc/echo-opus-notices1`)
- head: `267138cf8e09749ed1c12d3b5d34e929c966d12c`
- state: **proceeding**
- for: lead

## The question

Ray's observation C (zero cards when he genuinely talked over Rich) is an ONSET defect, not a notice-latch defect — his own log says no utterance START was logged at all. Do you want that dispatched as its own task, or folded into the next voice slice?

## What was already tried

Read from source and pinned with tests. (1) The brief asks to suppress HeardNoVoice/DidNotCatchThat 'for audio that was discarded as Rich's own echo'. That path does not exist: CaptureBrain::push_residual DROPS the Utterance on the tainted branch, supervise's Discarded arm never touches utt_tx, and both notices are emitted only inside RecognizerDesk::handle which is reachable only through utt_rx. Implementing the brief literally would have suppressed nothing. Cards 2 and 3 are audit-5's own #8 double card on an ADMITTED non-speech sound, which Ray himself says. Fix landed as one shared authority-ranked budget across both threads: 3 cards -> 1, pinned by rays_first_spoken_answer_produces_exactly_one_notice_card plus a 'before' test and two structural pins. (2) Ray attributes the zero cards in observation C to the latches being spent; his own log line 'NO utterance START logged for it at all' means no notice path was entered and no latch was consulted, so nothing in the notices layer can fix it.

## Proceeding meanwhile

Job 1 and job 3/4 are committed and green (6ae4ef52, 267138cf). Proceeding on job 2, the ledger provenance field. Also noting: the brief names 'richos/docs/verification/' but after the 2026-09-17 relayout that directory is 'docs/verification/' at the repository root; and the brief's footprint rule ('ledger.rs is the one file outside your crate you may touch') cannot be satisfied together with 'end to end' provenance, because the submit callback's one consumer is src-tauri/src/main.rs and the shell would not compile otherwise.

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20260917T225154Z-a11992d7`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20260917T225154Z-a11992d7 --disposition "<what you decided or did>"
