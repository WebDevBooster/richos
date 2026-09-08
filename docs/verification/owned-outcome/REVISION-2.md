# Response to Sage's external review

This revision responds to `docs/reviews/sage-fable-r1-owned-outcome-2026-09-08.md`
on main. The reviewed commit was `b80f9978`. Changes remain on
`codex/owned-outcome-completion` in the existing separate worktree. The review was
read by absolute path; main was not merged or modified to obtain it.

## Findings and corrections

The central finding was correct. The adopted engine path exited before examining
dispatch, so it was an off switch rather than a dependency boundary. Removing the
nonblocking Stop notice and changing pending status to success were additional
regressions. The passing unadopted mutation cases did not establish the adopted
policy's behavior.

The adopted guard now reads the authoritative TODO items. An explicit
`depends-on-ceo: <id>` holds that dependent dispatch while the item remains
unresolved. Asking a question does not establish an answer. A deferral does not
grant authority, and an absent or ambiguous item is not evidence of approval.
The review's explicit missing-authority dispatch is also refused. An independent
brief may mention an unanswered unrelated question without being blocked.
Pending decisions remain visible in nonblocking notices and status returns
OPEN/exit 1 while they remain pending.

[ENGINE-DEPENDENCIES.md](ENGINE-DEPENDENCIES.md) defines the boundary and tests.
It deliberately does not claim that a small prose recognizer can classify every
possible English dependency. Explicit declarations are checked mechanically;
undeclared semantic dependencies still depend on the leader and outcome reviewer.
This guard never authorizes spending or substitutes an ask receipt for a ruling.

The new adoption configuration lives at `.claude/owned-work.json`, not at the
repository root. Installation excludes its machine-specific contents and lock
from Git locally. Existing committed local settings can still change because
installing hooks intentionally changes those settings; deployment must account
for that reviewed change. No installation has been performed in production.

## Prompt stalls and ownership

The review correctly identified that a permission dialog does not end a turn.
A Stop-only adapter cannot recover it. The installed adapter now handles
`PermissionRequest` by returning a structured denial with `interrupt: false`.
The model receives the refusal and can select an already permitted method. No
tool is auto-approved, no permission rule is widened and no human answer is
fabricated. An essential authority gap must become a concrete business decision.

Native child agents need this refusal path too: their permission dialogs can park
the leader's interface. They now receive the same refusal without acquiring a
separate obligation store. Their questions return to the leader rather than
interrupting the CEO directly. RichOS-managed leases retain their existing
controller-owned permission handling.

Before the leader invokes `AskUserQuestion`, a separate read-only `audit-question`
inspection checks the complete captured authorization and proposed questions.
Routine questions and premature blocking questions are denied with next work.
Genuine material decisions remain available for the actual human answer. A passed
question review only permits presentation; it grants no business or tool authority.
Malformed or unavailable review cannot silently allow the question. A correction
arriving during review invalidates the earlier disposition.

Notification capture records a permission prompt as an operational observation,
not as a CEO instruction. If transcript saving is unavailable, capture now states
that degraded condition explicitly and supplies it to the auditor. Payload-only
capture is not presented as full transcript provenance.

## Pacing and lifecycle

Honest incomplete verdicts now share persisted pacing, rather than only pacing
inspection errors. Five audits can run in the initial burst. Continued unfinished
work then receives hourly recovery. Attempts and the next deadline are reserved
before inference so a crash cannot reset pacing. A synthetic reminder does not
grant another burst. Ownership is retained and recovery remains automatic.

