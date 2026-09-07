# Andreas's onboarding and waiting complaints: independent audit

**Verdict: neither complaint can be signed off as fully fixed.** The new invitation and feedback surfaces are real improvements. Current code still contains failures that can reproduce the missing-onboarding or apparently frozen-app experience. The most serious native failure was reproduced and isolated with a one-line control change.

Audited on 2026-09-07 at `8c777abce6caee4ba86ca1583061a0b3613e39e4`, compared with v1.0.2 at `704b4596d6bacf1757db99ffec2ba17e7b1530e4`. Echo reviewed onboarding, Ray reviewed waiting states and Frank independently challenged lifecycle behavior. The lead ran the full test suites and native macOS experiment.

Andreas's reported setup is a MacBook Air 2026 with 32 GB RAM and Claude Code already installed. The native experiment ran on a different arm64 Mac, macOS 15.6, with 24 GiB RAM. It isolates a software scheduling defect; it does not benchmark Andreas's machine or establish which defect caused his particular incident.

## Published software versus current code

At audit time, [v1.0.2 was still the latest public release](https://github.com/WebDevBooster/richos/releases/tag/v1.0.2). The downloaded updater manifest also advertises **1.0.2**, dated September 4. Its macOS asset was last updated that day. The onboarding and waiting-band work examined here landed later.

Consequently, a client using the public release and updater has not received these fixes. The current shell manifest still says `version = "1.0.2"`, so publishing corrected source also requires a new version and verified update artifacts. No release was made during this audit.

Evidence: [downloaded updater manifest](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/published-latest.json), [current version](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/src-tauri/Cargo.toml:3).

## What is actually improved

- **The invitation now has a real trigger.** Missing company notes cause an interview instruction to be included in priming. A visible notice offers Start and Not now without requiring the customer to type first. The startup check also runs for existing installations after an upgrade. It is not restricted to a new-install flag.
- **The interview skill is now carried by the app's plugin.** Existing controlled model traces show that the new instruction changes the first reply into an offer. These traces support invitation behavior, not successful completion of the interview.
- **Company notes now have a reader.** A correctly located, usable company file reaches later priming, scoped to the company. Missing, empty and oversized files have tested behavior.
- **Waiting feedback is substantially better when its events arrive.** An anchored band describes activity, elapsed time and silence. Compaction has explanatory copy. Accepted events drive feedback; tested terminal events remove it. Existing WebKit checks cover both themes and contrast requirements.

These changes are useful. Their tests do not cover several connections between the model, native host and renderer.

## Release blockers

### 1. P1: ordinary replies can block the macOS event loop

`send_message` holds the spine mutex for the whole model operation. Each queued or working status emits a thread-summary update. The renderer automatically refreshes navigation, invoking the synchronous `navigation_tree` command. That command waits for the same mutex on the native main thread.

This happens automatically on Send. It does not require another sidebar click. The same wiring exists in v1.0.2.

Source chain: [send holds the mutex](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/src-tauri/src/main.rs:499), [summary listener](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/ui/main.js:2510), [navigation invocation](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/ui/main.js:1022), [synchronous lock acquisition](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/src-tauri/src/main.rs:2522).

**Native reproduction:** an isolated, instrumented copy of the current Tauri app used the real renderer, real IPC and a synthetic native-protocol peer producing an eight-second reply. The driver clicked the production Send control. The app's window remained hidden to avoid taking focus. Both cases used identical instrumentation and synthetic traffic.

| Measurement | Current behavior | Control build |
| --- | ---: | ---: |
| Main-thread callback delay during the reply | 7,720 ms | 0 ms |
| Queued event received | 7 ms | 7 ms |
| Working event received | 8,105 ms | 17 ms |
| Completed event received | 8,109 ms | 8,060 ms |

**The control changes only `navigation_tree` from synchronous to threadpool dispatch.** In the baseline, the band remained “Rich has your message” and “He hasn't started on it yet” during the response. In the control it changed promptly to “Rich is working” and then “Writing the reply”. An earlier native run independently measured a 7,668 ms main-thread delay.

The renderer's JavaScript timers continued in the separate WebKit process. The proven failure is blocking of the native main loop and delayed delivery of native events and commands. Hidden-window rendering is not evidence about animation smoothness or visible frame rate.

**Required correction:** remove synchronous waits on long-held model state from the native main thread. The one-line control establishes this cause, but a complete fix must also cover other commands that acquire the same mutex, such as thread switching, timeline reads and onboarding queries. Prefer short-lived state access or independent snapshots over making every query wait for the whole reply.

Evidence: [baseline timings](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/native-baseline-timing.log), [control timings](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/native-control-timing.log), [baseline renderer readings](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/native-baseline.json), [control readings](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/native-control.json).

### 2. P1: first-turn preparation can fail into a permanent queued state

The app persists the customer's message and emits Queued. It then primes the model before marking the visible turn started. If priming returns an error, only the internal action is marked failed. The customer's durable turn remains `Received`, with no end timestamp and no terminal event. The renderer suppresses the rejected send because it still sees a live queued turn.

An independent real-Spine probe established all of the following: only queued events were emitted, the actual queue was empty, no turn was running and reopening the ledger preserved the unfinished `Received` state. The matching WebKit probe still showed the queued message after five simulated minutes, with no error and an empty composer.

Source: [priming before turn start](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/spine.rs:1716), [error propagation](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/spine.rs:2897), [suppressed renderer error](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/ui/main.js:1535).

**Stop fails during this same preparation period.** `control.begin_turn` has not run, so Stop returns `NothingRunning` and never calls the attached cancellation handler. The renderer returns without explaining that nothing happened. Normal native prompt waiting has no deadline until cancellation starts.

Source: [late control registration](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/spine.rs:1728), [NothingRunning](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/steering.rs:758), [silent Stop result](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/ui/main.js:1644), [native receive loop](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/native.rs:1459).

**Required correction:** treat acceptance through preparation and response as one cancellable lifecycle. Every failure after acceptance must terminalize the durable user turn and emit a matching visible outcome. Provide a retry that preserves the request without duplicating it. Describe slow preparation truthfully instead of leaving it indefinitely in a state that cannot be stopped.

Evidence: [Rust probe](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/probes/prime-failure.rs), [Rust output](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/prime-failure.log), [renderer results](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/waiting-results.json), [five-minute screenshot](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/priming-failed-5m.png).

### 3. P1: the interview is not given its actual durable destination

The reader expects `~/myrichos/companies/<entity-id>/company.md`. Fresh priming returns a constant offer with no destination. The skill names `companies/<company>/company.md` under an unspecified “central folder”, while the model starts in the engine directory. The separate memory setup offers `~/RichOS/corpus`; it does not configure the onboarding root.

The probe captured a complete production Spine priming payload. It contains neither the configured central root nor `company.md`. The complete payload does contain the entity scope, so the claim is a missing file destination, not a missing company identifier.

Source: [reader root](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/company.rs:103), [constant fresh offer](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/onboarding.rs:292), [skill destination](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/skills/bootstrap-interview/SKILL.md:75), [different memory destination](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/provision.rs:101).

**What is proven:** the app fails to supply the required destination. **What is not proven:** every model will write to the wrong location. It might search or ask the customer, but that is not a reliable implementation of the promise that answers will be saved and used later.

The earlier evaluation explicitly denied file tools in its completion attempt. It measured refusal to claim a successful write, not an interview that saved answers and recalled them on a new launch. The record itself leaves that end-to-end check open: [original evidence limitation](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/onboarding-honesty-2026-09-06/README.md:317).

**Required correction:** supply a canonical, entity-scoped persistence destination or tool. Create and validate the destination, verify the written bytes against the reader's limits and prove recall in a fresh process. The customer should not have to identify the app's internal storage folder.

Evidence: [onboarding probe](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/probes/onboarding.rs), [results](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/onboarding-probe.log).

## Further confirmed defects

| Priority | Failure | Proof and required correction |
| --- | --- | --- |
| P2 | Declining company A also suppresses the invitation for newly registered company B. | One install-global timestamp is applied to every company. The probe derives `Declined` for both. Scope the decision to the company, matching the current wording. [Record](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/onboarding.rs:123) |
| P2 | Not now changes the UI and disk but leaves an already-primed Rich with the old offer instruction. | Two messages surrounding the button decline produce only one prime. A typed decline has no persistence caller at all. Connect both user-facing decline paths to durable state and the active conversation. [Writer](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/src/spine.rs:893) |
| P2 | The interview's size instruction disagrees with the reader. | The skill permits fewer than 8,000 characters; the reader rejects above 8,192 UTF-8 bytes. A 3,000-character fixture containing 9,000 bytes becomes Unusable. Use one enforced byte budget and validate before confirming success. [Skill limit](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/crates/richos-core/skills/bootstrap-interview/SKILL.md:97) |
| P2 | A worker update makes an old activity description appear recent. | A 26-second-old completed action is displayed as 3 seconds old after a description-free update resets the shared timestamp. Keep the activity timestamp separate from the latest signal timestamp. [Signal handling](/Users/alex/ab/richos-worktrees/andreas-client-audit/app/ui/main.js:1952) |

Additional observations worth addressing:

- Partial saved notes immediately count as Described and remove the invitation. The skill can resume on request, but the app has no partial-interview/resume state. This is a product gap, not evidence that saved answers are lost.
- Malformed text containing a plausible `declined_at_millis` can be treated as a valid decline. Some filesystem permission errors are also treated as absent notes. These disagree with the claimed corruption/error handling.
- A healthy 60-second compaction produces no new polite live-region announcement beyond “Rich started working”. The visual explanation is not announced. This was measured at the DOM level; VoiceOver itself was not tested. [Accessibility readings](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/waiting-workers-a11y-results.json)
- The app's interview explicitly records desired roles without staffing a company. That limitation is now stated honestly, but interviewing and creating a working team remain different outcomes.

## Response time is still an open acceptance question

The earlier waiting-state review explicitly set latency aside. This audit finds no controlled v1.0.2-versus-current evidence establishing reduced end-to-end model response time. Existing September 6 traces show roughly 1.6 to 2.1 seconds of priming before the separate reply operation, whose first text arrived another 3.0 to 5.8 seconds later in those samples. They are historical examples, not a latency benchmark.

The native experiment proves the UI can withhold feedback that already exists. Fixing that should improve perceived responsiveness. It does not establish faster model inference or a guaranteed reply time on Andreas's Mac. His RAM capacity and existing Claude Code installation do not remove these software defects.

Before signing this off, measure Send to accepted, first meaningful visible feedback, first answer text and completion. Cover cold launch, first conversation, a warm follow-up, a company switch and a resumed conversation. Report distributions and outliers rather than one successful run. Include slow preparation, process exit, lost connectivity, compaction and Stop during each phase.

## Verification performed and its limits

| Check | Result | What it establishes |
| --- | --- | --- |
| Complete richos-core suite | 982 passed including 5 doctests; 4 ignored; exit 0 | Existing Rust checks pass. Ignored checks remain unverified. |
| Detached Tauri suite | 66 passed; exit 0 | Existing shell logic checks pass. |
| Native shell check/build | Passed on macOS; production source build restored afterward | Current code compiles with the actual native dependencies. |
| All 30 WebKit suites | 578 distinct checks verified after one harness correction; no suite skipped | Existing browser acceptance checks pass in aggregate. |
| Adversarial onboarding probes | Reproduced destination, decline and size-limit defects | Uses actual Rust state and priming implementations. |
| Priming failure/cancel probe | Reproduced both failures | Uses real Spine, durable ledger and TurnControl with a synthetic cognition adapter. |
| Additional WebKit probes | Reproduced queued failure, ineffective Stop and stale activity age | Uses shipping renderer with controlled bridge events and clock. |
| Native baseline/control | Main-loop delay 7,720 ms versus 0 ms | Causally isolates the automatic navigation dispatch failure. |

**Harness correction:** the first full browser run returned exit 1 because the audit's scratch copy omitted `app/Cargo.toml`, which one `runs.js` check uses to execute a Rust example. The unchanged manifest and lockfile were supplied, then all 29 checks in that suite passed with exit 0. This was an audit setup failure, not a product regression. The original full-run failure is preserved rather than relabeled as green.

Evidence: [machine-readable summary](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/summary.json), [browser summary](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/ui-summary.txt), [corrected suite output](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/ui-runs-rerun.log), [core log](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/core-tests.log), [Tauri log](/Users/alex/ab/richos-worktrees/andreas-client-audit/docs/verification/andreas-client-audit-2026-09-07/evidence/tauri-tests.log).

The native runs used a debug build with audit instrumentation, not a new signed release installed through Finder. No authenticated live interview was completed in this audit. An isolated Claude configuration reported no login; credentials were not copied. No claim is made about live audio, VoiceOver, Andreas's exact network conditions or an updated artifact installed on his Mac.

## What must happen before telling Andreas it is fixed

1. Repair native dispatch and the accepted-turn lifecycle, including preparation failure and cancellation. Add regression coverage at the real IPC boundary.
2. Make onboarding persistence deterministic and company-scoped. Reconcile decline behavior, active model state and the size budget.
3. Run a complete interview with a scratch customer profile. Verify exact saved answers in a fresh process, partial resume and a second company. Repeat from an existing v1.0.2 profile.
4. Validate the waiting states on a visible packaged macOS app, including error and cancellation paths. Measure end-to-end latency and check the key feedback with VoiceOver.
5. Publish a new version with verified signed artifacts. Install it through the v1.0.2 updater and repeat the client path.

This audit leaves production source unchanged. The one-line native control exists only in the scratch experiment and the archived patch. Work initially used read-only checks against main plus isolated /tmp copies for browser tests and native instrumentation. After the user asked about Git worktree isolation, the report and evidence were moved into the dedicated `codex/andreas-client-audit` worktree at `/Users/alex/ab/richos-worktrees/andreas-client-audit`. The main checkout is clean. The only changes on the audit branch are this report and its evidence. Historical logs and archived reproduction sources retain the original paths used during measurement. These findings are not a claim that corrective product changes have landed.
