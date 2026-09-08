# Workspace cleanup: delivery scope and deferred proposals

Recorded after the user's instruction to stop expanding the scope. This is the
delivery boundary for the current job. It supersedes the broader rollout
prerequisites in the earlier implementation status report. It does not claim
that the implementation or rollout is complete.

## Required outcome

- Automatic cleanup for finished worktrees and dead branches across femcboost,
  richos and richos-hq, including hand-rolled cross-repository work. Respect
  Claude Code's ownership of native worktree cleanup.
- Mechanically gate the managed workflow's finished state on committed work
  being integrated into its intended destination. A model's statement, idle
  notification or session exit is not proof of delivery.
- Reclaim disk space automatically. Retaining every workspace indefinitely or
  repeatedly archiving the entire backlog does not meet the requirement.
- Preserve active work and canonical repositories. Interrupted or unfinished
  work must not be silently classified as finished.
- No administrator prompts or routine user babysitting in normal operation.
- Finish the necessary implementation, test it, obtain the requested Sage and
  Frank reviews, merge, push and activate it.
- After those steps, perform the already authorized batch removal of all
  confirmed dead backlog worktrees and branches, regardless of their dirty,
  staged or uncommitted contents. This exceptional discard authorization does
  not replace the daily completion checks.

Existing Claude Code terminal use is part of the requested environment. Passing
desktop or richos-run tests alone does not establish that the whole job is done.
Terminal compatibility remains an acceptance requirement; replacing the terminal
with an entirely new execution platform is an implementation proposal.

## Remaining delivery checklist

- [x] Identify the smallest existing lifecycle path that meets the requirements
  for both ordinary terminal work and RichOS-managed work. Record any actual
  gap without silently narrowing the user's requested environments.
- [x] Verify the completion gate rejects dirty or unintegrated deliverables and
  accepts a clean integrated result in the intended repository.
- [x] Verify automatic cleanup for native ownership boundaries, cross-repository
  work, dead branches and interrupted cleanup, while preserving active work.
- [x] Verify the configured engine loads and the required lifecycle hooks run.
- [ ] Resolve failures relevant to that delivery path and complete Sage and
  Frank review of the exact changes being shipped.
- [ ] Merge and push the tested changes, then activate the required installation.
- [ ] Retire obsolete cleanup routing and services. Any already authorized
  one-time administrator maintenance for legacy root-owned residue is separate
  from normal product operation.
- [ ] Execute the authorized dead backlog batch and verify remaining worktrees,
  branch lists and reclaimed disk space.

## Deferred proposals, not delivery prerequisites

Existing experimental code is preserved. Listing it here does not approve its
activation or inclusion in the final merge.

| Proposal | Disposition |
| --- | --- |
| Replace unrestricted interactive Claude with a new whole-session launcher | Deferred |
| Preload all three repositories into separate session volumes | Deferred |
| General terminal resume and transcript migration platform | Deferred |
| General native profile, settings and plugin rebasing framework | Deferred |
| Broader authentication, toolchain and network containment redesign | Deferred |
| Extend APFS transfer-generation machinery to every workflow | Deferred |
| Unrelated updater or product improvements | Deferred; retain only changes demonstrably needed to remove the reported prompt paths |

## Scope control

New improvement ideas go into this proposals list. They do not become delivery
requirements because an agent identifies them during review. A concrete defect
that prevents a required outcome is fixed within scope; a broader improvement
stays deferred. If a proposed redesign is truly necessary, state the failing
acceptance case and the reason before expanding the job.

Do not delete unfinished implementation to simplify the branch. Preserve it
separately if necessary and select only the reviewed delivery changes for merge.
Do not describe cooperative hooks as an operating-system security boundary or
claim that arbitrary future writes are impossible. These limits do not excuse
missing ordinary workflow cleanup or dropping terminal support from the job.

## Verification recorded before rollout

The selected branch uses the existing completion hook and terminal reconciler.
Completion verification passed 20 controls. A real installed Claude Code session
kept a dirty fixture task open and accepted a clean integrated fixture with one
receipt. The configured RichOS plugin loaded; the fixture registered the selected
hook explicitly. Installed-file verification follows the canonical merge.

Daily cleanup passed 16 controls, independently repeated by Frank and in the
assembled delivery checkout. The explicit backlog discard passed nine actual
Git controls. The femcboost ECS wrapper uses the same verifier before appending
completion, with refusal controls and its existing crash recovery suite passing.

The selected updater passed its 37 library tests, startup execution test and
69 app tests. The signed updater acceptance run passed ten controls. The broader
prototype runtime is preserved separately and is not included in this delivery.

Normal cleanup is a background operation. Its time budget is checked between
members, so it does not promise a hard cancellation deadline during file reads.
