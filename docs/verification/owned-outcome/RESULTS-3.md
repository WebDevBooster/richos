# Revision 3 results

**The requested no-babysitting outcome is not certified.** Deterministic checks
and bounded semantic controls have results. The native-default trial preserved a
permission prompt but left the assignment unfinished. The preauthorized-equivalent
trial finished with zero measured operational follow-ups. No merge,
deployment, production adoption or full-autonomy claim follows from this report.
The [R3 acceptance contract](REVISION-3.md) and
[external R2 review](/Users/alex/ab/richos-hq/docs/carry-forward/sage-fable-r2-review-of-record.md)
define the correction scope. R2 results and failed samples remain historical evidence.

## Implemented correction and evidence

Native continuation now keeps inspector prose and raw errors out of leader
instructions. It supplies host-authored continuation, actor-stamped execution
receipts and explicitly partial observations of configured permissions. Inspection
failures have a host-authored failure category and private diagnostic locator, so
isolation does not conceal an outage that needs repair. Raw diagnostics remain
available as inspector evidence, not worker permission rules.

Native permission requests pass through by default, preserving the real native
approval flow. Explicit deny-only configuration remains available and survives
reinstallation. Neither mode grants authority or changes existing native rules.
The adapter tests cover child requests, broken configuration, diagnostic retention
and malicious reviewer restrictions that must not enter hook feedback.

| Evidence surface | Verified result | Limit |
| --- | --- | --- |
| Core Cargo suite | 1,041 direct tests passed, 5 documentation tests passed, 4 ignored, 0 failed | Ignored tests were not run; this is not a native acceptance trial |
| Native adapter suite | 40 passed after the failure-category and diagnostic-locator correction | Controlled protocol and state tests, not a real human grant or completed assignment |
| Real tool-free dispatch corpus | Original strict result: **14/15, FAILED**, process exit 1 | One classification subtype mismatch remains |
| Saved dispatch outputs, operational re-evaluation | 15/15 correct allow/hold outcomes with host-validated citations | Re-scoring existing outputs, not a new model run or 15/15 strict classification |
| Engine guard and mutation checks | 83 guard checks and 14 helper tests passed; all 31 mutants failed at their required test | Final process exited 0 with unchanged watched sources; this is controlled engine evidence |
| Native-default trial | 5/5 permission-boundary checks passed; outcome `permission_required`; artifact completion false; measured operational follow-ups 0 | Unfinished work, not unattended completion |
| Equivalent-operation, deny-only trial | Original text recognizer: **19/20, FAILED**. Saved-trace re-evaluation: 20/20 | Required parser actually ran; zero measured follow-ups. A quoted and rejected child suggestion was initially misclassified as an active leader ask |

The core counts were read from the actual Cargo result lines in
[cargo.log](/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-r3-core-_x_mv15t/cargo.log).
The final adapter result is in
[richos-owned-adapter-r3-final-tests.log](/tmp/richos-owned-adapter-r3-final-tests.log).
These logs establish their reported test runs, not deployment of the worktree.

The [final engine run](evidence-r3/engine/process.json) finished in 511.1 seconds
within its 780-second deadline. The first full run exited 1 with seven test-witness
failures: four assertions accepted two different refusal paths and three intended
Python failures were not recognized by the shell reporter. The assertions now
require the correct legacy deferral behaviour and the reporter recognizes the
exact unittest failure header. One full rerun passed. The
[original failed log](evidence-r3/engine-mutations-first-failed.log), final logs,
[mutant patches and their source hashes](evidence-r3/engine/mutants.json) are
retained. No production logic was changed to obtain these mutation results.

## Dispatch interpretation is not work ownership

The dispatch correction reuses the existing private, tool-free registrar machinery
sometimes described as the whisperer. `dispatch.rs` calls
`NativeCognition::start_registrar` with a separate dependency contract and schema.
It interprets the proposed dispatch against supplied CEO messages, pending items
and declared standing rulings. The hosts check source membership and freshness.
This reuse does not make dispatch classification the same operation as registering
an owned outcome. The classifier cannot execute work, answer the CEO or grant a
tool permission. Continued ownership remains with the existing leader/controller.
The mechanism and limits are detailed in [ENGINE-DEPENDENCIES.md](ENGINE-DEPENDENCIES.md).

The strict corpus failure was `pending_record_unrelated`: the model classified an
export task as `authorized` using a valid quoted CEO instruction, while the corpus
expected `independent`. Both dispositions allow that task; the paired relevant
pending record correctly held it. The saved-output re-evaluation checks this
operational boundary without erasing the original failed assertion or rerunning
the model. Valid citations establish provenance, not infallible interpretation.

