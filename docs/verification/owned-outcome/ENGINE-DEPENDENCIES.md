# Engine dependency boundary, revision 3

The revision 2 gate was wrong in both directions. Its phrase matcher held explicit
independence and historical quotations, while ordinary statements of dependence
passed. Its marker was a permanent hold: the pending-record read changed only the
refusal text and could never establish that authority had arrived. The six direct
reproductions and original source hash are preserved in
`engine-dependency-r3-reproduction.json`. Prior R2 results remain historical evidence,
not verification of this replacement.

## What makes the dispatch decision now

Explicit adoption still requires `.claude/owned-work.json` with integer
`version: 1`, boolean `enabled: true`, `decision_policy: "dependency"` and an
available configured runner. Invalid or absent policy values retain the existing
unadopted policy. There is no root-dotfile fallback and no production installation
in this work.

The adopted Agent guard calls `owned-dispatch.py`. It reuses the existing
`ca_resolve`/`ca_items_json` parser for authoritative pending items and `cr_resolve`
for declared standing-ruling paths. No alternative TODO parser or answer ledger
was added. The source conversation comes from the native transcript through
`owned-session.source_messages`, including only observed successful
AskUserQuestion responses as answers. An emitted question or the historical ask
ledger is not an answer.

The helper invokes `richos-run audit-dispatch WORKSPACE SECONDS`. Its new
`dispatch.rs` module uses `NativeCognition::start_registrar`, the existing
registration default model tier and a neutral disposable directory. This is a
private, tool-free interpretation call. It receives only the proposed native
`tool_input`, parsed pending records, source messages and declared ruling text.
It cannot inspect the repository, execute work, answer the CEO or approve tools.

The strict result is one of three dispositions:

- `independent`: no unresolved CEO dependency was found for this dispatch.
- `pending`: affected work requires unresolved CEO authority, or a claimed
  dependency cannot be shown to have cleared.
- `authorized`: an applicable actual CEO instruction or standing ruling clears
  the dependency. This requires at least one exact source citation.

An authorized citation must identify a zero-based CEO message index with role
`user`, or an exact declared standing-ruling path, plus a nonempty verbatim quote
present in that source. The Rust host validates membership and the engine validates
it again at its boundary. Unknown paths, assistant statements, invented quotes,
ambiguous citations and unsupported fields cannot clear work. Quote membership
establishes provenance; the model still has to interpret the quote's meaning,
scope, relevance and possible later revocation correctly.

There is no phrase recognizer and no magic marker that either authorizes work or
holds it forever. A `depends-on-ceo` line can identify the subject for the registrar.
The same dispatch, marker and pending row can be cleared by actual applicable
source authority. Conversely, deleting a marker or pending row is not authority.
A recommendation, question receipt, unrelated answer or deferral cannot replace the
CEO's answer. Existing permission, publication and spending rules still apply.

## Source continuity and freshness

The helper reads the current transcript even when saved scope exists. Saved native
messages may extend the evidence across compaction only when the host's existing
owned state matches workspace, session and canonical `source_transcript`. The
helper merges current rows by native source ID, preserving a repeated answer that
arrives after a revocation. It strips cache-only fields before passing evidence to
the registrar.

A child dispatch must have that verified parent-source binding. The observed native
child event can name the parent transcript, so it can reuse bound CEO scope. An
unknown or mismatched child transcript is unverified; a child task brief must not
become a CEO instruction just because its transcript labels it `user`. Sidechain
rows remain excluded. The helper never captures a child event into leader state.

After review, the helper resolves pending records and standing declarations again,
rereads the transcript and saved scope, then compares the complete input and
configuration. Changed authority, pending state or declared sources invalidate the
review. It does not reread a stale temporary copy and call it a freshness check.
There is still a small interval between this final check and native dispatch; this
is not a transaction locking the CEO conversation and every repository file.

## Refusals, cost and limits

