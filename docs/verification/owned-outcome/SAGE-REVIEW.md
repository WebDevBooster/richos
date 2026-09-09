# Sage review: owned outcome completion

Reviewed the change against SCOPE.md and the CEO's requirement that authorized work
continue through verified completion without routine approval questions. I used
Sage's review discipline: identify the actual execution surface, prefer bounded
changes and distinguish evidence from a confident completion claim.

This review began independently and read-only. The lead then explicitly assigned
me implementation of the concrete intake defects below. The fixes I wrote are
therefore not independently approved by their author; the lead must inspect them
and run the combined checks. No production repository, installed settings or
user session was changed by this reviewer.

## Findings and bounded corrections

1. **P1: recovering registration could execute canceled or outdated work.**
   Registration accepted cancellation and amendment targets only from existing run
   snapshots. A request still waiting for registration had no target. Its recovery
   could create a run before a later cancellation could apply. Saved requests now
   have non-executing target views (`app/src-tauri/src/owned_work.rs:59`). Later
   unresolved instructions fence older pending creation (`owned_work.rs:76`),
   including the interval when a new turn exists in the conversation ledger but
   discovery has not created its request file. A durable cancellation marker is
   saved before superseding the old request (`owned_work.rs:396`). A correction
   becomes the first executable assignment with the prior scope preserved.

2. **P1: interruption before Rich spoke was permanently unregistrable.**
   An interrupted turn can contain an authorized CEO request and an empty assistant
   reply, but quote validation required a nonempty quote from both. Retrying the
   same source bytes could never succeed. `registration.rs:72` now permits absent
   reply evidence only when the actual reply is empty and no Rich commitment is
   claimed. It still requires real CEO provenance and rejects fabricated replies.

3. **P1: repeated corrections could lose original prohibitions.**
   The previous scope was copied into a task but not the persisted plan goal.
   Another amendment read only that goal. Once the original conversation left the
   short context tail, its constraints could disappear. `registration.rs:118`
   persists the complete chain and source context in the goal and execution/review
   contract, including consecutive amendments before the first run exists.

4. **P1: a correction could silently resume explicitly paused work.**
   Existing amendment clears the run pause, and the desktop removed the pause
   marker. The intake now records whether the work was explicitly paused before
   using its transient interruption for live correction (`owned_work.rs:514`).
   User pause is committed atomically with the amendment through Echo's
   `RunController::amend_with_pause` API. This avoids the crash window between
   writing an unpaused amendment and restoring pause in a second journal entry.

5. **P2: restart could bypass registration recovery spacing.**
   The attempt count was saved before inference but the next deadline was only
   saved afterward. A process repeatedly dying during inference could restart with
   an already due request. The deadline is now reserved before the operation
   (`owned_work.rs:337`). Application attempts also precharge their failure count,
   refunding it only after a successful return, so that process death during apply
   cannot evade the same backoff.

6. **P1: a legitimate native decision could repeatedly wake Rich to ask it again.**
   The initial adapter deduplicated only an unchanged full-message fingerprint.
   Rich presenting the decision changed the fingerprint and triggered another
   audit/wake without a CEO answer. The lead added a decision waiting identity and
   presentation check. I also flagged that native AskUserQuestion presentation is
   not ordinary assistant prose. The lead is handling provenance for successful
   native question results. An unpresented or paraphrased question must not be
   silently treated as delivered.

7. **Evidence gap: separate transport and model trials do not establish their
   composition.** The original interactive wake trial used a deterministic
   auditor. The original real-provider trial used `richos-run handle`. They are
   useful evidence for different components, but neither demonstrates the full
   interactive Claude adapter with the real outcome auditor. The lead assigned
   that composed disposable trial after this review raised the gap. Its result
   belongs in the final evidence record, not as an assumption here.

## Verification performed here

- `cargo test --manifest-path app/Cargo.toml -p richos-core --test registration_tests`:
  10 passed, including empty interrupted reply and three consecutive corrections
  with no supporting conversation tail.
- `cargo test --manifest-path app/src-tauri/Cargo.toml pending_instruction_tests`:
  3 passed. These cover causal fencing, durable cancel replay and amendment of a
  pending request without losing its publication prohibition.
- `python3 app/scripts/test-owned-work-desktop.py --pending-only`: passed against
  the actual debug app with a scripted native provider. The harness submits the
  cancellation while the initial registrar sleeps. Both requests become resolved,
  the old request gets a durable cancellation marker and no executable run is
  created. Evidence directory:
  `/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-desktop-95vsb47y`.
- Initial test compilation failed because I assumed a `tempfile` dependency existed.
  It does not. The tests use standard-library temporary directories instead. The
  failed commands were not reported as green and no dependency was added.

After the atomic pause API was wired, the 10 registration and 3 pending-instruction
tests were rerun and passed. Echo separately reports all 44 core run tests passing,
including atomic pause persistence and transient interruption recovery.

The lead is responsible for the final combined build, desktop suite and real
provider evidence after these and other parallel changes.
The targeted passing runs above are not a claim that those later checks passed.

## Strongest counterargument

This still delegates semantic judgment to models. A persistent owner, exact source
scope, challenge review and native wake transport cannot prove that every future
reviewer will correctly distinguish obsolete tests from defects or recognize every
business dependency. Repeated review also has real cost and latency. Therefore a
claim of universally infallible autonomous operations would remain false.

The strongest argument for this implementation is narrower and testable: the
observed failure is no longer protected only by doctrine. Authorized work remains
owned despite a noncommittal reply or registration failure, canceled pending work
cannot restart, corrections retain source constraints and a native session receives
an actual continuation event. Completion claims must stay tied to the exercised
surfaces and measured scenarios. Closing both host applications still stops
execution; this change does not install an operating-system service.

## Scope discipline

Do not expand this change into a new framework, general policy rewrite, cleanup
redesign or historical backlog execution. Suggestions remain in IMPROVEMENTS.md.
The causal fence deliberately delays an unstarted assignment in the same
conversation while a later instruction has not been classified. Another company's
work remains independent. That is the bounded cost of preventing a stale request
from executing while cancellation or a scope restriction is unresolved.

## Combined desktop fixture diagnosis

The first combined 13-phase run stopped at `registration-failures`. Its retained
log is `/tmp/richos-owned-desktop-final.log` and its evidence directory is
`/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-desktop-9winh3cg`.
The persisted requests establish the cause: the older malformed request had zero
attempts, while the newer inconsistent classification had three attempts and a
future recovery deadline. Both belonged to the same conversation.

The assertion that both must independently reach three attempts was obsolete under
the new causal rule: an unresolved later instruction may cancel or narrow the
unstarted older request. It must be classified before that older work can proceed.
There was no evidence that retry scheduling itself was broken. The selftest now
puts the two independent provider-failure cases in separate conversations. It
retains the exact three-attempt assertions, two durable reports, no worker launch,
restart preservation and eventual fourth-attempt recovery. The separate
`pending-cancel` phase still verifies cancellation within the same conversation.
Production behavior was not changed to satisfy the old fixture.

After the fixture correction, the complete actual-desktop suite passed all 13
phases with process exit 0. This includes live correction, pending cancellation,
independent work, registration failure, restart, automatic recovery and panel
decisions. Final log: `/tmp/richos-owned-desktop-final-r2.log`. Final evidence:
`/var/folders/mx/w46p9btx1t17wv9tbsq885qw0000gn/T/richos-owned-desktop-obe9mals`.
