# Owned outcome completion: implementation and review handoff

Historical report for `b80f9978`. The external review found deficiencies in the
adopted guard and trial interpretation. Current corrections and evidence are in
[REVISION-2.md](REVISION-2.md); its behavior supersedes this report where stated.

Date: 2026-09-08. Branch: `codex/owned-outcome-completion`.
Base: `28f07ab5`. Worktree: `/Users/alex/ab/richos-wt/codex-owned-outcome-completion`.
The implementation and acceptance work are isolated here. No production session
was adopted, no installed app replaced and no merge or push performed.

## Problem

The CEO had already authorized work. The orchestrator nevertheless replaced
execution with reports, treated historical assertions as current requirements,
asked whether to dispatch repairs and stopped while work remained. The observed
Claude session was `5584bf8d-6ff7-4db2-86a3-745f2e130c42` in femcboost. The earlier
desktop controller could not continue that standalone Claude team. More guard
prose on an unconnected surface could not fix that execution gap.

Two policies also conflicted: own authorized work through completion, but ask a
prepared CEO question before dispatch even if it has no bearing on that work.
RichOS intake had a related defect: Rich's noncommittal reply could veto the CEO's
action request, and three registration failures abandoned automatic recovery.

The required outcome is bounded by [SCOPE.md](SCOPE.md). Optional suggestions are
recorded in [IMPROVEMENTS.md](IMPROVEMENTS.md), not silently implemented.

## Changes and their execution surfaces

| Surface | Change | What owns continuation |
| --- | --- | --- |
| RichOS conversation | Preserve the entire request, source context and amendment chain. An unnecessary permission question or empty interrupted reply does not revoke authorization. | Existing durable inbox and run scheduler |
| RichOS recovery | Retry registration after early failures, then hourly. Persist attempts and deadlines before inference/application. Recover old halted entries without resubmission. | Existing app scheduler while the app is open |
| Pending work | Allow cancellation and correction before a run exists. Fence stale creation while a later instruction is unresolved. Save cancellation before acknowledging it. | Inbox plus cancellation receipt |
| Live or paused work | Persist amendment, receipt and explicit pause atomically. Temporary interruption for correction can resume; a user pause remains paused. | Existing exclusive run controller |
| Workers and review | Share one authorized-outcome policy. Check current requirements against actual failures, separate obsolete assertions from implementation defects and keep improvements outside scope. | Existing worker plus independent outcome inspector |
| CEO decisions | Independently challenge proposed escalations against original authority. Return the validated final question, not a rejected earlier proposal. Malformed review is retryable failure. | Shared outcome verifier |
| Interactive Claude Code | Capture source conversation durably and inspect it at native stop/resume/error boundaries. An incomplete audit produces native `asyncRewake` feedback to the same leader. | Existing Claude session, not a competing leader |
| Adopted engine workspace | Replace the unrelated prepared-question dispatch quota with dependency-based decision policy. Preserve real pending questions and all tool permissions. | Explicit workspace adoption flag |

The CLI `handle` path saves the complete request as one assignment. It no longer
asks a model to manufacture a task list that can expand the scope. Workers still
discover the required implementation steps and relevant repository records.

## Native continuation contract

`engine/scripts/install-owned-work.py` adds only owned-work hook entries to the
workspace's local settings and writes `.richos-owned-work.json`. The installer is
idempotent and preserves unrelated hook and permission settings. Adoption is
explicit and does not require femcboost-specific paths.

`engine/scripts/lib/owned-session.py` uses synchronous source capture and native
asynchronous wake auditing. Source state is private, atomically persisted outside
worktrees under `~/.claude/state/richos-owned-work`. Separate locks allow new
instructions to arrive while one auditor runs. A newer source revision invalidates
the old verdict. Full source messages survive shorter compacted transcripts.
Native task notifications and synthetic wake text do not become CEO authority.
Observed successful question results preserve presentation and the actual answer;
failed question calls do not fabricate either.