The guard returns host-authored pending or unverified text. Arbitrary registrar
prose never becomes leader policy. Raw result/error diagnostics and the input hash
are appended locally to `.claude/state/owned-dispatch-reviews.jsonl`; that file is
not read as authority. A malformed result, missing source, missing configured
runner or changed source returns unverified. Rich must repair/reconcile the local
condition and retry. An infrastructure error does not itself create a CEO-level
decision. The original owned outcome remains with the leader continuation system;
this dispatch helper has no separate background retry scheduler.

Each proposed Agent dispatch makes one tool-free registrar call. It uses the
existing `RICHOS_REGISTRATION_MODEL` override or registration default (`sonnet`).
These paid calls are separate from the outcome-audit burst policy. There is no
claim that that policy caps all model calls or that this classifier is infallible.
The registrar subprocess is bounded at 150 seconds, with up to four 15-second
source resolver calls across the two collections. The outer Agent gate timeout is
240 seconds, above that 210-second bounded subprocess total. The model's requested
review budget remains 120 seconds. The native trials used the prior 180-second
outer setting; raising it adds timeout margin without another model sample. The
final guard also adds two explanatory comments about its historical unadopted
contract. Neither difference changes its executable dispatch logic.

A source quote is not a semantic proof of permission. Ambiguous natural language,
conflicting standing records and a model's interpretation can still be wrong.
Host checks establish source membership, schema shape and freshness. Controlled
model cases establish measured behavior on those cases, not universal correctness.
No new permissions are emitted and no other tool guard is disabled.

SessionStart and Stop retain their named nonblocking pending-decision reminders.
An asked but unanswered prepared item stays pending in those notices and the status
CLI. Unrelated pending work no longer imposes a per-session dispatch quota. These
existing reminder/status changes are tested alongside the replacement gate.

## Verification and evidence boundaries

Mechanical source tests exercise the shipped engine guard with a controlled
registrar fixture. The fixture is explicitly not a language classifier. The same
marked dispatch holds before an answer, clears when an actual cited CEO answer is
supplied despite the unchanged pending row, then holds when that answer is removed.
Tests separately cover pending-record delivery, declared standing sources, source
changes during review, compaction, bound child sources and renewed answers after
revocation. Rust and Python tests reject invalid source membership and result
shapes. Mutation checks must break these conditions, not match a particular phrase.
The final full process exited **0** after 511.1 seconds: **83/83 engine cases**,
**14/14 Python host tests** and **31/31 mutants killed at the required named
failure**. All watched source hashes remained unchanged. Final aggregate log and
retained mutant sources/outputs are in
`/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-ceo-r3-final-ejgsh7b8/`.
`engine-dependency-r3-results.json` records counts, hashes and evidence paths.
The first full run remains preserved as red evidence: its config cases did not
distinguish two different refusals and its failure-label matcher did not recognize
unittest headers. The strengthened cases instead prove retained legacy deferral
behavior, and the matcher requires the exact failing Python test name.

A fixed real-model corpus ran exactly once against a hashed runner and unchanged
`dispatch.rs`/corpus source. Original evidence is in
`/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-dispatch-r3-sql03a_q/`.
The original run had **14/15 exact-kind assertions and process exit 1**. All three
reviewed independence variants and all four reviewed ordinary/R1 dependency
variants behaved as expected. Actual and revoked answers, ask-only state and
standing-ruling removal were also distinguished.

The remaining exact-kind failure was the unrelated pending-record case: the
registrar returned `authorized` with a valid exact CEO instruction citation where
the corpus expected `independent`. The subtype distinction is imperfect in this
measured case. The paired relevant record returned `pending`; the unrelated record
was allowed. A separate `result.operational-re-evaluation.json` validates every
saved output through the host and records **15/15 correct hold/allow outcomes**.
It does not rerun the model, erase the failed assertion or claim a 15/15 semantic
classification result. Original inputs, stdout, stderr, source hashes and failure
remain preserved.

These are tool-free registrar controls and controlled engine tests. They do not
prove installation, a full native team run or finished work in a live product
session. Those evidence categories are reported separately by the lead.