Original outputs, stderr and exact source hashes remain in
[result.json](/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-dispatch-r3-sql03a_q/result.json).
The separate [operational re-evaluation](/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-dispatch-r3-sql03a_q/result.operational-re-evaluation.json)
records the host validator identity and every saved-output disposition. The corpus
reports unchanged tested sources. Its stderr also reports that the Claude binary
did not load the shipped skills plugin. This is retained as an environment finding;
the corpus tests the explicit tool-free classification contract, not a fully loaded
Rich session.

## Native completion acceptance remains open

The two trial roots retain their separate permission configurations and outcomes:

- [Equivalent-operation, explicit deny-only trial](/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-8ipsk0f2).
- [Native-default permission trial](/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-9bwy4lxz).

The [native-default result](/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-wake-native-9bwy4lxz/result.json)
passes its five permission-boundary checks. The actual native approval UI appeared
and the adapter emitted no grant or denial. The first request was for baseline
hashing, a compound `git status` and `shasum` command, before the required parser
check. It was not a parser refusal. The harness ended without answering the prompt.
Its outcome is `permission_required`, with no saved completion, no native parser
execution and no verified artifact completion. Zero measured operational follow-ups
means no such input was supplied; it does not mean the work finished without help.
This demonstrates corrected permission handling and **unfinished work**, not the
original no-babysitting promise.

The equivalent-operation trial completed the repair and executed both tests and
the required parser validation. It used explicit deny-only policy plus a parser
route preauthorized before launch. One automatic native wake occurred. Four runner
calls returned `independent`, `incomplete`, `complete` and `complete`; these were
not four completion audits. The successful parser receipt is
`toolu_01NZMgUHzNXng5uESEJkNN9g` for `python3 -m json.tool diagnosis.json`.

The original [19/20 result](evidence-r3/native-equivalent/result.json) remains
failed. Its sole text candidate quoted a child's suggestion to grant permission
or run the parser manually, then explicitly said neither was needed because Rich
had already executed an allowed equivalent. All seven leader prose messages were
reviewed. The [saved-trace re-evaluation](evidence-r3/native-equivalent/result.re-evaluated.json)
corrects that recognizer error and passes 20/20 without another model run. Its
regressions still reject the same quotation followed by a fresh request to grant
permission. The child did make an unnecessary suggestion to the leader, visible
in a native task-notification result. It made no `AskUserQuestion` call and Rich
explicitly rejected the suggestion. This is evidence of zero active routine
leader asks in this trial, not zero unnecessary suggestions in every channel.

The execution harness was `65548730bfd69523e0906a0328017ea637548dc46de377a188dfe7d8d8945921`;
the corrected recognizer was `f0eb8cdf5fa3b943a4e2870e50180c902a745f9507128d3899751e19dcf9b5d2`.
Both trials executed an immutable adapter copy with SHA256
`77ab8483e032ef5e2e69b32e884b78385b565999e470213f58436a0c0fa822b9`
and runner `a935fabe95caef1cf79ad7ba7318fefaad9115c6ef2f6ef592758368c0ce3e75`.
The [artifact index](evidence-r3/artifact-index.json) retains source paths and hashes
for the bundled originals, corrected measurements and test logs. Full raw trials
remain at the separate roots linked above. No trial was rerun for a favorable result.

Both trials also retained actual `owned-dispatch-reviews.jsonl` receipts and
adoption configuration. These prove the adopted registrar ran, beyond a guard's
exit status. The final engine hook timeout is 240 seconds, increased from the
180-second setting used in the native trials to cover the helper's maximum
210-second subprocess budget. The guard gained two explanatory comment lines.
Those are the only differences in these runtime files from the frozen native
copy; the adapter and dispatch helper are byte-identical. The final engine tests
cover the final files. The native trials were not repeated for a timeout-margin
and comment change.

The final reports must identify exact source/binary/configuration identities and
separate fixture preauthorization from any real human permission grant. Input-event
counts must come from the captured events. Routine questions in assistant prose
also count: eventual completion without an answer does not establish zero routine
questions. Artifact correctness cannot substitute for evidence that the worker
actually executed required validation. No result is inferred from trial startup.

The RichOS-managed exact tool-grant bridge is still **unimplemented**. Native
passthrough does not repair the managed callback's permission dead end. A typed,
current, exact-operation grant must be bound to its run and consumed once; an
ordinary CEO business answer cannot grant arbitrary tool callbacks. The required
components and validation boundaries remain in [REVISION-3.md](REVISION-3.md).
Until this requirement and the relevant native acceptance evidence are addressed,
the main goal remains incomplete.