A bounded native transport probe delivered 12 consecutive asynchronous wake
reminders in one session, then stopped at the probe's explicit safety ceiling.
That establishes at least 12 for Claude Code 2.1.263, not unlimited continuation.
It does not establish a general runtime guarantee. `stop_hook_active` is recorded
for diagnosis, not treated as permission to abandon unfinished work. The
[official hook contract](https://code.claude.com/docs/en/hooks) distinguishes
asynchronous wake from synchronous Stop blocking and defines structured permission
denial separately from an exit code.

This is a rate policy, not a total cost cap. Proposed-question inspections are
separate paid calls and do not consume the five outcome-audit attempts. Closing both hosts still stops
execution. Same-session resume retains native ownership; an unrelated new session
does not automatically inherit another session's authority or work. Automatic
cross-session transfer and migration into RichOS remain separate work, recorded
in the improvements list. This revision does not claim those lifecycle gaps are
fixed.

## Doctrine and evidence interpretation

Rich must now tell the CEO whether a failure is a real defect, an obsolete assertion
or a broken test environment. If the cause is unknown, he states what would settle
it and owns that investigation. Genuine pending decisions must be presented with
options and a recommendation even when unrelated work can continue.

The literal recommendation that every ledger entry proves execution was not
adopted. `Ledger::record_action` writes a claim before execution, and re-prime
includes claims and failed actions. The corrected doctrine distinguishes an
observed historical result from a claim, then separately asks whether it is still
true. The rendered doctrine remains within its 4 KiB budget.

The first revised doctrine-only samples still failed: one filed an authorized
lesson in unread scratch storage, and the other corrected a false record without
naming the individual affected subjects. Those are incomplete deliverables, not
reasons to weaken the gate. The doctrine now requires the documented loaded
destination for an authorized lesson and item-level facts and evidence for a
source correction. This does not authorize unrelated product changes.

The original injected-stop trial is transport evidence. Its prompt explicitly
ordered both the initial stop and continuation, so it cannot establish uncoached
behavior. The new assignment-only variant removes those instructions and runs the
actual adapter, verifier and targeted engine decision hooks. It preserves narrow
permissions and supplies no operational replies. Source identity is checked against
an immutable runner snapshot. Full engine adoption is not claimed by a fixture
that only wires the decision guard and reminder.

That assignment-only trial uncovered another real defect. The leader finished the
repairs but explicitly reported that a required JSON parser check had not run.
Both leader and child attempts had been denied. The auditor nevertheless returned
`complete`. The outer harness initially passed because it parsed the artifact
itself. That proves artifact validity, not the worker's required execution, so
the saved run has been re-evaluated as FAIL. Its original result remains intact.

Capture now retains paired tool calls and results from the leader and only that
session's native child transcripts. Receipts keep the child identity, error flag
and truncation flag through compaction. They are evidence, never new CEO
instructions. Completion review explicitly rejects an omitted required executed
check even when the deliverable looks correct. A real-provider replay of the saved
failure, with the actual leader and child refusals supplied, now returns
`incomplete`. Missing or truncated receipts cannot be treated as successful checks.
This is stronger observed evidence, not a cryptographic guarantee that a model
will always reason correctly about it.

A subsequent assignment-only sample exposed repeated permission misdiagnosis.
The leader bundled the already permitted parser command with an optional `echo`
suffix. The runtime requested authority for that suffix. Generic refusal feedback
hid that distinction, and both leader and reviewer treated the parser itself as
unavailable. The leader eventually asked for a routine allowlist change. Keeping
the state unfinished was correct. After four native wake reminders, the same
leader found an allowed equivalent and actually executed `jq empty diagnosis.json`.
It then completed without any operational reply. The harness initially missed
that valid receipt because it recognized only Python parsers; its original result
and corrected assessment are both retained. That is a harness false negative,
distinct from the earlier auditor false positive with no successful parser receipt.
The question reviewer denied the routine permission question but wrongly advised
that inspection could suffice. The separate completion reviewer rejected that
claimed waiver and kept the work incomplete until actual parser execution. This
sample is evidence for retaining the independent completion check, not evidence
that either model's intermediate advice is always correct.

Refusal feedback now preserves the runtime's actual `permission_suggestions` as
explicitly ungranted diagnostic data for leader and reviewer. A compound call's
refusal does not establish that every component is unavailable. The worker may
remove optional formatting and submit the already authorized required operation
alone for normal permission evaluation. Suggestions are not a complete permission
map, are never applied as rules and never authorize disguising a refused operation.
This uses the documented [PermissionRequest input and denial message](https://code.claude.com/docs/en/hooks#permissionrequest).

The unmanaged-assignment gate remains a separate doctrine-only measurement because
it loads no hooks. Its scenarios use separate output directories to avoid the
review's overwritten-artifact issue. That gate's own implementation is outside
this change and was not modified. Final measurements and failed attempts are
recorded in `evidence-r2.json` beside this document.

On the final doctrine, both single live samples returned GREEN across M1–M6:
10 executed checks for rate-limits and 13 for shipping-units, with all three
coverage mutants caught in each. Each received one assignment and zero nudges.
The earlier RED samples remain in the evidence. The gate voided several judge
quotes that were absent from the artifacts; one rate-limits judgment consequently
had only one valid ballot. These are the gate's reported results, not three
unanimous valid votes for every judgment or a measured production reliability rate.

The final rebuilt runner also passed three single-attempt real-provider question
probes: deny an already authorized start question, permit a material purchase
question after independent work and deny the same question while independent work
remains. The disposable quote files were unchanged. Deterministic checks passed:
1,034 ordinary core tests and five doc tests (four ignored), three separate Tauri
pending-instruction tests, 13 actual-desktop scenarios, 71 engine cases with 24
mutants killed, 30 adapter tests, 11 escalation and five question-protocol cases,
29 assignment-panel checks and six documentation checks. The 20 unchanged controller
mutations are carried forward from R1 and the external reproduction, not counted
as a new R2 invocation.

The final composed native trial passed all 18 declared checks on the final adapter
and immutable runner: four audits, two native wake notifications, one leader and
zero operational follow-ups. Actual `python3 -m json.tool diagnosis.json` execution
completed the required validation. Real child permission refusals returned control,
both regression mutants were rejected and scope was preserved. Full interpretation
is in [the native trial narrative](evidence-r2/native-final-narrative.md).

One requirement is not fully met on the native surface: the leader still emitted
a routine question in ordinary prose before the completion auditor corrected it.
It finished without receiving an answer. `PreToolUse` can intercept a question
tool; it does not own already streamed conversation text. This branch demonstrates
automatic continuation without babysitting, not suppression of every unnecessary
question. That remaining gap is explicit in the follow-up list. It must not be
converted into a passing “zero routine questions” claim from this sample.

## Review and activation

Read the new engine policy helper and guard first, then `owned-session.py`, the
installer and the `audit-question` branch in `richos-run.rs`. Check the negative
cases for asked-but-unanswered decisions, unrelated pending mentions, malformed
question verdicts and child permission refusals. The original
[review package](REVIEW.md) remains the historical record for `b80f9978`.

Sage reviewed the adapter, installer and audit CLI changes independently of their
author and found no blocking authority or completion defect. He also reviewed the
later permission-diagnostic addition. He authored the engine changes, so that part
is not an independent review. His repeated-question cost finding is disclosed above
and retained in [IMPROVEMENTS.md](IMPROVEMENTS.md).

Activation remains separate: land reviewed code, refresh engine integrity
sidecars, build at a stable installation path, install the adapter into the
chosen workspace and start a new native session with those hooks. Rebuild and
launch RichOS for its desktop changes. Preparing this worktree changes none of
the running production sessions.