The adapter calls `richos-run audit-session`, which uses the same outcome verifier
as managed work. It never dispatches another leader. The original leader remains
responsible for its teammates, integration and deliverables. Managed RichOS
workers carry a host marker to prevent recursive ownership by this adapter.

Inspector failures retain unfinished ownership and use persisted backoff. Genuine
questions are presented once and wait for an answer; explicit pause and cancellation
are respected. A native audit's `complete` verdict can also mean no runnable
obligation after cancellation, pause or discussion. It is not a claim that a
canceled or paused deliverable was produced.

The [Claude hooks reference](https://code.claude.com/docs/en/hooks) describes
`asyncRewake`: exit 2 wakes an idle interactive session. Ordinary asynchronous hooks
do not provide that guarantee. Current documentation also gives synchronous Stop
blocking an eight-continuation limit. The first proposal's one-refusal limit was
our engine's own policy, not a Claude contract. Native interactive transport was
measured here using Claude Code 2.1.263; a `claude -p` process tearing down its hooks
is not an equivalent test. Claude's [team documentation](https://code.claude.com/docs/en/agent-teams)
also says in-process teammates are not restored on resume. The leader must inspect
current effects and reconstruct needed work, rather than assume its old team lives.

## Evidence and what it establishes

The adjacent `evidence.json` contains measured results, exact local evidence paths
and source hashes. Raw model transcripts remain local because they can contain
account or private workspace context. Small result files and deterministic test
logs accompany this review where suitable for sharing.

- Core: 1,034 ordinary tests passed, four ignored checks and five doc tests passed.
  Process exit was checked separately. The four ignored checks are not counted as
  passes. Twenty controller/registration mutations failed their intended tests;
  compilation errors do not count as killed mutations.
- Adapter: 17 tests cover source preservation, stale audit fencing, transport
  failure, pause/cancel, decision presentation, nested host exclusion and installer
  preservation. Engine policy: 51 cases and 13 mutation properties passed.
- Escalation: 11 scripted cases traverse the actual native protocol and production
  audit command. They check routine-question rejection, corrected authority and
  malformed outcomes. These prove host handling, not model judgment reliability.
- Desktop: the actual debug app runs a scripted provider through 13 phases,
  including in-flight cancellation, correction, independent work, restart and
  registration recovery without resubmission. Three additional Rust tests cover
  pending instruction durability. The fixture advances saved retry deadlines for
  the recovery phase; it does not pretend to wait an hour.
- WebKit: the existing assignment-panel suite passed. Documentation claims were
  checked against source inventory, including the updated test count.
- Real provider: two unattended `handle` trials repaired a real implementation
  defect and replaced an obsolete assertion with current-contract coverage. Both
  kept the original constraints and avoided routine offers or follow-up questions.
- Native transport: one interactive deterministic-auditor trial passed ten checks.
  Separately, the composed real-auditor trial passed all 15 checks: one initial
  request, injected premature `Recorded` stop, real incomplete verdict, native wake
  of the same leader, repair and complete verdict. No operational replies were
  supplied. Independent execution passed both tests and rejected two coverage
  mutants. Source and immutable auditor identities remained stable.

These small controlled incidents establish the exercised paths. They do not
establish universal semantic correctness on arbitrary projects or installed
performance in the user's existing femcboost session.

To reproduce from this branch, with Cargo on PATH and the existing UI test
dependencies installed:

```sh
cargo test --manifest-path app/Cargo.toml -p richos-core
cargo build --manifest-path app/Cargo.toml -p richos-core --bin richos-run
cargo build --manifest-path app/src-tauri/Cargo.toml
cargo test --manifest-path app/src-tauri/Cargo.toml pending_instruction_tests
python3 app/scripts/test-managed-run-mutations.py
python3 engine/scripts/lib/owned-session.test.py
bash engine/scripts/hooks/ceo-asks.test.sh
python3 app/scripts/test-owned-escalation.py
python3 app/scripts/test-owned-work-desktop.py
node app/ui/tests/runs.js
node app/ui/tests/docs-claims.js
```

The real-provider probes additionally require the configured Claude account and
consume inference. They create disposable workspaces, not production assignments:

```sh
python3 app/scripts/test-owned-outcome-native.py
python3 app/scripts/test-owned-wake-native.py --incident
```

## Failed measurements and remaining limitations

Initial CLI calibration exposed redundant generated tasks, unrequested behavior
coverage and an optional follow-up offer. Those prompted the single-contract
intake and policy corrections. A later evaluator wrongly assumed a flat JSON
diagnosis layout the request had not required. Its original failed results are
retained. Rescoring accepted equivalent layouts, retained every substantive check
and reran the independent tests; both original trials passed without model nudges.

Early native trials exposed terminal setup assumptions, a missing fixture test
permission and synthetic wake text leaking into source authority. The latter was
fixed and regression-tested. Another composed trial passed behavior but failed
identity verification when a concurrent build relinked the shared runner. It is
retained as failed evidence. The final trial used a read-only binary snapshot and
passed identity verification. Only narrow disposable test commands were permitted;
the trial did not use unrestricted permission bypass.

The final model auditor inspected code rather than executing tests. It overstated
test-execution evidence by inferring it from `__pycache__`. The independent harness
actually ran tests and coverage mutants; that is the execution evidence supporting
our acceptance claim. This remains a limit of model-based review, not a reason to
report that the auditor ran tests. A pre-existing missing-skills warning from the
limited inspector also remains visible. Both observations are in the improvements
list.

The first combined desktop run also failed a fixture assumption: two independent
provider failures had been placed in one conversation. The cancellation safeguard
correctly held the older request behind later unresolved authority. The fixture
now gives them separate conversations while retaining all retry, restart and
recovery assertions. The same-conversation cancellation test remains unchanged.
The corrected full run passed all 13 phases; its first failed log is retained.

Closing both host applications stops execution. State survives for restart; no OS
service is installed. Native ownership is tied to the workspace and Claude session
identity. The adapter does not automatically transfer obligations to an unrelated
new session. Large source input above the audit limit fails as unverified rather
than silently dropping constraints. Decision presentation matching is conservative
and can repeat a paraphrased question it cannot prove was presented.

Desktop work remains serial and retains its existing ten-cycle resource decision.
Registration instead retries hourly after repeated failure. Native auditing has
backoff for inspection failure, not a total cost ceiling. Providers can still fail,
misclassify intent or accept inadequate evidence. None of these paths justifies an
infallibility claim or equating a model's confidence with actual delivery.

## Review map and later activation

Start with `registration.rs`, `owned_work.rs`, `autonomy.rs` and `owned-session.py`.
Then inspect `run.rs` for atomic pause preservation and the policy hook diffs for
adoption boundaries. [Sage's review](SAGE-REVIEW.md) and [Echo's review](ECHO-REVIEW.md)
record discovered defects and tests. Both reviewers implemented assigned fixes,
so their documents are not independent approval of their own edits. The lead
inspected the combined changes and reran the integration checks.

This branch has not changed installed behavior. After review and merge, build and
launch the updated RichOS application for desktop recovery. For native Claude,
build `richos-run` and run the following from a stable checkout whose engine hooks
have also been updated. A disposable linked worktree must not become the permanent
installation path.

```sh
cargo build --manifest-path app/Cargo.toml -p richos-core --bin richos-run
python3 engine/scripts/install-owned-work.py /absolute/workspace /absolute/richos-run
```

Use the installed engine's ordinary hook migration to refresh its local integrity
sidecars, then restart or resume the native session and verify source capture and
wake behavior there. The adapter installer does not replace old engine guard code:
both the updated guard policy and adapter must be available for dependency-based
dispatch. The worktree implementation is reviewable and tested; installed adoption
is a separate deployment step and is not claimed complete here.
