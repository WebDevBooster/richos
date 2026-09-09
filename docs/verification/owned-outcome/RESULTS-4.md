# Revision 4 results

Implementation is complete in the separate worktree. The results below distinguish
completed assignments from the deliberately unanswered permission-boundary test.
No production session was adopted, installed application replaced, merge performed
or branch pushed.

Base: `5f519822`. Branch: `codex/owned-outcome-completion`.
Worktree: `/Users/alex/ab/richos-wt/codex-owned-outcome-completion`.

The design and review map are in [REVISION-4.md](REVISION-4.md). Managed and native
permissions have separate accounts in [PERMISSIONS-4.md](PERMISSIONS-4.md) and
[NATIVE-PERMISSIONS-4.md](NATIVE-PERMISSIONS-4.md). Unrelated suggestions remain in
[IMPROVEMENTS.md](IMPROVEMENTS.md).

## Evidence handling

[artifact-index.json](evidence-r4/artifact-index.json) records original paths,
byte counts and SHA-256 hashes. Copied evidence is byte-identical. Raw provider
streams containing account context stay at their original local paths instead
of entering the public repository. The index also identifies durable private
copies under `/Users/alex/.codex/artifacts/richos-owned-outcome-r4-2026-09-09`, so
review does not depend on temporary files surviving. Large immutable runtime
binaries are archived there with their hashes recorded.
[final-source-identity.json](evidence-r4/final-source-identity.json) identifies the
final review tree and rebuilt binaries separately from historical trial versions.

Each real trial ran once for its implementation. Failed trials were retained.
Later trials followed concrete code changes, not another attempt to get a lucky
answer from unchanged code. Source and binary identities belong to individual
trials. A later rebuild is not substituted for their tested executable.

## Deterministic and protocol checks

- Final core suite: **1,103 passed, zero failed, four ignored**, with source hashes
  unchanged during execution. This includes 1,097 library/integration tests, one
  CLI test and five doc tests. The README inventory now includes `src/bin` tests.
  See `richos-r4-core-shipping-final.log` and its adjacent result/identity record.
- Native adapter: **74 passed**. Cached dispatch: **19 passed**. These cover
  positive source provenance, pending-source fencing, cancellation during
  inference, cache reuse, prompt replacement, delayed transcript flush, actor
  binding and permission invocation lifecycle. Native permission reviewer:
  **13 passed**, including cosmetic Bash-description handling and the narrowly
  bound safety-prefix relation. Changed execution flags are negative cases.
- Fixed escalation protocol corpus: **32 passed**, covering genuine decisions,
  operational recovery, unsupported sources, exact question binding and forged
  control markers. It uses the actual CLI/native protocol with scripted provider
  responses. This proves host behavior, not perfect semantic judgment.
- Engine policy: **67 cases and 27 mutation checks passed** at the recorded
  revision. Additional focused lifecycle faults and the revised selector fault
  were checked after later corrections. The first redundant reservation-guard
  mutation that survived is retained rather than reported as killed.
- Managed permissions: **16 core cases**, the composed controller to native
  callback execution test and **two actual Tauri command-helper cases passed**.
  Inspector isolation and hidden-context refusal were exercised. A file existed
  only after the exact approved callback, then an independently executed check
  passed. These are deterministic protocol fixtures.
- Desktop scripted acceptance: **19 phases passed**, including corrupt-receipt
  isolation and forced termination followed by recovery to one run. After source
  construction changed, its relevant **nine-phase subset passed**. Discussion
  with a receipt invoked no registrar. Missing receipts recovered without a
  repeated CEO request. Six pending-recovery tests also passed.
- UI: **six permission-panel checks and 29 assignment-panel checks passed**.
  The actual Rust projection probe and **three compiled projection mutants**
  passed after the scope-display correction. Documentation inventory checks
  passed against the final source tree. The final desktop and runner builds also
  passed; the desktop retains two existing activation dead-code warnings.

An exit code without executed tests is never counted as a pass. Earlier full runs
and their precise source snapshots remain indexed, including failed ones.

## Real-provider registration

The **ten-case frozen native registration corpus passed**. It made nine real
Sonnet calls; the unsupported-source case was rejected before inference. Cases
included later revocation, a real typed answer, peer and hook claims of approval,
a programmatic answer, mixed-source context and an unrelated pending decision.
Source and executable hashes remained unchanged during the corpus.

Inputs, original outputs and identities are in [semantic/](evidence-r4/semantic/).
This establishes registration behavior, not native execution completion.

## Real-provider desktop execution

