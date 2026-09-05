# Fifth revision: measured validation

Measured on 2026-09-05 in the isolated `codex/durable-orchestration` worktree.
No production data or main checkout was changed. The review document is
[ORCHESTRATION-REVIEW.md](ORCHESTRATION-REVIEW.md).

| Check | Witnessed result |
| --- | --- |
| Full core suite | 732 direct non-doc tests and five doctests passed, zero failures. Two child-only fixtures are ignored at top level. Source inventory: 734 tests. |
| Focused regressions | 36 controller/Spine tests and four registrar tests passed. |
| Desktop build | Debug build finished successfully with the final Rust changes. |
| Controlled desktop | Nine phases passed: enqueue, resume, recover-notice, correct-live, slow-registration, independent-work, registration-failures, registration-failures-restart and end-live. |
| Registration permissions | Fixture process arguments prove `haiku`, no tools, empty settings sources, strict empty MCP configuration and a neutral working directory. Acting-worker permission tests still pass. |
| Busy registration | An eight-second registrar did not prevent Rich from answering a second message within the three-second assertion. |
| Failed registration | Two bad inputs each made exactly three registrar calls, created no jobs and produced one failure notice each. Restart added no calls or notices. |
| Independent work | A second job completed while an earlier job in the same thread stayed paused. End targeted the selected older job. |
| Active End | A running worker received persisted cancellation directly from End, without a prior Pause click. The final journal state was `canceled`. |
| Resource checkpoint | Tests drive the real controller through the five-cycle delay and ten-cycle decision, including restart and review-only failures. An eleventh call cannot start without a recorded answer; Resume alone cannot authorize it. |
| Mutation harness | 14/14 deliberate behavioral regressions killed at their named assertions. Six additions cover the resource ceiling, checkpoint invocation, review-only behavior, registration consistency, verbatim constraints and redundant priming. Compiler errors do not count as kills. |
| Panel browser checks | 16 passed, including assignment selection, control identity and the selector's computed 16px type size. |
| Affordance checks | Passed with 287/287 states classified. New stale-assignment errors have a Refresh work plans control. No enforcement rule was weakened. |
| Documentation checks | Six passed, including the source-derived 734+5 count. |
| Installed Claude desktop | Passed. One CEO message, one worker attempt and exact ten-byte `Hello Rich` file with no newline. Rich delivered the acknowledgement and verified completion through the ordinary conversation. |
| Conversation lease in that native trial | One initial prime, one answer and one completion report. No registration or extra priming turns on Rich's lease. |
| Conversation compatibility | The unchanged main checkout's reader rendered a controlled new ledger with nine CEO messages exactly once and visible completion. |

The full core run includes the persisted creation timestamp used to select the
newest assignment consistently. The final desktop harness includes the later
request-budget accounting and direct-End changes. The mutation run preceded those
application edits and the creation-timestamp addition; its six new mutants test
core behavior, not the entire reconciler. The native trial preceded the final
metadata, End-control and UI edits; it exercised the detached registrar and the
same native permission and conversation paths.

Initial validation caught a missing snapshot initializer, stale state inventory,
a missing README test-file entry and WebKit forcing a native selector to 13px.
Those failed invocations are not counted as successes. Each relevant check was
rerun after correction. The selector now uses an explicit styled appearance and
its computed font size is asserted in WebKit.

The full UI suite and voice hardware were not rerun. The focused UI checks use
WebKit and the core test asserts speech chunks, not microphone or speaker behavior.
No live-provider correction, production-scale load test or independent P4 design
approval is claimed. The live/reloaded proactive report styling seam remains
listed in the review document. No merge into main or deployment is included.

## Reproduce this revision

```sh
cargo test --manifest-path app/Cargo.toml -p richos-core
cargo build --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-owned-work-desktop.py
python3 app/scripts/test-owned-work-desktop.py --native
python3 app/scripts/test-managed-run-mutations.py /path/to/cargo
python3 app/scripts/check-owned-ledger-compat.py /path/to/older/core /path/to/ledger.jsonl /path/to/cargo
node app/ui/tests/runs.js
node app/ui/tests/affordances.js
node app/ui/tests/docs-claims.js
```

Browser tests need Playwright, optionally supplied by `RICHOS_PLAYWRIGHT`.
The native desktop test needs an installed, signed-in Claude runtime. Each
desktop invocation creates a separate temporary company and app data directory.
Portable results are in `validation/owned-work/results.json`.

---

# Historical fourth-revision evidence

The following is retained as earlier evidence, not the current result inventory.


Measured on 2026-09-05 in the isolated `codex/durable-orchestration` worktree.
Commands run from the repository root. Cargo resolves to the real executable
under the operator's Cargo installation. No main checkout or production app data
was changed. Temporary desktop boots used an explicit isolated data directory.

