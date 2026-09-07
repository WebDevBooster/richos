# Andreas client fixes: verification record

The confirmed onboarding and waiting defects from the [initial audit](../andreas-client-audit-2026-09-07/README.md) are repaired on `codex/andreas-client-audit`. The candidate version is **1.0.3**. Automated macOS checks and an authenticated Claude interview passed. This is evidence for the repaired source and local candidate, not a claim that Andreas has received an update or that model response latency is eliminated.

All product edits and builds were made in `/Users/alex/ab/richos-worktrees/andreas-client-audit` and dedicated subagent worktrees. The main checkout remains clean. Echo reviewed onboarding, Ray reviewed the renderer and Frank challenged lifecycle and cancellation. The lead integrated the changes and ran the final verification. Runtime source is at `fc656e9`; subsequent changes only record verification or maintain test documentation.

## What changes for the CEO

- **The invitation has a working completion path.** Start leads into the interview. Rich can save approved answers through two application-owned tools, with the selected company and destination supplied by the app. The customer does not have to identify a storage folder.
- **Answers survive stopping and reopening.** Partial interviews retain a resume state. Completion is distinct from partial progress. Writes are atomic, read back and checked against the reader's 8,192-byte budget, including the progress header. Rejected writes preserve the previous notes.
- **Not now means Not now for that company.** Both the button and a typed decline are durable. The active model context refreshes after changes. Other companies retain their own invitation. Legacy global decline records migrate once to the restored company. Malformed records and unreadable notes produce explicit errors.
- **Feedback starts promptly.** Sending has immediate local feedback. Once accepted, the request becomes working before connection and context preparation. Slow preparation, output, silence and compaction have visible states. Last activity retains its actual timestamp through unrelated updates and reloads.
- **Stop covers the whole accepted request.** Connection, preparation, visible response and session rotation share the same tracked lifecycle. Failure or child exit ends the durable request rather than leaving it queued forever. A stalled child is retired after the cancellation grace period. Restart reconciles abandoned work.
- **Navigation stays controllable.** Native IPC no longer waits on the model mutex on the macOS main loop. Opening another conversation hides stale messages immediately and preserves the destination draft. Send waits for the actual binding and saved messages. A delayed send, decline or Stop cannot act on a different conversation or newer turn.
- **Fresh setup follows the same path.** Setup refreshes the executable used by the connection factory. It does not start another uncancellable handshake after installation. The next accepted request owns that connection and its feedback.

## Production integration defects found during repair

A live interview uncovered behavior that unit tests alone had missed. Production owned-work rules initially prohibited the direct onboarding save. The exception is now limited to the two exact onboarding tools. The registrar accepts an onboarding-only outcome only when the host observes an actual tool receipt in the current visible turn. An unrelated accepted deliverable still becomes managed work.

The first production probe then exposed an approved save happening inside hidden context preparation. Pending CEO requests are now excluded from hidden priming history. Context-only calls refuse action permissions, and the onboarding server denies writes unless the host grants them for the visible turn. Grants close on completion, failure and Stop. Failed revocation retires the child. Memory retrieval still uses the current question without delivering that question as hidden conversational history.

The final live run requires the exact visible-turn tool receipt and a closed grant after every turn. It passed. Six additional real-child tests exercise grant boundaries through actual process configuration and stdio.

## Verification results

| Check | Final result | Evidence |
| --- | --- | --- |
| Complete core suite | 1,030 ordinary tests and 5 documentation tests passed; 4 top-level ignored entries; exit 0 | [Core log](evidence/core-tests.log) |
| Complete detached Tauri suite | 68 passed; exit 0, repeated after the final setup change | [Shell log](evidence/shell-tests.log) |
| All discovered WebKit suites | 32 ran, none skipped, 596 checks passed; exit 0 | [Full UI log](evidence/ui-tests.log) |
| Final targeted renderer/source checks | Setup, affordances and documentation reconciliation passed after their last changes | [Setup](evidence/setup-tests.log), [affordances](evidence/affordances.log), [documentation](evidence/docs-claims.log) |
| Real macOS Tauri IPC regression | Five scenarios passed using the actual renderer and native bridge with a controlled child process | [Native log](evidence/native-tests.log), [timings](evidence/native-results.json) |
| Finder-like macOS boot environment | All 21 checks passed, including six deliberately broken machine configurations; seven launches left no surviving apps | [Boot log](evidence/gui-boot.log) |
| Actual Claude interview with production rules and registrar | Partial save, restart recall, typed decline, restart, explicit completion, mixed independent work and second-company isolation passed | [Live transcript](evidence/live-interview.log), [fictional saved notes](evidence/fictional-company-notes.md) |
| Live doctrine treatment/control gate | Explicitly ran the normally ignored model check; passed | [Live doctrine log](evidence/live-doctrine.log) |
| Frontend packaging exclusion gate | All 10 passed; test assets are excluded from the shipped frontend | [Payload log](evidence/frontend-payload.log) |
| Release bundle | 1.0.3 built and Developer ID signature verified; hardened runtime, timestamp and required microphone declarations present | [Package log](evidence/package.log) |
| Packaged executable onboarding protocol | Initialization, tool discovery, denied/granted/revoked writes, verified persistence and clean protocol-only exit passed | [Result](evidence/packaged-onboarding.json), [reproduction script](evidence/packaged-onboarding-smoke.py) |