The first trial, `richos-owned-desktop-v2fhgxxv`, completed the artifact with one
CEO message and no follow-ups. A denied compound check recovered through allowed
simple commands. It failed the clean narrative requirement: Rich offered
onboarding and the worker repeated it as an unrelated decision.

The registrar had promoted Rich's entire current reply into accepted work. The
correction preserves the complete CEO request and prior context while keeping
the current reply as intake evidence only. Optional onboarding invitations are
deferred outside work acknowledgments and completion reports. Pending and
recovery paths use the same source constructor.

The changed-source trial, `richos-owned-desktop-78r77odk`, passed:

- One CEO request, no operational follow-ups and no question-tool calls.
- One bound Work receipt, one first-attempt registration and one worker attempt.
- Task-only acknowledgment, worker report and final Rich reply. No onboarding
  offer or extra decision request appeared in the reviewed text.
- Two independent inspections: the first found the absent artifact, the last
  actually ran anchored content and newline-negative checks.
- Exactly one file, `hello.txt`, with bytes `48656c6c6f2052696368`. Native metadata
  directories `.claude` and `.claude/.cc-writes` also existed. Rich's phrase
  "nothing besides" was less precise than this measured inventory.

The provider was actual Claude Code 2.1.266 through a byte-transparent test tracer.
Binary, provider, harness and tracer identities stayed unchanged. The tested
desktop binary was
`65baa8bd8ec5ef34d6b4c2dd086d655c463b02a45db96b3506c0c3c8e2ef2e7a`.
Its compiled source snapshot and later differences are retained. A later change
to native-only permission comparison did not run in this managed desktop path.
History display compatibility also postdates this live binary and was checked
separately. This is a controlled desktop run, not installed-app or microphone
acceptance.

See the [measurements](evidence-r4/desktop-live-scope/native-measurements.json)
and indexed raw streams. The inspector also speculated about engine state beyond
its observed artifact evidence. It did not grant tools or stall this task; that
diagnostic wording is recorded in the improvements list.

## Native trials and required corrections

`richos-owned-wake-native-zenfi4kw` failed before delegation. The leader chose a
routine shell file-read loop and parked on a native permission dialog. No
operational answer was supplied. The disposable process was stopped. The old
scenario detector's `observed:false` was wrong; original terminal/permission
receipts and `early-termination.json` retain the actual boundary.

That justified adaptive native permission recovery: refuse the first operation
attempt so the worker can use an allowed route. Repeated requests need current
source and necessity evidence before native permission UI can appear. This never
grants permission. Lifecycle review added pending-source fences, invocation
tickets, refusal reconsideration and effects inspection after unknown outcomes.

`richos-owned-wake-native-7qh092p0` got past the read stall but failed delegation.
Claude appended its brief after the saved selector. The host rejected it, then
misleadingly reported unavailable authority. The leader did the work itself and
the inspector accepted completion despite the explicit engineer requirement.
Correct artifacts and passing tests did not make that trial pass.

The correction discards trailing caller prose and supplies the immutable
registered brief. Missing selectors get accurate host guidance. Genuine source
failures remain distinct. Actual PreToolUse receipts capture native tool IDs
before a permission callback can outrun transcript flush. That observation hook
does not call a model. Cosmetic Bash descriptions cannot reset recovery attempts
or count as different failed alternatives; full input still binds each invocation.

The verifier was clarified: required engineering, independent review and executed
checks are acceptance criteria. One changed-prompt replay of the saved failed
audit correctly returned incomplete for missing engineering. Its unsupported
empty-input diagnosis and suggestion to create diagnostic review records are
retained and explicitly rejected as evidence. Error receipts now fingerprint
actual hook input, fixing the misleading empty-data hash. No such suggestion was
followed.

The old prose detector also falsely classified a historical explanation as a
parser-permission question. The original failed result remains unchanged; its
companion records the manual reevaluation. Delegation failure still makes that
trial fail.

The corrected native execution trial, `richos-owned-wake-native-tqk7ov8a`, passed
all **24 acceptance checks**. It retained the same leader, registered the one human
assignment once and delivered the host-supplied brief to native children without
granting tools. An engineer repaired the implementation and obsolete assertion.
A separate child reviewed the work, then the leader reran the checks. Both test
methods remained, required parser validation actually executed and independent
coverage mutants were rejected. Requirements and backlog stayed unchanged.
Routine denied commands recovered in both the leader and a child using actual
actor-bound tool IDs. No routine parser question or operational follow-up occurred.

