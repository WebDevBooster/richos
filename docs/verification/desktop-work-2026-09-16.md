# Desktop plumbing verification, September 16 2026

Target: app 1.2.0 and engine 1.2.0 on macOS 15.6 arm64. This is source and
candidate verification. It is not the clean-OS installed acceptance receipt and
does not establish that the user can retire the terminal workflow yet.

## Actual component and provider work

Claude Code 2.1.273 ran generic workers and independent reviewers through the
native desktop profile. Two fictional repositories were connected, including
paths with spaces. The target main checkouts stayed unchanged until verified
integration. Checks covered actual provider identities, committed bytes, review
identity, Git ancestry and canonical workspace removal. A recovery probe replaced
the reasoning process between implementation and review in each repository.

A separate natural-language probe supplied a fictional Markdown backlog without
tool names or internal IDs. Rich recorded one obligation, completed both
repositories, obtained independent reviews, integrated locally, cleaned up and
closed the parent obligation through host-verified receipts. This also passed
against an extracted engine archive. The probe's permission responder supplies
synthetic fixture approvals. It does not certify the desktop permission UX.

The opt-in entry point is `richos/app/crates/richos-core/examples/work_roundtrip.rs`.
Its default mode checks process replacement; `--natural` checks the ordinary
assignment. `--revision` exercises a deliberately incorrect fixture through
rejection, continuation and fresh review. The live revision run passed: the actual reviewer rejected the seeded defect,
Rich continued the worker, obtained a fresh passing review, integrated the fix
and retired the rejected-review workspace. These modes operate only on
disposable fictional repositories and never publish.

`loro_ecs_roundtrip.rs` uses the actual delivered Loro writer through the app's
proposal and confirmation desk. Append, supersede, historical-reference reads,
durable desk replay and idempotent ECS projection passed. ECS recorded two
confirmed outcomes and performed zero knowledge writes. This also passed against
the extracted candidate's runtimes and components.

## Automated evidence

- The full core run passed 1,020 ordinary tests and five documentation tests;
  four opt-in/helper cases remained ignored. Later affected library checks passed
  all 551 library cases, with one ignored, and the Tauri suite passed all 98 cases.
- Eleven desktop dispatch/review/integration cases passed. They include dirty
  checkout preservation, cross-session continuation, failure after fast-forward,
  partial cleanup, rejection followed by a corrected review and crash recovery
  after ECS closes an obligation but before its local receipt is saved.
- The canonical Mega Lander suite passed all 76 cases with delivered Python and
  Git. Review-chain cleanup still uses canonical eligibility checks.
- Eighteen ECS cases passed, including scoped import and confirmed Loro receipt
  recovery. Five desktop hook cases and seven evidence projection cases passed.
- The isolated GUI boot harness passed 29 cases. It used copied public components,
  delivered runtimes, an empty launch environment and a stub provider. This is
  useful boot evidence, not a clean OS or live desktop journey.
- A real OS parent-crash check stopped the fictional provider and descendant while
  preserving an unrelated process. Runtime relocation and nested Python execution
  retained the complete inventory.
- Permission-record regressions passed after removing an incorrect automatic
  approval label. Records now report the actual allow/deny outcome without
  inventing how it was obtained.

Live and fault tests found defects in background dispatch payloads, target versus
coordination paths, inherited Git configuration, nested Python bytecode writes,
continued-work identity, cleanup retries and rejected-review cleanup. Those
failures were fixed and affected checks repeated. Failed runs are not counted as
passing capabilities.

## Prepared candidate

Artifact identities are recorded in
[`plumbing-candidate-1.2.0-2026-09-16.json`](plumbing-candidate-1.2.0-2026-09-16.json).
The engine archive reproduced byte-for-byte across two environments. Every
member is accounted for by tracked public source or the verified runtime/license
inventory. The app bundle passed signature, icon, version and engine-pin checks.
Its four regular files contain no copied private corpus, settings or source
checkout. The executable scan found no developer home path, private port-staging
path or injected fixture sentinel.

The exact signed app bundle also booted from outside the checkout under an
isolated canonical HOME with an empty launch environment and a stub provider.
The log resolved the fixture's delivered engine, runtime and Loro read/write
paths. No missing setup component was reported. The first attempt used the
noncanonical macOS `/tmp` alias and correctly stopped at the update lease check;
the corrected fixture passed. Neither attempt is the clean-OS acceptance gate.

## Remaining release gates

The private installed matrix and composed desktop journey remain pending. They
must use the exact app/engine candidate in a clean OS account or disposable VM,
with app-directed account authorization and actual desktop controls. Outstanding
proof includes ordinary permission handling without routine repeated approvals,
Stop/resume and revision steering through the UI, component refusal paths,
installed legacy upgrade/import cases and final artifact provenance.

The current permission desk makes exact, turn-bound decisions and rejects stopped
or stale requests. A fixture that approves every request does not prove that this
meets the ordinary authorized-action requirement. That remains an explicit gate.

No private working context was migrated, live engine pointer activated, public
branch pushed, release published or remote CI enabled. Local ad-hoc signing is
not notarization. An app pin for an unpublished engine URL is not a working
public first-install release.