| Check | Result |
| --- | --- |
| Full `richos-core` suite | 725 non-doc tests passed directly, two child-only fixtures ignored at the top level, five doctests passed. The source inventory is 727 non-doc tests. |
| Managed regression suite | 33 passed, including reviewer-only retry across restart, revision persistence, pre-execution review and Rich's conversation/speech handoff. |
| Desktop debug build | Compiles successfully. |
| Mutation harness | Eight of eight deliberate regressions killed. |
| Work panel browser suite | 14 passed, including an authoritative refresh for a new assignment and rejection of stale updates. |
| Affordance browser suite | Passed after updating the exact state inventory. No rule was weakened. |
| Documentation claims | Six passed with the updated source count and stream documentation. |
| Controlled desktop harness | Acceptance, restart, false completion rejection, notice recovery, conversation responsiveness and live correction are exercised. Final rerun is summarized in `validation/owned-work/results.json`. |
| Installed Claude terminal trial | Completed, exit 0, exact ten bytes `Hello Rich`, no trailing newline. Three native sessions: intake, worker and reviewer. No sibling-field parsing retries. |
| Installed Claude desktop trial | Rich acknowledged ownership in the normal conversation, privately registered the job, completed it in one worker attempt and reported independent verification. Exactly one CEO message was rendered. |
| Older reader | A temporary executable built against the unchanged main checkout's core deserialized and rendered the controlled desktop ledger with four CEO messages exactly once and a visible completion report. |

The final full-core run preceded the small amendment-validator correction that
permits an explicit same-scope revision. The 33-test managed suite was rerun with
that correction, including a close-and-reopen assertion. Desktop build and harness
runs cover the later application integration edits. The final command statuses
are captured in the portable summary; a compilation is not a behavioral proof.

## Reproduce

```sh
cargo test --manifest-path app/Cargo.toml -p richos-core
cargo build --manifest-path app/src-tauri/Cargo.toml
python3 app/scripts/test-owned-work-desktop.py
python3 app/scripts/test-owned-work-desktop.py --native
python3 app/scripts/check-owned-ledger-compat.py /path/to/older/app/crates/richos-core /path/printed/by/harness/data/conversation-ledger.jsonl /path/to/cargo
python3 app/scripts/test-managed-run-mutations.py /path/to/cargo
node app/ui/tests/runs.js
node app/ui/tests/affordances.js
node app/ui/tests/docs-claims.js
```

Browser tests require the existing Playwright installation, optionally selected
through `RICHOS_PLAYWRIGHT`. The native desktop test requires an installed and
signed-in Claude runtime. It runs against a new temporary company and app data.

The controlled desktop harness first sends through the actual `send_message`
command and exits before work registration. On restart the worker falsely says
“All done” without producing the deliverable. Assertions require continuation,
the correct file, exactly one original CEO message and no output in another
company. A third boot tests notice recovery without repeating work. A fourth
holds a worker busy while another conversation answers promptly, then corrects
the original assignment and requires the revised deliverable without manually
ending the job.

The core conversation regression records actual stream events from Spine. It
requires the answer and result report to produce chunks once, preserves the Jam
source and same Rich session and forbids private registration JSON in messages.
This checks the speech input contract. It does not claim microphone or speaker
hardware testing.

## Failures found and corrected

- The first desktop integration used a conversation turn ID where a UUID run ID
  was required. Stable conversion now preserves identity and recovery.
- A correction initially wrote a changed contract that the immutable-journal
  reader rejected on reopening. Explicit numbered amendments now have a validated
  transition shape. Tests reopen the revised journal, including same-scope changes.
- A root union schema failed against the installed provider. Schemas now use a
  required object envelope with the appropriate nested union. The actual native
  run then completed in three sessions.
- The first live desktop trial let Rich perform a small file edit before handing
  it off, followed by a redundant worker. The coordinator instruction now covers
  small actions too. New handoffs independently inspect existing effects before
  executing. A regression proves a satisfied handoff never starts a worker.
- Adding that initial review exposed a controlled-fixture mistake: it checked a
  previous deliverable for the correction scenario. It now checks the file named
  by the actual assignment. That failed run was not counted as a pass.

The third revision's complete 23-suite browser run is historical evidence, not a
claim that all 23 suites were rerun here. This revision reran the affected suites.
The previous audit independently reproduced the controller, permissions and
ledger behavior; this revision adds conversation and correction coverage.

No CI run, release package, deployment, live team migration or independent
product/design sign-off is claimed. Available tools, model judgment, process
crashes during external actions and the requirement that the app be open remain
real limits. See [ORCHESTRATION-REVIEW.md](ORCHESTRATION-REVIEW.md).