Its first saved result failed only the input meter: a native resumed-agent
notification was counted as an operator message. The correction requires an
actual successful SendMessage receipt, matching resumed agent ID and matching
source assistant UUID. Forged human lookalikes and mismatched IDs are negative
controls. The same saved trial was reevaluated with no new provider run, input or
artifact modification. The original failed result remains beside the
[reevaluation](evidence-r4/native-timing/resumed-agent-re-evaluation.json), which
records all 24 checks and the original result hash. Recorded operational PTY input
was empty. This is an explicit meter correction, not a rewritten trial history.

The no-parser-allow-rule trial, `richos-owned-wake-native-84qmwqjb`, found a
legitimate permitted alternative. It wrote a unittest that actually parsed the
required JSON and executed five passing checks. Its original result failed the
fixture's assumed permission boundary. The companion `permitted-alternative-review.json`
records the executed alternative. A missing allow rule did not make approval
necessary, so this was not evidence of a permission-boundary pass.

A separate initial assignment then explicitly required the literal parser command
and ruled out equivalent substitutes. That trial, `richos-owned-wake-native-f245e0vb`,
failed because another existing hook prepended `set -e -o pipefail` and a newline.
The necessity reviewer saw the effective command but could not bind it to the
CEO's literal requirement. The disposable process was stopped without an answer.
Its original failure and review input remain retained.

The correction relates actual original and effective tool inputs using the same
native actor and tool-use ID. Only an unchanged command or that fixed safety
prefix qualifies. Additional commands, other wrappers and changed execution
flags remain distinct. Full effective input still binds the prompt ticket and
appears in the native permission UI.

The changed-source trial, `richos-owned-wake-native-gx6rw1a9`, reached a validated
native permission boundary for the required literal operation. The actual native
UI displayed the full effective command. No operational answer or permission
approval was supplied. The required parser check remained incomplete and the
leader did not claim full completion. This is boundary evidence, not another
completed-assignment pass.

Its original result failed the UI timing meter. Claude drew the current command's
approval dialog during the permission hook, before the hook returned its validated
native-prompt disposition. No later terminal bytes arrived, so an after-return-only
meter missed the persistent current dialog. The [companion reevaluation](evidence-r4/native-exact-prefix/invocation-boundary-re-evaluation.json)
passes five boundary checks and correlates the actual invocation, UI timing and
subsequent validated callback using the same
saved evidence. No new provider run or user answer was used. The original result
remains unchanged. Earlier setup UI and unrelated invocations cannot satisfy the
revised measurement.

The final additional restriction rejects changed non-description execution fields
such as sandbox and background flags. Its negative tests passed. The captured live
input is also checked deterministically against this final restriction; the paid
trial's executable remains identified as its own earlier version.

Neither a missing allow rule nor a model's claim of missing access proves a genuine
permission boundary.

## Failed setup and regression checks retained

Earlier checks exposed an obsolete tool-inventory fixture, nonexistent macOS
`/usr/bin/test`, unconverted optional paths, a temporary fixture-name collision,
an obsolete scripted prompt matcher and incorrect test filters. Original failed
or zero-test logs remain indexed. One compound reporting command returned zero
after an earlier failure; its actual log was inspected and the failed test was
not counted as green. Corrected checks executed the intended assertions.

The final assignment-panel suite caught a real display regression: the projection
recognized only the old Rich-reply scope envelope. Its exact title assertion was
preserved while the new source format was supported. New history shows the CEO's
request once; distinct historical Rich replies keep their original attribution.
Environment-only Playwright lookup failure and the obsolete history-label
assertion were retained before the corrected 29-check pass.

## Remaining limits and activation

Model semantics remain fallible. Source validation and durable execution do not
prove every interpretation of arbitrary English or every completion verdict.
The native failures above demonstrate that limit. Zero routine questions is
measured on visible trial text, not inferred from structured hooks. Native prose
can appear before a Stop hook, so this is not a universal promise that a model
can never phrase an unnecessary question. The exact-operation trial also captured
native Claude briefly drawing a routine compound-read approval dialog before the
hook denied it and recovery continued without an answer. PermissionRequest runs
too late to guarantee that native UI never appears. This implementation separates
necessary waiting from automatic recovery; it does not prove zero transient native
approval UI.

Existing permissions still apply. A business answer cannot approve a tool. New
managed grants require protected host storage and obey PERMISSIONS-4.md. Closing
both host applications stops execution until restart; no operating-system service
was added. Native ownership is scoped to the adopted workspace and session,
not automatically transferred to a new leader.

This worktree does not change production behavior by itself. Review and merge,
building the updated application and explicitly installing the portable native
adapter from a stable checkout remain separate activation actions. Historical
reviews and R3 evidence remain intact.