The four ordinary-suite ignored entries are not four untested features: two are child-process fixtures exercised by parent tests. The live doctrine gate was run separately above. The optional real personal Loro corpus check was not run. No personal corpus was used for the fictitious onboarding fixture.

The final full UI run preceded the small setup-handshake removal and the correction of “child-only” to “ignored” in the test-count documentation. The affected shell, setup, affordance and documentation checks were rerun afterward. Product compilation and packaging were repeated after the final runtime edit. Unrelated suites were not relabeled as having run against a later tree.

## Measured responsiveness

The original controlled reproduction measured **7,720 ms of native main-loop delay** and delivered working feedback at 8,105 ms during an eight-second reply. Changing the dispatch alone removed that delay. This isolates a software scheduling defect, not a RAM shortage.

Final native measurements:

| Scenario | Working feedback | Terminal outcome | Measured main-loop delay |
| --- | ---: | --- | ---: |
| Slow reply | 7 ms | Completed at 6,606 ms | 0 ms |
| Stop during context preparation | 25 ms | Stopped at 1,043 ms | 0 ms |
| Stop during initial connection | 13 ms | Stopped at 1,031 ms | 0 ms |
| Preparation failure | 8 ms | Failed at 197 ms | 0 ms |
| Child exits unexpectedly | 10 ms | Failed at 92 ms | 0 ms |

The Stop scenarios issue Stop approximately one second after submission. Their terminal timestamps therefore represent about 31–43 ms after that scheduled action, not a one-second cancellation delay. The preparation scenario also exercises rejection of a stale Stop before submitting the valid one. Reported zero main-loop delay is the probe's millisecond resolution, not a claim of zero execution cost.

This probe uses an instrumented hidden macOS window with the production renderer and IPC. It proves event delivery, main-loop availability and terminal state. It does not measure visible animation frame rate. Separate WebKit screenshots were visually inspected in both themes: [light waiting state](evidence/waiting-light.png), [dark waiting state](evidence/waiting-dark.png), [onboarding invitation](evidence/first-run-offer.png) and [stopped conversation](evidence/stopped-row.png).

## Actual model response times

The authenticated run used the installed Claude Code 2.1.263 and normal existing login with fictitious Northstar/Morgan data. No credentials were copied or changed. The live example starts actual native sessions, uses production doctrine and tools, then reopens the durable RichOS state with a new native session between the specified stages. It is not a Finder-installed upgrade walkthrough.

| Live request | First visible text | Turn completed |
| --- | ---: | ---: |
| Begin interview | 12.912 s | 16.400 s |
| Save partial answers | 11.767 s | 15.761 s |
| Recall after reopening | 5.586 s | 8.785 s |
| Typed Not now | 8.495 s | 9.452 s |
| Resume and complete after reopening | 29.695 s | 34.364 s |
| Save update plus accept separate checklist | 27.376 s | 30.999 s |

These are six observed turns, not a latency distribution or a speed guarantee. Timings include the turn's context preparation but exclude the separately logged initial connection and subsequent registrar call. The checklist was classified as independent work; this probe did not execute it or contact anyone. The deliberately tool-free registrar prints a pre-existing misleading missing-skills warning. Exact primary-chat tool discovery and successful tool receipts are checked independently.

Provider response speed remains variable. The repaired app supplies timely feedback and cancellation during those waits. The [improvement list](IMPROVEMENT-SUGGESTIONS.md) records concrete performance and CEO experience opportunities without claiming them as shipped features.

## Release boundary and remaining verification limits

The candidate bundle is at `app/src-tauri/target/release/bundle/macos/RichOS.app` inside the audit worktree. It is Developer ID signed but **not notarized**. Gatekeeper rejects a downloaded copy until notarization is completed. No release, updater manifest or update signature was published. Andreas is not fixed merely because the source branch is fixed.

Before distributing 1.0.3, complete notarization and signed updater packaging, publish through the normal release process and verify an update from installed v1.0.2. This task did not run that distribution path or touch Andreas's machine. Legacy onboarding-state migration is covered by automated tests, not by a copy of his private profile.

The native host was a different arm64 Mac running macOS 15.6 with 24 GiB RAM. Andreas's reported MacBook Air has 32 GB RAM and Claude Code already installed. His exact hardware, account and network were not benchmarked. Windows, live microphone use and real VoiceOver operation were not tested; DOM live-region, contrast and reduced-motion checks must not be presented as actual VoiceOver validation.

The earlier audit and failed exploratory probes remain historical evidence of what was found. The final logs linked here are the acceptance evidence for these repairs.
