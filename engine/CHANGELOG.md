# Changelog

All notable changes to the **RichOS engine** are recorded here.

The engine follows [semantic versioning](https://semver.org/) as defined for a
doctrine + hooks product in [`VERSIONING.md`](./VERSIONING.md) (what counts as
MAJOR / MINOR / PATCH), and this file follows
[Keep a Changelog](https://keepachangelog.com/): each release gets a dated
version heading with Added / Changed / Fixed groupings.

## [Unreleased]

### Added

- **Teammate worktrees are bound to the platform agent id at spawn and
  terminalized at the first terminal event; no sweep decides liveness any
  more** (`scripts/lib/worktree-transactions.py`,
  `scripts/hooks/guard-sealed-worktree.sh`, `record-subagent-start.sh`,
  `terminalize-agent-worktrees.sh`, `scripts/reconcile-terminal-worktrees.py`,
  and the rewritten `create-teammate-worktree.sh`,
  `guard-worktree-isolation.sh` clause 7, `detect-nonnative-worktree.sh`
  binder, `guard-resume-isolation.sh` terminal refusal,
  `session-start-reap-worktrees.sh`; `docs/worktree-lifecycle-transactions.md`)
  — MINOR, implementing femcboost `docs/plans/worktree-real-fix-2026-09-03.md`.

  Seven designs were rejected before this one, nine rounds failed in nine
  shapes, and the CEO ruled: *"The system should stop trying to discover
  whether the agent might return. It is forbidden to return."* So ownership is
  recorded at the one moment it is certain — the spawn — keyed by the
  platform's own `session_id`, `tool_use_id` and `agent_id`: a `prepared`
  record when `create-teammate-worktree.sh` creates a cross-repository tree
  (verified against git, fsynced, rolled back with the tree if it cannot be
  written); a `spawn-intent` written by the isolation guard with the EXACT
  member set before the Agent call may run; a `bound` record when the lead's
  PostToolUse joins the acknowledged agent id to that intent (or the parent
  transcript's exact call/result join, shared with every other consumer);
  a start fact from the worker's own SubagentStart; and a `sealed` manifest
  when both agree, in either order. Until sealed, a matcherless PreToolUse
  barrier refuses every potentially writing tool (Bash, Agent, editors,
  unknown and MCP tools) and permits only a read-only allowlist. The FIRST
  SubagentStop or WorktreeRemove claims the transaction by compare-and-set
  (exactly one wins; the loser resumes idempotently), writes a backup ref
  `refs/richos/handoffs/<session>/<agent>/<branch>` in each repository BEFORE
  anything moves, quarantines every member by atomic rename beside its path,
  and re-points git at the quarantine so a prune cannot orphan it. A
  persistent launchd job (installed by `install.sh`) then kills residual
  writers, requires two identical manifests across a settle, archives raw
  bytes plus index blobs plus provenance, verifies every digest, unregisters
  and removes — each transition persisted so a crash at any boundary is
  recovered from disk; SessionStart runs the same reconciler as crash
  recovery with a budget. A terminal agent is refused every `SendMessage`
  with no escape hatch. TeammateIdle and TaskCompleted hold no destructive
  authority (the agent-finish reaper is gone); the session-start reaper is a
  DRY-RUN inventory. Ownership in the ledger is exact-path only: names,
  branches and transcript joins are reported and never authorize a removal.
  Every piece is registered on both surfaces and the probe's managed set,
  and every suite runs a mutation harness that turns a named case red per
  property: 51 + 37 + 20 + 32 + 162 + 58 + 12 + 35 + 27 + 58 + 26 + 15 + 10
  cases, 85 mutants.

- **A turn whose report does not match its actions is refused**
  (`scripts/hooks/guard-stated-actions.sh` + `.py`, `stated-actions.corpus.md`,
  `guard-stated-actions.test.sh`, `stated-actions.mutation.sh`) — MINOR.

  On 2026-09-02 the lead wrote "Zach builds it tomorrow" and "Frank breaks it
  first" in turns that made no Agent call, and six times answered a returned
  teammate with a report and started nothing; the CEO restarted each one by hand
  ("WHERE THE FUCK IS FRANK THIS FUCKING TIME"). `guard-idle-land.sh` saw all
  three of the evening's finishes and stood down on its backlog term. A blocking
  `Stop` hook now reconciles the final text against the turn's own tool calls in
  two arms. ARM 1: a roster role as the subject of a present-simple act with a
  pronoun or determiner object, or a first-person dispatch naming who, in a turn
  with no Agent call — replayed through the shipped analyzer over 1,280 real
  turns: 2 fires, both the defect, 0 false; the role-future shape measured 0/2
  and only reports. ARM 2: a host-written Agent-finished notice in the turn, no
  Agent call, no backgrounded command, no question to the CEO, no hold, and no
  `stop-declared:` line — every term imported from `guard-idle-land.py`, so the
  engine has one declaration vocabulary; 265 of 368 completion turns in the
  corpus were undeclared stops and an independent reader agrees on all 265. The
  refusal names the clause or the finished agent and the exact declaration line;
  fails open on every error; cannot fire on its own output (quotes, fences and
  code spans are stripped before reading). Registered on both surfaces, in the
  probe's spec table and Layer R, and in the demo's analyzer list; 31 mutants,
  each proven load-bearing; the harness runs from the house suite as SA2.

- **The model capability order is data in one place, and a move DOWN it is
  stated or refused** (`orchestration.config` `MODEL_TIERS`,
  `scripts/lib/model-tiers.sh`, `scripts/hooks/guard-worktree-isolation.sh`
  clause 6, `scripts/hooks/contract-integrity-probe.sh` Layer MT) — MINOR.

  The doctrine had said "don't downgrade" since it was written and never once
  said which direction down was. On 2026-09-02 the orchestrator decided, out of
  nothing, that a Sonnet-default teammate spawned on Fable was a downgrade,
  killed the correctly-configured teammate, told the CEO he was correcting an
  error that did not exist, and commissioned a guard whose fixtures would have
  refused that correct spawn shape permanently. It is an upgrade. The CEO
  caught all three. A rule left as prose was broken; a guard built on the same
  prose would have made the error permanent and given it authority.

  So the order is declared ONCE, as data: `MODEL_TIERS="fable > opus > sonnet >
  haiku"` beside `ALLOWED_MODELS` — `>` separates tiers, leftmost is most
  capable, aliases sharing a tier are equal — with a re-derivation note and
  a rule that no consumer may infer capability from an alias name. Every
  consumer reads it through one parser. Clause 6 of the spawn guard fires only
  on an explicit `model:` override: a LOWER tier than the definition's own
  default is refused, naming the teammate, both models, both ranks and the
  exact `model-downgrade-ack: <reason>` line to add (logged like every other
  hatch); equal or higher is silent, always. It fails OPEN on its own error —
  a missing parser, a malformed or blank declaration, an unranked alias —
  with a notice, never a refusal. Layer MT refuses a declaration whose alias
  set drifts from `ALLOWED_MODELS`, a doctrine file that quotes a different
  order than the declaration, and a doctrine file that still says "downgrade"
  without pointing at the data; it also runs the guard two-sided (a lower
  tier refused, a higher tier silent) so a dead guard cannot pass. Mutation
  harness extended with the incident's own inversion (the comparison flipped:
  Sonnet -> Fable refused, Opus -> Sonnet waved through) and the over-blocking
  arm (same tier taxed), all run by `contract-integrity.test.sh` WTI1 — no
  ninth unrun harness.

- **A defect the tree can show you becomes a row, written by the machine that
  found it** (`scripts/hooks/notice-mechanical-findings.sh`,
  `scripts/lib/mechanical-findings.{sh,py}`, `scripts/mechanical-findings-lint.sh`,
  `reference/mechanical-findings/`) — MINOR.

  On 2026-09-02 an audit found eight real defects in twenty minutes that six weeks
  of attention had missed, and the one known for six weeks sat under a CI comment
  reading "Tracked separately" — tracked in none of the three queue files. The
  audit ran because the CEO asked; the findings became rows because the lead typed
  them. Both links were a person. Now a `Stop` hook reads the record's own declared
  artifact roots at HEAD for three MECHANICAL facts — a suite skipped in a workflow
  by name, a mutation harness no script or workflow names on a code line, a
  registered hook no test names — and appends a row for each finding it does not
  already see, in the record's own format, with a warrant minted by the landing
  guard's own `identity()`, carrying its identity as `` `finding:<class>:<path>` ``
  so the same defect on the next run is one row and not two. It never edits an
  existing row; it names a row whose finding is gone and a row closed over a live
  finding; `finding-exempt: <reason>` in the source is honored and reported.
  Calibrated on the real roots: reproduces the audit's F5 list exactly (7 of 7
  unrun harnesses) and F2 until its fix landed, zero false positives. Proven on the
  real record: nine rows written by the machine, read back off disk, accepted by
  `row-currency-lint.sh`, named by `unstarted-rows-lint.sh`, and a second run
  wrote nothing. 44 cases, 28 mutants killed. Named blind spots in the reference.

- **A generic agent is not a teammate: staffing is now gated separately from
  worktree isolation** (`scripts/hooks/guard-worktree-isolation.sh` clause 5,
  `orchestration.config`: `HARNESS_UTILITY_TYPES` / `GENERIC_AGENT_TYPES`).

  `READONLY_ALLOWLIST` answered one question — does this agent need an isolated
  worktree? — and it was read as answering a second: may work be STAFFED to this
  type at all? On 2026-09-02 an engine-wide audit was dispatched to `Explore`, a
  generic built-in, because a roster teammate would have needed a worktree
  created first and the built-in could be dispatched immediately. Nothing
  refused it, correctly by the old contract. A comment was added to
  `orchestration.config` saying the exemption is not a staffing permission, and
  a comment is prose; prose did not hold.

  Clause 5 refuses a spawn of a generic type unless the prompt carries a live
  `generic-agent: <why no roster teammate fits this work>` line, in the shape
  already used by `main-checkout-run:`, `resume-ack:` and `hand-roll-ack:`. A
  bare marker exempts nothing (≥ 30 characters, ≥ 5 words, ≥ 3 distinct
  substantive words), and a SPEED or CONVENIENCE reason is refused by name —
  that was the rationale in the incident, and needing a worktree first is a
  single call to `scripts/create-teammate-worktree.sh`. Accepted uses are logged
  to `.claude/state/generic-agent-dispatches.log`. The refusal names the
  alternative rather than saying only no: a generic agent never appears in the
  team display and leaves no commit, so work sent to one disappears from the
  CEO's view and from the record.

  `statusline-setup` and `claude-code-guide` are NOT gated — they configure or
  explain the harness itself and carry no delegated work, and a gate that fires
  on a statusline change is how a defense becomes a nuisance and then a
  formality. That exemption is config (`HARNESS_UTILITY_TYPES`), not code, and
  the default is deny. `GENERIC_AGENT_TYPES` closes the obvious detour:
  `general-purpose` is file-capable, is not on the read-only allowlist, and
  passed the whole contract before.

  **The isolation exemption is unchanged.** An allowlisted type that satisfies
  clause 5 still spawns with no isolation and no name. Both properties are
  proven separately: 37 new suite cases, and a new
  `scripts/hooks/guard-worktree-isolation.mutation.sh` whose 10 mutants are all
  load-bearing — three of them in the OVER-blocking direction, including the one
  that folds the isolation exemption into the staffing gate.

- **A CEO item can now state the fact its question rests on, and a landing that
  moves that fact is refused** (`scripts/lib/row-currency.py`,
  `scripts/lib/row-currency.sh`, `scripts/lib/ceo-todos.py`,
  `scripts/lib/ceo-todos.sh`) — MINOR, and opt-in per repository.

  Two mechanisms already stood over the CEO's page and neither answered the
  question that rotted an item on it. `.row-currency` asks *is this row still
  describing the work?* — and it governs section 3 only. The `Done-check` asks
  *is this already finished?* On 2026-09-02 an item was neither: it asked the
  CEO to rule on whether a repository should enforce its own rules, resting on a
  measurement taken on 2026-08-30 — both contracts committed, "nothing reads
  either of them", 28 commits that day with no check running. Three days later
  that was false: scope is declared by the DESTINATION, and both guards had
  refused commits into that repository three separate times that same day while
  34 commits landed checked. The item was never finished, so its Done-check was
  correctly unsatisfied and correctly silent. **Its premise had rotted, and no
  machinery had an opinion about premises.**

  So an item in a CEO section may carry a `- **Premise:**` warrant that pins the
  observable fact its question rests on, by object id, exactly as a section-3
  row pins work:

  ```
  - **Premise:** `richos/engine/scripts/hooks/guard-x.sh`@`1789d2589cde` — this
    guard exits before it reads the destination's declaration
  ```

  When that object id moves, the next landing is refused, naming the item and
  what moved, and printing the warrant to paste beside a sentence somebody has
  to decide is still true. There is no re-stamp command and no override, for the
  reasons the row contract already states. The STATED FACT is part of the
  warrant: a pin with no sentence beside it clears by retyping a hex string,
  which is the original defect wearing a fix's clothes — and is what the rotted
  item had, its premise sentence thirty lines below in prose, attached to
  nothing.

  Not every question rests on something observable, and forcing a pin would
  produce fiction — "run `railway login`" rests on no artifact. An item may
  declare `unobservable "<why not>"`, on the `DONE-CHECK-MANUAL` precedent: a
  bare marker exempts nothing, the reason is required, and every such
  declaration is COUNTED AND PRINTED by a census that rides on every verdict,
  clean or not, because the correct output for an unobservable premise is
  silence and silence is also what a checker that never ran produces.

  Declared in the record repository's `.ceo-todos` — `PREMISE_SECTIONS` (a
  subset of `CEO_SECTIONS`; undeclared = not adopted, and the census says so)
  and `PREMISE_REQUIRED` (`0` names every premise-less item, `1` refuses).
  It lives there rather than in `.row-currency` because the CEO sections are
  that declaration's jurisdiction and `CEO_SECTIONS` is already stated there
  once; a subset named in a second file is the copy-of-a-fact drift this engine
  keeps finding in itself. It is CHECKED by `row-currency.py`, which is the only
  place in the engine that compares an object id — the stamp walk was extracted
  into one function serving both warrants rather than a second staleness
  implementation, and the section-3 refusal sentences are asserted at runtime,
  byte for byte, against what they said before.

- **RichOS owns the worktree ownership record, so a worktree's owner can be
  judged after the harness's lock is gone** (`scripts/lib/worktree-ledger.py`,
  `scripts/create-teammate-worktree.sh`, `docs/worktree-ownership-ledger.md`)
  — MINOR for the record, **MAJOR-class for the two contract changes below**.

  A hand-rolled worktree (cross-repository work) takes no git lock, so the
  reaper judged it from its owner's NATIVE isolation-worktree lock — which a
  land deletes. From that moment the tree was permanently undecidable:
  cleaning up one repository destroyed the only evidence that could ever clean
  up another. Four forward-only fixes left 29 of 29 `richos` worktrees
  `owner-undecidable` on 2026-09-02. Now `~/.claude/state/worktree-ledger.jsonl`
  records every spawn that ran (teammate, agent id, session id, session pid +
  start time, paths, branch), every WITNESSED termination the reaper or the
  remover observes (copied the moment it is seen, once per agent), and the
  three lifecycle signals as advisory. Owners are judged from the ledger
  first, then from an index of EVERY transcript (not the newest file under
  the swept repository's slug — a directory that never holds one for a
  cross-repository sweep), and a session with no pid on record is proven over
  by exhaustion of the process table against the harness's own
  `~/.claude/sessions/<pid>.json` registry. INDETERMINATE and UNRESOLVED are
  never collapsed; absence is never death; finish signals never decide.

  Cross-repository worktrees are created, seeded from `.worktreeinclude`, and
  registered by `scripts/create-teammate-worktree.sh`, which prints the two
  spawn shapes (`cwd:` without isolation, or a `cross-repo-worktree:` prompt
  line with it).

### Changed

- **`guard-worktree-isolation.sh` clause 4 — a cross-repository spawn is
  admitted only into a worktree RichOS registered** (MAJOR-class: the guard
  now blocks shapes it previously allowed). A `cwd` spawn passes only when
  `cwd` is the top level of a linked worktree with a ledger registration;
  `cwd` together with `isolation` is refused as mutually exclusive; every
  `cross-repo-worktree:` line must name a registered path; and a prompt that
  instructs the teammate to run `git worktree add` is refused (`hand-roll-ack:
  <reason>` is the audited escape hatch). Clauses 1-3 are not relaxed.
- **`scripts/reap-stale-worktrees.sh` — exit-code contract and report**
  (MAJOR-class): a hand-rolled worktree with NO ownership record is
  `owner-unresolved` and the run ends `verdict: FAIL`, **exit 3**; a known
  owner whose session still runs is `owner-indeterminate`, `verdict: PENDING`;
  everything decided is `verdict: CLEAN`. Both wrappers announce the verdict
  FIRST. Non-teammate worktrees (a CI checkout, another tool's) are
  `operator-worktree`: inventoried, never mutated, never a verdict. A pass
  over `refs/heads/` sweeps merged teammate-shaped orphan branches
  (`branches-swept=N branches-skipped=N`); an unmerged orphan is reported and
  kept. `--transcript` is repeatable; `REAP_WORKTREE_LEDGER` is a new test
  affordance that every sandbox run must set.
- `scripts/remove-agent-worktree.sh` copies an observation-based NOT-ALIVE
  verdict to the ledger before removing; never an absence-based one.
- `scripts/hooks/install.sh`, `scripts/demo.sh` and the meta-suite's sandbox
  list carry the two new files.

### Fixed

- **A failed `git worktree repair` was recorded as a successful quarantine**
  (`scripts/lib/worktree-transactions.py` `quarantine`;
  `scripts/reconcile-terminal-worktrees.py` no-progress reporting;
  `worktree-transactions.test.sh` T53–T54, mutant `repair-result-ignored`) —
  PATCH, review 2026-09-03 blocker 6. The repair's return code, stdout and
  stderr were ignored and the member advanced to `quarantined` regardless;
  the main repository could still point at the vanished original, and the
  next prune deleted the admin directory the quarantine's `.git` file points
  at — the index the reconciler claims to preserve. The member now advances
  only when the repair exits 0 AND git lists the quarantine as the exact
  registered, non-prunable path; otherwise it stays `ref_saved` with the
  quarantine recorded, the directory preserved, `attempts`/`last_error`
  written on the member, and the step retried by the next run (reported
  once after the soft-attempt ceiling, like any other retryable failure).

- **Terminal revocation was not crash-consistent: the transaction and its
  two derived indexes were three writes, and only the indexes were read**
  (`scripts/lib/worktree-transactions.py` `claim_terminal`,
  `is_terminal_agent`, `_repair_terminal_indexes`, `RICHOS_TX_CRASH_AFTER`;
  `guard-sealed-worktree.sh`, `guard-resume-isolation.sh`,
  `reconcile-terminal-worktrees.py`; `worktree-transactions.test.sh`
  T55–T58, `guard-sealed-worktree.test.sh` G22–G23, mutants
  `terminal-index-is-truth`, `loser-does-not-repair`,
  `terminal-from-index-only`) — PATCH, review 2026-09-03 blocker 5. A crash
  after the transaction's terminal write but before either index left a
  terminal worker that every guard read as live. The transaction is now the
  source of truth: `is_terminal_agent(agent_id, session_id)` consults it
  when the index is absent (exact session, or every session's record for the
  exact agent id when no session is known) and repairs the index on the way
  out; every claim (winner and loser), every terminalize, the barrier's
  sealed path and every reconciler pass repair the derived indexes
  idempotently; and a test-only crash point after each of the three writes
  proves each is survivable.

- **An unsealed worker's only terminal event was discarded, and the suite
  asserted it** (`scripts/lib/worktree-transactions.py`
  `record_pending_terminal`, `claim_terminal`, `try_seal`,
  `find_unsealed_by_native_path`, `iter_pending_terminals`;
  `terminalize-agent-worktrees.sh`; `reconcile-terminal-worktrees.py`
  `process_pending_terminals`; `orchestration.config`
  `PENDING_TERMINAL_GRACE_SECONDS`; `terminalize-agent-worktrees.test.sh`
  R21 INVERTED + R21b–R21e, `reconcile-terminal-worktrees.test.sh` C26–C28;
  mutants `pending-not-recorded`, `seal-ignores-pending`,
  `worktreeremove-unsealed-ignored`, `pending-for-nobody`, `grace-ignored`,
  `fallback-never-built`) — PATCH, review 2026-09-03 blocker 4. R21 used to
  assert that a bound-but-unstarted agent's `SubagentStop` left its worktree
  present and created no terminal marker; that was the defect written as a
  test, and it is inverted. Now every attributable terminal event (the
  session holds a bound or a start record for the exact agent id) is
  persisted at once as `pending-terminal/<agent_id>.json`, the agent is
  terminal by policy from that moment, and `try_seal` consumes the pending
  event the instant the manifest seals — claim, terminalize, quarantine.
  `WorktreeRemove` for an unsealed native path resolves the platform's own
  `agent-<id>` to an agent this session has a record for and records the
  same fact. A pending event nothing can seal within the grace period is
  routed by the reconciler through creation-time ownership: the bound
  record's prepared external members, verified against git exactly as the
  seal would have, plus the native member only if a start fact names one
  that still verifies — never a name, never a guess. A pending event with no
  bound record owned nothing and is dropped after grace.

- **Native evidence could be deleted before quarantine: the terminal ingress
  saved every repository's backup ref before renaming anything**
  (`scripts/lib/worktree-transactions.py` `terminalize`;
  `worktree-transactions.test.sh` T51–T52, mutant `refs-before-any-rename`) —
  PATCH, review 2026-09-03 blocker 1. The `WorktreeRemove` hook has a 20s
  budget and any git subprocess may take 30s; with two passes (save every
  ref, then quarantine every member) a stalled external repository exhausted
  the budget while the native path — the one the platform was about to
  delete — still stood at its original name. Members are now processed one
  at a time, the named native path first: its ref is saved, it is renamed,
  the transition is persisted, and only then is any other repository
  touched. T51 stalls the external repository's git, kills terminalize at 6s
  the way the harness kills an overrunning hook, and asserts the native
  member is `quarantined` on disk and in the record while the external is
  still `bound` and untouched; T52 finishes it on the next run.

- **`install.sh --force-engine-pointer` scheduled the reconciler from a test
  fixture** (`scripts/hooks/install.sh`; `install-reconciler-schedule.test.sh`
  S11–S16) — PATCH. The ephemeral/worktree facts were computed only when the
  flag was off, and the launchd step read them; a forced run from a temp
  checkout with a redirected HOME (`global-state-witness.test.sh` c4) passed
  every withholding branch and bootstrapped `gui/<uid>/com.richos.worktree-
  reconciler` at a directory deleted a second later. The facts are now
  computed unconditionally and the flag governs the pointer alone; a HOME that
  is not the account's passwd home withholds the schedule outright, because
  `gui/<uid>` is per-account and cannot see a redirected HOME; the suite shims
  `launchctl` so it can never re-create the leak it catches.

- **The evidence collector read the wrong repository's directory list and
  mirrored into the wrong checkout** (`scripts/collect-worktree-artifacts.sh`;
  new `scripts/collect-worktree-artifacts.test.sh`) — PATCH by
  `VERSIONING.md`'s adopter-impact question: the only path that changed was one
  that never produced a correct result, and what an adopter can now observe is
  a refusal where there was a mis-write.

  Run by reference, the collector resolved "the main checkout" as its own
  parent — the ENGINE — and sourced the engine's `orchestration.config`. For
  femcboost that meant three directories where nine are declared: both
  `visual-screenshots` trees and both per-tree `playwright-report` trees were
  invisible to the one step whose job is saving QA evidence before a worktree
  is destroyed, and the three it did see were rsynced into the engine checkout.
  It reported `done`. Two collections ran that way on 2026-09-02 ahead of
  worktree removals; both trees happened to be docs-only. The same call sits
  inside `reap-stale-worktrees.sh` before every removal it performs.

  Now: the root comes from the two-root contract (`scripts/lib/resolve-roots.sh`,
  as `remove-agent-worktree.sh` already does) — `$RICHOS_ENTITY_ROOT`, else
  `$CLAUDE_PROJECT_DIR`, else `$PWD`; never `$SCRIPT_DIR/..`. No governed
  entity, no `orchestration.config`, or a config declaring neither
  `ARTIFACT_MERGE_DIRS` nor `ARTIFACT_REPLACE_DIRS` is a REFUSAL (exit 2, root
  contract banner), not a fallback: the built-in default list is gone, because
  a step that proceeds on a wrong-but-plausible value reports success over the
  evidence it never saved. A declared-empty list is honored. Every run states
  the entity root and how it was resolved, the config file it loaded, and each
  list with its count, before it touches anything. The suite reproduces the
  bug against the previous source (0 of 13 pass: 3 of 9 collected, into the
  engine) and is discovered by `run-all-tests.sh` (52 -> 53 suites); 7 mutants,
  7 killed.

- **A `**Blocked:** nothing` declaration silenced the row it was written to
  surface** (`scripts/lib/unstarted-rows.py`). Rows 3.19 and 3.20 of the real
  record each read `**Blocked:** nothing — buildable now, nobody blocked.` and were
  classified DECLARED because the construct's presence was taken as a declaration
  without reading what it declared. A `**Blocked:**` is now judged by its first
  word, as the queue's `Blocked by` cell already was; six rows of the real record
  surfaced the moment it was fixed. Suite 35 -> 38, harness 37 killed / 0 survived.

- **The unstarted-row sweep had been standing down in the seat the operator
  actually runs in.** `femcboost` had no `.row-currency`, so every turn-end
  sweep resolved no record and wrote `verdict: STOOD-DOWN` to a receipt nobody
  read. Fixed on the femcboost side by a one-line peer declaration; recorded here
  because it is the engine's third link that was dark.

- Three suites (`reap-stale-worktrees.test.sh`, both reaper-wrapper suites)
  set `RC` inside a command substitution — a subshell — so every
  `[ "$rc" -eq 0 ]` assertion they carried was true by initialization. They
  now capture the exit code. `task-completed-handoff.test.sh` had been dying
  at EOF.

- **A file can now be declared private BY IDENTITY, and both publication guards
  enforce it** (`scripts/lib/publication-boundary.sh`,
  `scripts/lib/publication-boundary.py`, `scripts/hooks/guard-publication-writes.sh`,
  `scripts/hooks/guard-publication-commits.sh`,
  `scripts/hooks/publication-boundary.test.sh`) — MINOR.

  The boundary's two detectors are scoring functions. They were measured against
  the 2026-08-29 transcripts and they are sharp for transcripts, and they are
  blind to a small named file that is private for a reason no scoring function
  can see. **Measured 2026-09-01, both halves: a seven-line note about which
  typeface a wordmark was drawn in was written into the publication-bound tree
  and staged, and both guards returned 0.** The instruction to keep that file in
  the private record had been given twice, and twice it was honored by somebody
  remembering.

  `PRIVATE_FILES` in `.publication-boundary` takes `<64-hex-sha256>:<name>`
  entries and MAY BE REPEATED, so declaring the next file is a one-line diff;
  every other key now refuses a second occurrence instead of letting the last
  line silently win. A declared file is refused **renamed** (the digest travels
  with the content), **reformatted, recased or re-encoded** (the digest covers
  the normalized word sequence as well as the bytes), **into a gitignored path**
  (a file with one home does not belong here in any form), and **as a binary
  blob** — which is not a hypothetical: the first file declared is UTF-16, so
  every text-shaped filter in the pipeline called it binary and dropped it before
  anything looked at it. What defeats it is a rewrite AND a rename together, or a
  partial excerpt under a new name, and the header says so rather than leaving it
  to be discovered.

  **Nothing reads the private record at guard time.** The digest and the name are
  committed, so a fresh clone with no sibling checkout enforces exactly what the
  author's machine does — the machine that matters, being the one where nobody
  has heard the rule. The cost is that the NAME is public; the content is not,
  and that trade is written down where an operator declaring the next file will
  see it.

  Mint an entry with `publication-boundary.py --digest <file>`. The minter lives
  inside the scanner rather than beside it, because a second copy of the recipe
  is a declaration that protects nothing while looking exactly like one that
  does — pinned by a mutation case that fails the moment the two disagree.

  Suite 85 -> 121 cases; nine mutations, one at a time, each turning red before
  the case it belongs to was believed. Zero findings across all 1,159 tracked
  files in the repository, against a corpus of 14 files / 130,466 words.

  **ADDING A KEY TO THIS DECLARATION IS A TWO-LAND CHANGE, by construction, and
  the next person should expect it rather than discover it.** An unknown key is
  BROKEN to the engine reading the file, the engine every repository reads is
  the one on main, and a branch is not on main — so a declaration carrying the
  new key refuses every commit in its own repository until the engine that
  understands it has landed. Measured on this change: three registered hooks
  refused, by name. The mechanism lands first and the entry that arms it is a
  one-line commit after that. This is the unknown-key rule working, not a defect
  in it; the alternative is an engine that quietly ignores settings it does not
  understand, which is the failure this whole file is about.

### Fixed

- **The removal guard blocked the read that CHECKS a removal, and did it during
  the sweep it exists to protect** (`scripts/hooks/guard-worktree-removal.sh`,
  `scripts/hooks/guard-worktree-removal.test.sh`,
  `scripts/hooks/guard-worktree-removal.mutation.sh`,
  `scripts/hooks/contract-integrity.test.sh`) — PATCH.

  Measured 2026-09-02, mid-amnesty-sweep. The command was

  ```
  ls -d <path> 2>&1; git branch --list 'worktree-agent-a58289*'
  ```

  the verification step taken immediately after a removal had succeeded — two
  reads, no mutation of any kind. It was BLOCKED as `git branch -D of a
  worktree-* branch`.

  The rule's three conjuncts were three INDEPENDENT `re.search` calls over the
  WHOLE command string. `git ... branch` matched the listing, `worktree-\S+`
  matched its glob, and `-[dD]` matched the **`ls -d`** — a different verb, in a
  different clause, that deletes nothing. `sort -d`, an earlier `ls -d`, or a
  `-D` inside an `echo` would each have done it, and the sibling report was
  `git merge-base --is-ancestor <branch> main` going the same way.

  **This is not a nuisance, it is how a defense decays.** The one command an
  operator runs immediately after every removal is the command that proves the
  removal happened — the "verify the ARTIFACT, not the exit code" discipline.
  A guard that fires on THAT is a guard whose ack token gets pasted in by habit,
  and an ack pasted in by habit is a guard that no longer decides anything.

  Fixed by scoping: flags are read from the arguments of the git invocation that
  OWNS them (`git -C <repo>` and friends skipped so the subcommand is found),
  and an invocation whose subcommand is read-only — `list`, `for-each-ref`,
  `merge-base`, `rev-list`, `rev-parse`, `show`, `log`, `status`, `diff` and
  their kin — can no longer contribute a reason at all. Recall is unchanged: a
  destructive invocation is still caught wherever it sits, so a read-only verb
  in an earlier clause cannot launder a `git worktree remove` in a later one.

  **The test is two-sided on purpose, because a false positive can always be
  "fixed" by disabling the guard.** 11 `RO*` cases assert the reads pass, 8
  `RD*` cases assert every destructive shape still blocks (44 -> 63). Three new
  mutants hold both directions: M5 reverts the clause scoping, M6 lets the
  read-only allowlist swallow `worktree` and `branch`, M7 stops skipping
  `git -C`'s value. M5 is the instructive one — widening the argument run turns
  RO2 into a false positive **and** RD3/RD4/RD5 into false negatives at the same
  time, because the read-only verb at the head of the line then owns the whole
  line.

  And the harness that proves all of this was **run by nothing**:
  `run-all-tests.sh` discovers `*.test.sh` from disk, so the behavioral suite
  ran, but a `*.mutation.sh` is outside that glob and no house suite invoked
  this one. Contract-integrity now runs it as `WTR1`, the way `IL7` and `CL2`
  already run theirs.

- **The worktree reaper ran, reported success, and swept a room that was
  already empty** (`scripts/reap-stale-worktrees.sh`,
  `scripts/hooks/agent-finished-reap-worktrees.sh`, both wrappers,
  `hooks/hooks.json`, probe Layer Q, two new suites) — MINOR.

  At session start on 2026-09-01 it printed
  `reaped=1 skipped=0 errors=0 residue=0`. By evening there were 19 registered
  worktrees in one repository and 6 more in another that it had never looked
  at, in that session or any session before it. **Nothing was broken.** Three
  scope assumptions were wrong and the summary line was written as if none of
  them existed:

  1. **One repository.** It resolved a single repo root. The engineers were
     working in two others.
  2. **One path convention.** It scanned `.claude/worktrees/agent-*`, the
     native isolation layout. The trees that accumulated were hand-rolled.
     **The design assumption was inverted:** the project's own doctrine
     REQUIRES hand-rolled worktrees for cross-repository work, so the reaper
     covered the rare case and missed the standard one.
  3. **One moment.** SessionStart only. A twelve-hour session accumulated
     everything and cleared nothing until the next session opened.

  Fixed as SCOPE, not as a second reaper — two sweeps each certain about their
  own half is the same defect one level up. Repositories are now DISCOVERED
  from named sources (primary, engine, the session's in-flight repo list and
  event-log cwds, a ledger, and the neighborhood of a known checkout), never
  from a typed inventory of repo names, which is the drift this repo has
  shipped five times. Worktrees come from `git worktree list`; path shape now
  decides only native vs hand-rolled.

  **The safety rule, which is the reason this is careful rather than clever:**
  a hand-rolled worktree takes no lock, so quiet is not death there. It is
  reaped only on a positive termination signal for its OWNER, taken from the
  owner's native isolation-worktree lock through the one liveness resolver.
  ALIVE, INDETERMINATE, and a name that resolves to no agent all mean leave it
  alone. **So does NOT-ALIVE when the verdict rests on the native worktree
  being ABSENT** — absence is the exact inference doctrine forbids, and it is
  refused even with every other gate open. That is also why the agent-finish
  trigger is correctness rather than throughput: the owner's native worktree,
  the only evidence a lockless tree ever has, is removed at land time, so a
  session-start-only reaper is structurally incapable of ever deciding a
  hand-rolled worktree however often it runs.

  Two smaller things the first run of the rewrite got wrong and the second
  caught, recorded because both were silent: `/private/tmp` became a "worktree
  container" after one throwaway checkout landed there, and 39 launchd sockets
  were reported as residue (a signal buried in noise is a signal ignored); and
  the ledger recorded every DISCOVERED repository, so its own `ledger` source
  promoted a neighborhood-only repository to reap-eligible on the next sweep
  and the report-only boundary evaporated after exactly one run.

  **The summary now carries its own denominator** — coverage, per-source
  counts, and a `blind:` line for every thing the run could not see.
  `reaped=1 residue=0` over one repository out of three is a false green, and
  it was one all day.

  Probe **Layer Q** grew the checks that go red when the reaper GOES BLIND
  rather than only when it is unregistered: Q1b (the agent-finish trigger
  wired exactly once on each of its two events), Q4 (a sibling repository
  found only by discovery is swept; a LIVE owner's hand-rolled tree is never
  selected; a terminated owner's merged+clean one IS, so the layer cannot be
  satisfied by a reaper that refuses everything; an unmerged one never is; the
  coverage line is present) and Q5 (the second trigger actually sweeps).
  BR2's "exactly once" became a PER-EVENT invariant with a derived expected
  total — the double-fire it guards against is one hook wired twice on the
  SAME event, and a hook legitimately wired on two events was being called a
  defect.

  A mutation test earned its keep here: deleting the "an absent isolation
  worktree is not a termination signal" branch changed nothing and all 15
  cases stayed green, because the owner table was built from a CLI that only
  ever describes worktrees that exist — so the flag that branch read was a
  constant and the branch was unreachable on the day it was written. The table
  is now built by importing the resolver and joining `names_to_ids` with
  `enumerate_all`, which makes the absence case a real row.

- **Four of the five commit/push guards were walked around by typing `cd`
  instead of `-C`** (`scripts/lib/git-jurisdiction.sh`,
  `scripts/lib/git-jurisdiction.test.sh`, and the five guards) — MINOR.

  Each guard resolved the repository it was about to judge from an explicit
  `git -C`, and failing that from the hook payload's cwd. A worktree-isolated
  agent's cwd is the checkout the harness gave it, so `cd <worktree> && git
  commit` — the way that agent types a commit — resolved the SESSION's
  repository, found no adoption declaration there, and stood down. **Measured
  2026-09-01: the identical commit was REFUSED through the `-C` form and
  ACCEPTED through the `cd` form minutes apart.**

  Enumerated rather than assumed, by reading each guard's own jurisdiction
  announcement over eight command shapes: completeness 8/8 wrong, ceo-todos
  8/8, row-currency 8/8, inflight-notify 8/8, and publication 1/8 — that one
  already tracked `cd` for a reason of its own and missed only
  `(cd X && git commit)`, where a glued paren made the segment's first token
  `(` instead of `cd`. All 40 now resolve the repository the command points at.

  Resolution moved into ONE library that all five refuse to start without,
  because it was five hand-copied blocks and four of them had the same hole.
  **The difference from the old answer is two sentences wide and both are
  pinned by cases:** a command that `cd`s into a repository is judged against
  that repository, and where one command carries several git invocations the
  anchor is the repository of the invocation being judged rather than the first
  `-C` on the line (which `guard-publication-commits.sh` had already corrected
  locally). For every single-invocation cd-free shape the answer is the legacy
  answer, byte for byte, over a 15-shape corpus. What it cannot expand — `cd
  "$D"`, `popd`, an untokenizable line — it REPORTS under a named `how` and
  falls back to today's answer rather than guessing.

- **Two teammates acknowledging one land collided on a single filename**
  (`scripts/inflight-ack.sh`, `scripts/lib/inflight.py`,
  `scripts/inflight-notify.sh`, `reference/ack-protocol-seam.md`) — MINOR.

  In-flight acks were keyed on the SHA and nothing else, so two teammates
  answering the same notice — the correct behavior — wrote two different files
  at one path and the merge was an add/add conflict. It happened twice on
  2026-09-01. **A lander in a hurry resolves that with `--ours`, and the proof
  that a teammate acknowledged a land is gone with nothing to reconstruct it
  from.** The key is now `<sha12>.<teammate>.ack`, defaulting to the worktree's
  own directory name — which the sweep already treats as one of that teammate's
  addresses — and the name is repeated inside the file.

  The reader was the other half of the same defect: it could not have reported
  two records even once the writer stopped colliding. It now returns every
  record for a tip and both renderers print all of them with whose each is.
  Pinned in the suite in both directions: the new key merges clean with both
  records intact, and the same fixture on the OLD key conflicts and loses one
  answer to `--ours`. Every ack already on main keeps verifying — attribution
  fails safe, setting a record aside only when it positively says it came from
  somebody else.

- **A red run moved the operator's engine pointer and left it moved**
  (`scripts/hooks/install.sh`, `scripts/lib/global-state-witness.sh`,
  `scripts/lib/global-state-witness.test.sh`) — MINOR.

  `~/.claude/richos-engine` — the pointer every session and the shipped app
  resolve the engine through — was found dangling at a Layer R red-run fixture
  that had been deleted after the run that made it. **Measured consequence: a
  double-clicked RichOS reported NO COMPUTE LEASE**, having attached its lease
  through that pointer an hour earlier.

  The defect was not the dangling link; it was that a test could move a global
  pointer `install.sh` owns and report success. `install.sh` now refuses to mint
  the pointer when the checkout is EPHEMERAL and the target is the operator's
  real config dir — narrow on purpose, so a suite that sandboxes
  `CLAUDE_CONFIG_DIR` is untouched and only the run that forgot is stopped, with
  `--force-engine-pointer` as the deliberate way through. Alongside it, one
  witness replaces two hand-rolled `readlink` checks that could not tell a
  DELETED pointer from an unchanged one, wired into every suite that runs the
  installer.

- **The turn gate blocked once in 107 landing turns, because anything running
  switched it off** (`scripts/hooks/guard-idle-land.py`,
  `scripts/hooks/guard-idle-land.sh`, `scripts/hooks/guard-idle-land.test.sh`,
  `scripts/hooks/idle-land.mutation.sh`, `scripts/hooks/idle-land.corpus.md`) —
  MINOR.

  `guard-idle-land.sh` shipped on 2026-08-30 refusing a turn that landed work
  and started nothing. It then watched that exact failure happen twice more on
  2026-09-01, and the CEO said it had been going on for months. **A gate that
  ships and then watches the thing it forbids happen twice is not a gate; it is
  a receipt.** Its own observation record says why, over 107 real landing turns
  on the operator's machine: `dispatched` 60, `background-running` **44**,
  `backlog-empty` 2, `block` **1**.

  Two defects, both of which made it quiet.

  **Term 4 was a blanket disarm.** It stood the whole gate down whenever
  `background_tasks` held anything running — and read out of the shipping binary
  (2.1.252), that field is `taskRegistry.all()` filtered to running|pending over
  ten task types: teammates, subagents, shells, monitors, workflows, MCP tasks,
  dreams, scans, cloud sessions. An orchestrator that keeps ten to fifteen
  teammates alive has the gate off almost whenever it matters — 12 of 20 landing
  turns in the operator's live session. The legitimate stop is far narrower than
  that suppressor was: *a teammate is running **and the next step depends on its
  result***, and dependency is already written down, in the record's own
  `Blocked by` column. So the record answers the case, the process count no
  longer votes, and what was running is REPORTED in the refusal instead. Work
  started *by this turn* still suppresses, and now includes a backgrounded tool
  call as well as an `Agent` call.

  **Term 1 read only half of "completed".** Work completes two ways: a land, and
  a teammate handing its work back. `ops` was an early return, so no turn
  without a git command could be evaluated at all. The gate now also triggers on
  the host's own `<task-notification>` — `<status>completed</status>` plus an
  `Agent "..." finished` summary, inside this turn's promptId window. A finished
  background command is not a teammate; an agent stopped by the user is not a
  delivery.

  **And the three legitimate stops now have routes**, which is the hard half. An
  `AskUserQuestion` this turn passes, read from the tool call and never from
  prose. The operator saying *he* is stopping passes — a different claim from an
  instruction to hold, and how a night actually ends. And the stop can be
  DECLARED:

  ```
  stop-declared: <case> — <why, in a full sentence>
  ```

  over a closed set of three cases (`nothing-unblocked`, `ceo-owns-it`,
  `waiting-on-teammate`), six words and thirty characters of reason minimum,
  echoed to the operator through `systemMessage` every time with "DECLARED AND
  NOT VERIFIED" attached. The header that argued for no override token was right
  about TOKENS, and that is why this is not one: a flag is free and gets typed
  reflexively, while a sentence naming which case applies and why can only be
  written by somebody who has looked. Code spans are stripped and the line must
  start a line, so quoting the refusal cannot switch the gate off.

  Measured on **1,221 real orchestrator turns** across 18 session files before it
  was trusted with `exit 2`: it fires on 25 — 2.0% of all turns, 56% of the 45
  that reach the last term. All 25 read by hand: **15 are the failure itself**,
  5 are legitimate `ceo-owns-it` stops asked in prose rather than through the
  tool, 5 are legitimate `waiting-on-teammate` stops that name the teammate in
  the reply, and **0 had no honest route through**. Full corpus, funnel and
  objection: `scripts/hooks/idle-land.corpus.md`.

  Suite 38 → 59 cases; a new 18-mutant harness proves every one load-bearing,
  and the run found three of the author's own checks that were not.

### Added

- **The Stop event's guards are now checked for ENFORCEMENT, not registration —
  probe Layer IL** (`scripts/hooks/contract-integrity-probe.sh`,
  `scripts/hooks/contract-integrity.test.sh`, `scripts/demo.sh`,
  `scripts/hooks/install.sh`) — MINOR.

  Nine hooks run on `Stop`, two of them blocking, and this probe knew all nine
  only as REGISTRATION. The idle-land gate is the proof that the two are
  different: it was registered, hashed, executable, counted in the banner and
  green on every layer for two days while refusing almost nothing.

  Layer IL is **two-sided**, over a real git repository with a real merge —
  a bad turn must be REFUSED (exit 2) and a legitimately declared stop must PASS
  (exit 0). Both halves are load-bearing, and the second is the one worth
  arguing about: this gate fails OPEN by design, so a corpse exits 0 and a
  one-sided canary would be satisfied by the exact state it shipped in.

  Four gaps had to close for the layer to be possible, and each was real on its
  own: the probe's hook extractor read `PreToolUse` only, so the Stop event was
  invisible to every functional layer; the contract-integrity sandbox wired no
  Stop hooks at all while claiming to mirror every event; **neither sandbox file
  list carried the `.py` analyzers** that five Stop wrappers take their entire
  verdict from — and `sandbox-completeness.sh` cannot see that, because a
  wrapper without its analyzer STARTS PERFECTLY; and `guard-idle-land.py` was
  unhashed, so the one file that makes every decision was the one file nobody
  verified.

  contract-integrity 112 → 123 cases.

- **A CEO item can now notice that it is already finished — `Done-check`**
  (`scripts/lib/ceo-todos.py`, `scripts/lib/ceo-todos.sh`,
  `scripts/ceo-todos-lint.sh`, `scripts/hooks/guard-ceo-todos-commits.sh`,
  `scripts/hooks/ceo-todos.mutation.sh`) — MINOR.

  On 2026-08-31 the app icon was made and landed and every CEO-facing record was
  left stale. He opened his own TODO page, searched "icon", and found the item
  still asking him to supply the artwork that already existed.

  The commit guard was green throughout and was not wrong. It checks that an
  item is well FORMED — four fields, an artefact on disk, a criterion written
  down — and "supply the artwork" stayed perfectly well-formed for every hour
  the artwork existed. **Form is not currency.** The asymmetry is the defect:
  §3 rows have been pinned to the object id of the work they describe since
  2026-08-29, so the rows nobody but the team reads were protected while the
  rows the CEO reads were not.

  An item may now carry a fifth, optional line restating its own end state in
  four verbs — `exists`, `contains`, `lacks`, `manual` — in one backticked span,
  in his own document, beside the sentence it restates. An item whose end state
  already holds is refused out of the CEO sections exactly as an unprepared one
  is; the CEO's page says, per item, whether it will close itself or whether
  nobody can check it for him.

  **There is deliberately no verb that runs a command**, which is the one thing
  the motivating item's own `Done:` line literally was. `ct_load_declaration`
  already refuses `$(` for the same reason in its own words — this file is
  parsed, never sourced — and a verb that executed a string out of a wiki page
  would run N programs from every governed commit, wedge the repository on one
  hang, and make the verdict machine-dependent. The stated cost: an item
  observable only by running something must name the file that something leaves
  behind, which in the motivating case was strictly better — the generator's
  "prints OK and exits 0" was checkable only while somebody ran it, while the
  artefacts it wrote were on disk the whole time.

  Five outcomes, four audible. SATISFIED blocks; OPEN is silent; MANUAL is
  silent, counted and named; SKIP names a root that is not on this machine;
  BROKEN blocks. **A check that errors is never allowed to read as "not done
  yet"** — a missing subject, an unparseable expression, an invalid pattern and
  a regex that does not finish inside a 5-second bound all refuse rather than
  report an item as correctly waiting.

  Every verdict now carries a `DC` census line, clean ones included, because the
  correct outcome for an unautomatable item is SILENCE and silence is also what
  an evaluator that never ran produces.

  `DONE_CHECK_REQUIRED` (new `.ceo-todos` key) defaults to `0` on purpose:
  shipping this as a requirement would have refused the next commit in every
  repository that already had a record. Items with no check are named in a NOTE
  on every verdict instead, and an owner turns the notice into a refusal with a
  one-line diff. An item that carries no check renders byte-identically, so no
  adopter's committed view goes stale on this upgrade — verified against a real
  record, whose view hashes the same before and after.

  Also closed: an unrecognized `- **Key:**` line inside an item was silently
  ignored, so a mistyped `- **Done-Check:**` would have switched an item's check
  off under a green verdict. It is now `UNKNOWN-FIELD`.

  32 new cases (97 total in `ceo-todos.test.sh`) and a 12-mutant harness that
  proves each property load-bearing by removing it.

- **The in-flight sweep — a land that leaves a teammate behind is refused, and
  the acknowledgement is a file rather than a hope**
  (`scripts/hooks/notice-inflight-sends.sh`,
  `scripts/hooks/guard-inflight-notify.sh`,
  `scripts/hooks/notice-inflight-acks.sh`,
  `scripts/lib/inflight.{sh,py}`, `scripts/inflight-notify.sh`,
  `scripts/inflight-ack.sh`, `verify-agent-prompt.sh` check 6) — MINOR.

  Landing moves `main`. Every teammate still working was cut from an older base
  and is now, silently, one revision behind. Nothing tells them; the lander is
  the only thing that can. Twice on 2026-08-30 the lander did not — an
  eight-hunk conflict across five files, and a library that shipped at 7 of 19,
  two extra agents between them. `rich-lander/SKILL.md` gained §8b the same day,
  and §8b is a paragraph. A paragraph is a promise.

  The two halves are different problems and are treated differently, which is
  the whole design rather than a caveat:

  **The SEND is enforced.** `notice-inflight-sends.sh` is a
  PostToolUse[SendMessage] hook — the exact mirror of `worker-updated-handoff.sh`,
  same field, opposite branch of the attribution gate — that records every
  message the LEAD sends, with the recipient and every hex SHA in the body (the
  body itself is never logged). It observes the SEND inside the lead's own tool
  call, so the record is true even when the ~50%-lossy mailbox drops the
  message, and the only way to produce the record is to actually send. At `git
  push origin main`, `guard-inflight-notify.sh` sweeps every live worktree and
  REFUSES the push while any of them is behind with no witnessed notice naming
  this tip — naming the teammate, its base, and what moved.

  **The ACK is surfaced, not enforced,** and it deliberately cannot block: at
  push time the message is seconds old. The teammate answers with an artifact in
  its own worktree (`scripts/inflight-ack.sh`), because a reply the lead may
  never receive proves nothing to the lead — the same reasoning that makes the
  commit, not the mailbox, the handoff. `notice-inflight-acks.sh` reports a
  missing ack at the end of every turn once 30 minutes have passed (measured:
  22 worker run segments, p50 40m, p90 71m — see `INFLIGHT_ACK_TIMEOUT_MIN`).
  Nothing is ever killed on a timer.

  **What no machine here checks, said in the guard rather than left to be
  found:** the ack's `detail` line is checked for length and for citing paths
  that really exist; whether it is CORRECT is comprehension, and a string match
  is not comprehension. The verifier prints it under HUMAN JUDGMENT REQUIRED.

  Chokepoint chosen on evidence: `git merge` was rejected because the SHA a
  notice must name does not exist yet at merge time, so a guard there could only
  enforce the PREVIOUS land's debt. `git push` is once per land, after the
  commit exists, and is the orchestrator's exclusive act. The stated gap — a
  land that merges and never pushes — is covered by the Stop-hook notice.

  The escape hatch is a command, not a token:
  `scripts/inflight-notify.sh waive <worktree> --reason "<why>"`, recorded with
  the tip, the worktree, the reason and the actor, and loud when what is being
  waived overlaps files the teammate has also changed.

  42 cases in `scripts/hooks/inflight-notify.test.sh`, including a POSITIVE
  PROBE so "silent no-op" cannot be indistinguishable from "never ran"; 12
  mutants killed in `scripts/hooks/inflight-notify.mutation.sh`. Three mutants
  survived the first run and each one bought a case the suite did not have.

- **Mid-session hook staleness — a landed guard says so, and says restarting is
  yours to do** (`scripts/hooks/snapshot-enforcing-hooks.sh`,
  `scripts/hooks/notice-hook-staleness.sh`,
  `registered_hook_rows()` in `scripts/lib/registered-hooks.sh`) — MINOR.

  Six guards were landed in one day. The lander knew they were inert until the
  session restarted and said so, in the form *"they arm at next session start"*.
  That sentence names a date. It names no actor and no action. The operator read
  it as something that would happen **to** him rather than something he could do,
  in five seconds, at any moment — nobody ever told him restarting was an
  available move. He was then hit by a failure three of those six guards would
  have caught.

  Nothing was wrong with the guards, and the sentence was not even false. The
  defect was that a deferred activation had been reported as a **forecast**
  instead of a **request**, so nobody acted on it. That generalizes well past
  hooks, so it is stated to generalize:

  > **A deferred activation must name the actor and the action.** Never "this
  > arms at the next session" — always "restart the session to arm this; that is
  > the operator's to do." A state change that requires a human action is not a
  > date, it is a request.

  The pair mirrors the definition-drift pair exactly, because it is the same
  problem one object over: something the host loads ONCE at session start, with
  no baseline against which anyone could prove it had gone stale.
  `snapshot-enforcing-hooks.sh` records the registrations this session actually
  booted with; `notice-hook-staleness.sh` re-derives them at the end of a turn
  and, when they differ, tells the **operator** — naming the inert guards,
  saying they are enforcing nothing right now, and saying that restarting arms
  them and that this is his to do. A notice that reported drift without naming
  the remedy would have rebuilt the original failure in a new place.

  Four decisions, each made against a real alternative and each settled by
  measurement rather than by argument:

  1. **Only the plugin surface is compared, and that was measured.** Probed
     against the shipping binary, each run gated on a negative control that had
     to fire first: a hook added mid-session to a loaded plugin's
     `hooks/hooks.json` **never fired** (control: a hook already in that table
     fired three times in the same run), while a hook appended mid-session to
     `.claude/settings.local.json` **fired on the very next tool call**. So the
     obvious "check both surfaces for completeness" would have produced a
     confident, well-formatted false positive on every settings edit. Guard
     script BODIES are excluded for the same reason: a registration names
     `bash <path>`, re-executed per event, so a body edit is live immediately.
     Only the registration is frozen, so only the registration is compared.
  2. **Stop, and `systemMessage`, because that is the channel that reaches the
     party who can act.** A Stop hook exiting 0 with `{"systemMessage": ...}`
     surfaces live as `{"type":"system","content":"Stop says: ..."}`;
     `additionalContext` and stderr reach only the model, which is precisely the
     party that **cannot** restart a session. Announcing this at the next session
     start instead would be a status line about a problem that had already
     solved itself.
  3. **Once per session, again only if the delta grows.** A notice on every turn
     is noise, noise gets muted, and a muted notice is worse than none.
  4. **It never blocks.** A stale hook set is not a reason to refuse work; it is
     a reason to tell the operator to restart.

  Zero false positives is structural here rather than hoped for: both sides are
  derived from the same file by the same parser, so there is no threshold and
  nothing to tune — a design for this that needed a threshold had taken a wrong
  branch. A session in which the table did not change prints **nothing at all**,
  and that is a test rather than a claim. Separately, a green run must prove it
  read something: the baseline's `rows=` must agree with the rows parsed out of
  it and be non-zero, the current derivation must be non-zero, and the engine
  paths must match — otherwise the hook says it **cannot check** instead of
  passing quietly. This operation has already shipped one scanner that reported
  CLEAN over an empty corpus and one reporting layer that was dead for weeks;
  that control is there so there is not a third.

  **This mechanism is itself inert in the session that lands it**, and pretending
  otherwise is the one joke it cannot afford to play straight. It is a hook. To
  arm it: re-run `scripts/hooks/install.sh`, then **restart the session** — the
  actor is the operator and the action is the restart, which is the whole rule
  above, applied to itself.
- **A land that starts nothing no longer ends the turn**
  (`scripts/hooks/guard-idle-land.{sh,py}`) — MINOR, and inert in any
  repository that does not carry the orchestrator's record beside a
  `.ceo-todos` declaration.

  The orchestrator's working record opens by stating its own rule: **a land
  ends by starting the top unblocked item, then reports** — the only permitted
  stop being an item whose next action needs a decision only the CEO can make.
  The orchestrator wrote that rule, then landed four branches across two
  repositories, wrote a long report, and ended the turn with an empty dispatch
  queue and seven unblocked rows still in the file. The CEO had to ask why
  everything had stopped, for the seventh time in two days.

  Every previous answer to that question had been a document — which is this
  engine's own cataloged defect, stated a dozen times in a week: **a rule
  enforced by attention lasts exactly as long as the attention.** So the answer
  is a chokepoint. `Stop` is the chokepoint, and the turn gate that landed
  hours earlier had already established against the shipping binary that a Stop
  hook can block and what its payload carries.

  Four terms, all four required, none of them read from prose the orchestrator
  wrote:

  1. **This turn landed.** A `git merge` or `git push` in the turn's own tool
     traffic, whose EFFECT is then confirmed by identity — the merged tip is an
     ancestor of `HEAD`, or `HEAD` equals the branch's remote-tracking ref. A
     merge that conflicted and was aborted fails both. The freshness contract's
     own rule, identity or refuse, pointed at an action instead of an artifact.
  2. **Nothing was started.** No `Agent` call this turn, scoped to `promptId`.
  3. **There is something to start.** An unblocked row **derived** from the
     record's `## Next` table. Struck rows and rows whose blocker cell is
     anything unrecognized are blocked; `"<x> free after 1-2"` resolves its
     references against the same table. Never a typed count.
  4. **Nothing is still running.** `background_tasks` from the payload.
     Landing while four agents work is not idling.

  A missing, unreadable, unparsable or ambiguous record makes the gate **inert
  and loud**, never a guess about what is left to do. There is **no live
  override token**: the escape is to move the row into the CEO's record, a
  committed, diffable act — which is also why the gate is inert unless
  `.ceo-todos` declares that record exists. A refusal with nowhere to send the
  row is a refusal people unwire.

  Measured over **1,082 real orchestrator turns across six sessions** before it
  was trusted: 305 turns ran a merge or push, 276 were confirmed by identity,
  **29 ran the command and the repository did not agree**. Of the 276, 95
  dispatched in the same turn, 101 still had an agent running, 0 were held, and
  **80 landed and started nothing (29%)**. Fourteen were read by hand: the
  mechanical terms were correct in all fourteen and **zero** fires came from the
  gate misreading ground truth. It ships blocking at that rate because the cost
  is bounded at one extra turn — `stop_hook_active` stands the gate down on its
  own re-fire, so it can refuse a given turn at most once.
  `IDLE_LAND_ENFORCE=0` runs it report-only.

  Like every hook here it takes effect in the NEXT session, and `install.sh`
  must be re-run after the merge to mint its `.sha256` sidecar.

- **Row currency — the working record stops going stale by itself**
  (`scripts/lib/row-currency.{sh,py}`,
  `scripts/hooks/guard-row-currency-commits.sh`,
  `scripts/row-currency-lint.sh`, `reference/row-currency/`) — MINOR, and inert
  without a `.row-currency` declaration.

  The CEO-TODOs contract made the CEO's own two sections honest: an item may not
  claim to be waiting on him unless the thing he opens exists. It left the
  WORKING section — the one the team lives in — enforced by nobody. On
  2026-08-29 four rows of that section described work as unbuilt, pending or
  open, **hours after it had landed, in a single day**. Every one was caught by
  a person reading the file, because a person reading the file was the only
  detector that existed.

  The cause was never carelessness. Updating a row is a manual step that comes
  after the merge, and a rule enforced by attention lasts exactly as long as the
  attention.

  > A row that describes open work states the identity of the work it describes.
  > When that identity changes and the row does not, the next landing is refused
  > until somebody rewrites the row.

  Each governed row's last cell carries a **warrant**: a status token and every
  path that row describes pinned to the object id it had when the row was
  written — `` **State:** `OPEN` — `<repo>/src/parser.rs`@`0a1b2c3d4e5f` ``. The
  guard recomputes those ids from the tree the landing is about to create
  (`merge-tree --write-tree` for a merge, a copy of the index for a commit) and
  refuses by item id, printing the warrant to paste. Content identity, never a
  timestamp: it survives a rebase and needs no clocks to agree.

  Five decisions worth stating, because each was made against an alternative:

  1. **`git merge` is gated, which the CEO-TODOs guard deliberately does not
     do.** All four rows rotted at a merge. A guard on `git commit` alone would
     have watched every one of them go past.
  2. **Only at a landing** — main checkout, attached HEAD. An engineer's branch
     is a proposal and has changed nothing the record describes. A guard that
     fired on every branch commit would be switched off inside a day.
  3. **Cross-repository, because no commit can touch two repositories.** The
     work repository carries a one-key peer declaration naming the record's; the
     two are drift-checked against each other; and a record repository that is
     not on the machine stands the guard down **loudly and blocks nothing**, so
     a published repository cloned without its private sibling still works.
  4. **No re-stamp command, ever.** A tool that refreshed the pin would let the
     obligation be discharged with nobody reading the sentence beside it, which
     is the original defect wearing a fix's clothes.
  5. **No live override**, for the publication boundary's reason with more
     force: what failed was in-the-moment judgment by the lander at the moment
     of the land, which is exactly when an escape token gets reached for. The
     way through is deleting the declaration in a committed diff.

  A second, narrower check refuses a commit or merge whose message NAMES an item
  whose row did not change. Its precision rules were built by sweeping 800 real
  commit messages and reading every hit: a blocklist of excluding words was
  written first, claimed an id in 36 of 400 messages, and was mostly wrong —
  `P1.4` (a phase), `bash 3.2` (a version), `nemotron-3.5` (a model),
  `+1.2 points` (arithmetic), `Stages 3.5, 3.6 and 3.7` (pipeline stages, plural
  and comma-separated). It was replaced with an **allowlist** of the words that
  name an item, because the set of words that can precede a decimal number is
  unbounded and the set of ways a team names an item is not. `--explain` prints
  the reasoning candidate by candidate.

- **The CEO TODOs, part two: REACHABLE, and READ FROM OUTSIDE**
  (`scripts/ceo-todos-render.sh`, `scripts/ceo-todos-init.sh`,
  `scripts/cold-open.sh`, `scripts/lib/cold-open-prompt.md`,
  `reference/ceo-todos/`) — MINOR, still inert without a `.ceo-todos`.

  The first release of the CEO TODOs enforced that every item waiting on the
  CEO was PREPARED, and shipped with nowhere for him to look: the items lived
  inside a long record mixed with everything else, and the only new artifact was
  a dotfile. The report read *"the contract is live, 9 prepared items"* — true
  of the record, false of his experience. The reason the other half fell out
  silently is the general case and the reason this release exists: **every
  acceptance criterion in that landing was internal.** Lint exit codes, guard
  tests, probe layers, git state. A view has no exit code, so it had no test
  that could fail, so it was never in scope and nothing said so.

  Three things now have exit codes that did not:

  1. **One entry point, enforced.** `TODO_VIEW` is a bare top-level, un-dotted
     file name, generated from the record by `ceo-todos-render.sh` and refused
     at commit unless it is byte-identical to what the record renders to,
     singular (no second file carrying the generated marker), and named in the
     first 40 lines of `ROOT_README`. The renderer moved INTO the engine and
     shares the predicate's single parse: the previous repo-local generator was
     a second parser of the same file, the gate would have had to trust code
     supplied by the repository it was checking, and — worst — adopters received
     the enforcement without the page.
  2. **The cold open.** `cold-open.sh` puts the CEO-facing surface in front of a
     reader with **no context by construction** — a fresh, customization-free
     process, or a person via `--record` — and files a transcript stamped with a
     fingerprint of the front door it describes. Change the front door and the
     next commit is refused until somebody reads the new one: the freshness
     contract, identity-or-refuse, applied to a judgment. **The gate enforces
     that the reading happened and never what it concluded** — a gate that
     demanded a favourable verdict would get one every time, and the finding is
     the entire product. Undeclared `COLD_OPEN_DIR` never blocks and is printed
     as an unchecked limit on every clean verdict.
  3. **An adopter actually gets one.** `ceo-todos-init.sh` plus
     `reference/ceo-todos/` install the declaration, a starter record, the
     entry point and the README pointer in one command, and the onboarding
     runbook and bootstrap interview name it. For one release the engine shipped
     the lint, the guard, the predicate and the test suite with **no
     declaration, no template and no mention anywhere in the adoption path** —
     so every adopter received enforcement that could never fire, and nothing
     told them. That is the same defect the mechanism exists to catch, one level
     out, and it shipped because the landing criterion was "the files are in the
     tree".

  Also added, from the first real cold reading: a `NOTE` when a prepared
  artifact exists locally but is git-ignored (correct for private preparation —
  and the link is dead in a fresh clone and on the web view), and an explicit
  "in the separate `<x>` repository, not this one" marker on items whose
  declared root is a sibling. Both were things a green lint could not see and a
  stranger noticed in ninety seconds.

- **The CEO TODOs** (`scripts/lib/ceo-todos.sh`, `scripts/lib/ceo-todos.py`,
  `scripts/ceo-todos-lint.sh`, `scripts/hooks/guard-ceo-todos-commits.sh`) —
  MINOR: purely additive, and inert in any repository that does not declare a
  `.ceo-todos`. Makes "waiting on the CEO" a **checkable claim** instead of an
  unfalsifiable one.

  The engine's orchestrator writes long, exact briefs for every teammate —
  paths, commands, constraints, a completion criterion. When the executor is
  the CEO the brief collapses to one sentence, so the most expensive executor
  in the system gets the worst brief. Worse, a record can say an item is
  waiting on him while the thing he is supposed to touch has never been
  prepared and does not exist; that claim reads exactly like a real one, so it
  sits for weeks looking blocked on him while it is blocked on unfinished
  preparation. One real item read, in full: *a real recorded call, a length,
  and a verified transcript* — a description of a desired state, with no file
  behind it, waiting on material that was never going to arrive.

  **AN ITEM MAY NOT CLAIM TO BE WAITING ON THE CEO UNLESS THE THING HE TOUCHES
  ALREADY EXISTS ON DISK.** Every item in a declared CEO section must carry
  four fields — the exact artifact path, the time cost, what *done* looks like,
  and what it unblocks — and the artifact is `stat`ed. Two states: `READY-FOR-CEO`
  (prepared) and `BLOCKED-ON-RICH` (unprepared, and therefore in the preparer's
  own section). Moving an item to `BLOCKED-ON-RICH` is the mechanism working;
  the CEO sections are worth something only while "waiting on the CEO" is a
  promise that everything else is done.

  Enforced at `git commit`, not at `Write`: the dominant way a markdown record
  changes here is the Bash tool, so a write-matcher guard would miss most real
  edits while reporting a clean session — the same shape as the "18/18 suites"
  defect, and the same discovery `guard-publication-writes.sh` records from the
  other direction. It fires on EVERY commit in a declaring repository, not only
  ones that touch the record, because the original failure was a bad row
  *sitting* there rather than a bad row being written; the refusal says whether
  this commit introduced the problem or ran into a pre-existing one.

  Scope is declared **by the repository that owns the record**, exactly as
  `.publication-boundary` declares the publication split — so a governed
  session committing into a repository that has NOT adopted the engine is fully
  covered. Artifact roots resolve against that repository's MAIN checkout
  (`scripts/lib/resolve-main-checkout.sh`), because a linked worktree contains
  no gitignored files and a private artifact prepared for the CEO is very often
  gitignored. A declared root that is not on this machine makes its artifacts
  UNCHECKABLE: skipped, and NAMED in every verdict, never blocked and never
  invisible. No silent degradation anywhere — a missing declared section, a
  CEO section reverted to a markdown table, an absent record and a malformed
  declaration each BLOCK; the CLI gives an absent record its own exit code (3)
  so "nothing to check" can never be read as "clean". `ceo-todos.test.sh`
  proves the predicate on fixtures alone (the real record lives in a private
  repository CI cannot see), including the original failing item replayed in
  both its shapes and its prepared replacement passing.

- **Worker lifecycle event stream** (`worker-created-handoff.sh`,
  `worker-started-handoff.sh`, `worker-updated-handoff.sh`,
  `worker-ended-handoff.sh` → `worker-events.jsonl`) — MINOR: purely additive
  log-only hooks; an adopter who ignores the new file experiences no change.
  The engine emitted only *completed* and *idle*, so a worker's CREATION was
  observed at `PreToolUse[Agent]` and thrown away into a plain-text name
  ledger. No consumer could answer "how many workers are running" from a
  signal, only from a guess — which is why the desktop app's `worker_status.rs`
  reports `active: 0` structurally rather than guess. These four emitters
  supply **created** (`PostToolUse[Agent]`, gated on the harness's async-launch
  acknowledgement so a synchronous Agent run — whose PostToolUse fires when the
  work is already over — never becomes a live worker), **started**
  (`SubagentStart`), **updated** (`PostToolUse[SendMessage]`, only when the
  payload's `agent_id` proves a worker sent it) and **run_ended**
  (`SubagentStop`). All four are sourced from PostToolUse or from events that
  only fire inside a running worker, so a BLOCKED spawn produces silence rather
  than a phantom active worker, and an event with no `agent_id` produces no
  line rather than an anonymous one. Deliberately NOT emitted, with the reason
  written down: **waiting** (idle cannot distinguish "paused for input" from
  "finished"), **interrupted** (a shutdown request is an instruction, not an
  observation) and **failed** (no payload carries an outcome) — see
  `docs/worker-lifecycle-events.md` for the full per-state table and the honest
  active-count derivation. Message bodies, spawn prompts and assistant text
  never enter the log. `spawned-names.log` and `guard-worktree-isolation.sh`
  are untouched; `worker-lifecycle.test.sh` re-proves name-reuse blocking and
  the blocked-spawn silence with paired positive controls.

- **`CLAUDE.md` provisioning** (`scripts/provision-claude-md.sh` +
  `identity.config.example`) — MINOR by `VERSIONING.md`'s test: purely
  additive, and an adopter who ignores it experiences no change. The engine
  ships `CLAUDE.md.template`, but Claude Code only auto-loads `CLAUDE.md`, so
  until now a **bare boot came up as generic Claude** and the Rich persona was
  established only by the RichOS app's re-prime path. The provisioner renders
  the template into a real `CLAUDE.md` using the CEO actuals in
  `identity.config`: it injects a "Who you work for" section (CEO, company,
  product, and a pointer to loro's context compiler), strips the adopter-facing
  header, and replaces every `<!-- TODO (adopter) -->` block with either the
  configured value or an explicit *"not configured — ask the CEO, never invent
  a value"* note, so adopter instructions and the sample "No pagination" rule
  can never be mistaken for live doctrine. Idempotent and no-clobber via a
  provenance stamp carrying the engine version plus template/values/body
  sha256s: unchanged inputs are a no-op, changed inputs refresh an unedited
  file, and a CEO-edited file is never overwritten (`--upgrade` writes
  `CLAUDE.md.new` beside it so `UPGRADING.md`'s hand-apply step is mechanical;
  `--force` is the only way past it). `--check` gives installers a gate,
  `--identity-json` gives other components one source of truth for
  `company_name`. 28 tests in `scripts/provision-claude-md.test.sh`.

- `gpt-exporter` (`engine/tools/gpt-exporter`, now v2.2.0): a popup checkbox,
  `Include above "Branched from" content`, positioned above the "JSON
  Backup" checkbox and unchecked by default. Unchecked (default), the
  markdown export of a branched ChatGPT conversation drops everything before
  the `---\n\nBranched from [[...]]\n\n---\n\n` divider, leaving frontmatter
  + the `# <title>` heading + the divider + the post-branch content — the
  same shape as the CEO's own manual trims. Checked
  reproduces today's full export byte-for-byte. Non-branched conversations
  and the JSON Backup output are unaffected either way. See
  `export/markdown.js`'s `conversationToMarkdown(conversation, options)` and
  the fixture test in `export/__tests__/branch-trim.test.mjs`.
- Vendored two marketing-surface skills, `landing-page-taste` and
  `landing-page-redesign`, from `taste-skill` @ `72e29953` (MIT), each
  scope-pinned to marketing surfaces only — never product UI. See
  `engine/skills/README.md`.
- **`scripts/ci-verify.sh` — the engine's full self-verification as ONE
  command**, and the single place CI's steps are written down: preconditions
  (tool versions + a git identity), `bash -n` on every shipped script, every
  suite via `run-all-tests.sh`, `install.sh`, the integrity probe, and
  `demo.sh` asserting 7/7 beats. Both GitHub Actions workflows — the adopter
  template under `.github/` and this repository's own root-level copy — are now
  thin callers of it, because two YAML files each spelling out the same six
  steps is a typed inventory in a different costume. Runnable by hand, so
  "what does CI do?" has an answer you can execute before you push.

### Changed

- **"The CEO queue" is now "the CEO's TODOs" — and the old name still works.**
  The CEO's instruction, and his reason: the target audience is non-technical
  CEOs based in the **US**, and *queue* is the British word for it. The rename
  is total — `.ceo-todos`, `TODO_RECORD`, `TODO_VIEW`, `CEO-TODOs.md`,
  `scripts/ceo-todos-{lint,render,init}.sh`, `scripts/lib/ceo-todos.{sh,py}`,
  `scripts/hooks/guard-ceo-todos-commits.sh`, `reference/ceo-todos/`, and the
  rendered heading a CEO actually reads (**"Your TODOs"**). The word *queue* is
  untouched everywhere it means something else: a Railway build queue, a Resend
  import status, the lander's next queued handoff, the app's audio queues.

  **The compatibility decision, because it is the whole story.** `.ceo-queue`
  was strict-parsed, so a clean cut would make the new engine find no
  declaration in an un-migrated repository, **stand down, and say nothing.** A
  guard that switches itself off silently is the failure class this mechanism
  exists to remove, so it is not an acceptable way to ship its own rename — and
  "no release ever carried `.ceo-queue`" is not a defense, because adopters
  install from `main` and at least one live repository already declares it.

  So: the legacy declaration and the legacy keys are **still read and still
  enforced**, and every verdict — including a CLEAN one, and including the
  commit guard's — prints `LEGACY-DECLARATION-NAME` / `LEGACY-DECLARATION-KEYS`
  with the exact rename command. Carrying **both** declarations is `BROKEN` and
  blocks; the engine never picks one quietly. `ceo-todos-init.sh` refuses beside
  a legacy declaration, because a rename is not a re-install.

  What the alias cannot fix, stated rather than discovered: **old engine + new
  `.ceo-todos`** still stands down silently, because that code has shipped. The
  land order in [`UPGRADING.md`](./UPGRADING.md) is the only fix — engine first,
  record repository second — and the alias makes the window between them safe
  rather than merely short. Migration steps are in `UPGRADING.md`.

### Fixed

- **The publication boundary examined zero bytes for a whole class of commits**
  (`scripts/hooks/guard-publication-commits.sh`,
  `scripts/lib/publication-boundary.py`) — PATCH, and the two holes were found
  while building on top of the guard rather than by testing it.

  The commit guard runs BEFORE the command it inspects, and it read only the
  index. So `git add <dir> && git commit`, `git add -A && git commit` and
  `cd repo; git add . ; git commit` all found an empty index at check time and
  exited 0 — a whole new directory of transcripts, committed in one go, was
  waved through. `git commit -m x <path>` and `git commit -a` were worse than
  missed: they record the WORKING TREE copy of a file, and the guard read
  `git show :path`, scanning the bytes being replaced rather than the bytes
  being recorded. The staged set is now derived from what the COMMAND will do —
  every `git add` in the same command, before the commit, in THIS repository,
  plus pathspecs given to `git commit` itself — enumerated with
  `git status --porcelain -z --untracked-files=all`, where `-uall` is the whole
  fix for the directory: without it git reports a wholly-new directory as ONE
  entry with no bytes behind it. Index bytes and worktree bytes are now
  materialized separately, because they are not the same bytes.

  One level down, the shared predicate had the same walk-past for every caller:
  an item whose path was a DIRECTORY raised `IsADirectoryError` inside the
  unreadable-path branch and came back CLEAN. Directory items are expanded to
  their files, binary skipped by NUL test, and overflowing the bound is BROKEN
  rather than a quiet truncation.

  Two smaller things fell out. The repository being committed to was taken from
  the FIRST `-C` in the command line, so `git -C /other add -A && git -C /here
  commit` judged `/other`; it is now the commit's own `-C`. And `git status -z`
  output was being stored in a shell variable on the way to its parser, where
  bash silently drops every NUL and all the paths concatenate into one string
  that matches no file — the same class as the NUL-by-byte-count test three
  lines below it.

- **The corpus could not see a recording whose only rendering was plain text**
  (`scripts/lib/publication-boundary.py`) — PATCH, and it was a live leak, not a
  theoretical one.

  A 6,000-character extract of a real private podcast transcript was written
  into the publication-bound repository and BOTH guards returned exit 0 in
  silence. The commit guard — the backstop that exists precisely to catch what
  the write hook misses — runs the same predicate and missed it identically, so
  neither arm held.

  The corpus had two ways in and both are extensions of ONE seed. The shape
  filter takes a file that looks like a recording; the closure takes another
  RENDERING of something already taken. whisper's plain `.txt` output has no
  timestamps and no speaker labels, so it has zero transcript-shaped lines and
  the shape filter rejects it — and the closure can only EXTEND a seed, never
  create one. A recording transcribed straight to plain text, with no
  timestamped rendering anywhere, was therefore invisible to the corpus whole.
  Three podcast transcripts of two named third-party guests — 5,713, 6,424 and
  22,375 words — sat inside the declared `PRIVATE_SOURCES` while the corpus held
  ten files, every one a rendering of the same webinar.

  The fix is provenance rather than content, because there is no reliable
  content shape for plain whisper output and every content-side widening was
  already rejected with numbers. The tree knows what the bytes do not: the
  transcript sits next to the recording it came from, under a name derived from
  it. A text file whose stem extends the stem of a media file in the same
  private directory now seeds the corpus. Measured across 5,353 tracked text
  files in eleven repositories: admits exactly the three transcripts, after
  which the closure takes a fourth on its own merits (a worksheet 80.9% covered
  by them, 763 of 943 windows); corpus 10 files / 83,793 words -> 14 / 130,466;
  costs ONE new colliding phrase in all eleven trees — a single 10-word run, 8
  of its 10 words function words, at the `MIN_QUOTE_WORDS` floor, in four files
  in a repository that declares no boundary — and ZERO in the publication-bound
  repository, before and after. The wider rule ("any text file in a directory
  holding media") reaches the same corpus by admitting a 51 KB mixed worksheet
  directly on a coincidence of directory; admitting mixed documents on weak
  evidence is what once blocked LICENSE files, so the narrow rule ships.

- **A scan that read nothing reported CLEAN**
  (`scripts/lib/publication-boundary.py`, `scripts/lib/publication-boundary.sh`,
  both guards) — PATCH.

  Everything after the corpus is conditional on the corpus: empty corpus, empty
  index, `verbatim_run` returns `None`, verdict CLEAN. A guard announcing it
  found no private material when it never had any to compare against — the "no
  media committed" check wearing a different hat. It had already happened once,
  silently: `../richos-hq` resolved inside a linked worktree to a path that does
  not exist, and the only symptom was one honest line in a message nobody reads
  on a PASS.

  Declared sources that resolve to trees that exist but yield no corpus member
  are now BROKEN, named, with the way through stated. NOT a size threshold —
  "unexpectedly small" cannot be derived from anything, and a magic number
  either never fires or fires on a legitimate small private record. The
  sanctioned way through is `CORPUS_MAY_BE_EMPTY` in the declaration, committed
  and diffable like `ALLOWLIST` and never an in-the-moment override. Note the
  scope honestly: this would NOT have caught the leak above, whose corpus held
  83,793 words. Vacuity and coverage are two different failures.

  The scanner also now ends every completed analysis with
  `CORPUS <TAB> files <TAB> words`, so a CLEAN can be told apart from a
  CLEAN-because-nothing-was-read from the outside. It is the negative control
  for the test suite itself: a regression test for a scanner can pass for the
  very reason the scanner failed.

- **The derived-from-private corpus was one recording deep**
  (`scripts/lib/publication-boundary.py`) — PATCH.

  Measured on the real private record: 481 candidate text files, of which the
  shape filter kept TWO, while seven more two-channel transcripts of real
  recordings sat in the same tree carrying no timestamps and no speaker labels —
  whisper's plain `.txt` output has neither. The verbatim-quote detector, the
  half that catches speech quoted inside ordinary prose, was matching against
  26,339 words. A private file now also joins the corpus when it reproduces
  corpus speech IN BULK — at least 400 distinct runs AND at least 8% of its own
  — which admits another rendering of a recording and refuses a document that
  merely quotes one. Corpus 2 files / 26,339 words -> 10 / 83,793.

  The threshold is where it is because the alternatives were measured. Admitting
  any file that shares ONE run pulled 251 private engineering documents in and
  blocked 206 of 5,333 public files, LICENSE and `.gitignore` among them; a
  40-word inbound run admitted one mixed brief whose header line and a scratchpad
  PATH then blocked five legitimate public files. Under the shipped rule the
  false-positive count across those same 5,333 files is unchanged from the
  narrow corpus, and zero in the publication-bound repository itself. The
  widening that would catch the CEO's typed words quoted nowhere else — harvest
  every quoted run from every private file — blocks 98 public files including
  this engine's own README and WALKTHROUGH; it is rejected, and the gap it
  leaves is now named in `publication-boundary.sh`'s "what this cannot catch".

- **Probe layer BR7 walked up from the POINTER, not the checkout.** When the
  engine is loaded by reference its root is normally a symlink
  (`~/.claude/richos-engine` → the checkout), and BR7 climbed from the link
  path — `~/.claude`, then `~`, then `/` — never reaching the repository that
  carries `.claude-plugin/marketplace.json`. The manifest was present, committed
  and correct, and the layer whose whole job is proving a fresh clone can
  register this engine reported it missing on the machine where the engine loads
  fine. BR6b resolves the same pointer two layers below; BR7 now does too.

- **The engine's self-verification CI had never executed once.** GitHub Actions
  discovers workflows ONLY in a repository-ROOT `.github/workflows/`; the
  engine's only copy sat under `engine/`, correct as an adopter template and
  completely inert in the engine's own repository. `gh run list` returned
  nothing at all. Not broken — unreachable, and silent about it, while two test
  suites sat red on `main` for a day. A root-level workflow now runs everything
  on every push/PR. **This is the enforcement that would have caught every other
  defect fixed on 2026-08-29**, each of which had the same shape: a correct rule
  with nothing enforcing it.
- **`contract-integrity-probe.sh` reported two hard gates as NOT WIRED on any
  bash >= 4** (i.e. on every Linux host). The array holding the wired
  PreToolUse[Bash] commands was named `BASH_CMDS` — bash's own **reserved
  associative** command-hash table since 4.0. `BASH_CMDS=()` does not make it
  indexed, so every appended element read back as the empty string, and Layers
  **O** (Bash main-write guard) and **S** (worktree-removal guard) failed on
  checkouts where both guards were correctly wired. Invisible on macOS, which
  ships bash 3.2 and has no such variable. Renamed to `BASH_MATCHER_CMDS`.
  Fail-closed throughout — nothing was ever let through — but a gate that cries
  wolf on every Linux adopter is a gate people learn to ignore.
- **`mktemp -t <template-with-no-Xs>` hard-fails on GNU coreutils** (`too few
  X's in template`) while BSD/macOS accepts it and appends its own suffix. Five
  such call sites, all converted to the explicit
  `mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"` form. One of them was in
  **`scripts/hooks/guard-workflow-ban.sh` — shipped enforcement code, not a
  test** — whose self-test and unadopted-repo path were broken on every Linux
  host; the other four broke 15 assertions across
  `scan-secrets.test.sh` and `detect-nonnative-worktree.test.sh`. The pre-CI
  portability audit had examined this exact divergence and classified it
  "cosmetic, non-breaking"; it had only looked at templates that contained X's.
- **`docs/ci-portability-notes.md` was an audit presented as a result.** It now
  leads with what the first real Linux execution found, records the three
  defects the read-through missed, and names the one layer set CI honestly
  cannot cover (the by-reference layers BR1-BR10, which need an operator's
  user-scope `~/.claude` plugin registration and are covered instead by
  `scripts/hooks/by-reference.test.sh`).

## [1.0.0] — 2026-08-20 — the fork

The RichOS engine begins here, forked from the standalone orchestration product
at its `v1.0.0` and vendored into the RichOS repository as `engine/`. Version
`1.0.0` is carried forward deliberately: the fork point is the upstream
`1.0.0` tree, byte for byte, so an adopter comparing the two starts from a known
identity rather than a guess.

### Added

Everything the engine ships today arrived in this fork — the mechanical hook
layer and its self-test suites, the contract-integrity probe, the worktree
reaper chain, the meta-role workers and role templates, the skill library, the
`ceo-wiki/` second-brain system, the scaffold directories, the 60-second demo,
and the packaging files (`VERSION`, `VERSIONING.md`, `UPGRADING.md`).
[`README.md`](./README.md)'s "What ships" table is the authoritative
piece-by-piece inventory; it is kept current and is not duplicated here.

### Changed

- The engine is RichOS-branded throughout: it is **the RichOS engine**, the
  machinery behind **Rich Hand**. Product-voice text says *Rich* and *AI
  workers*; Claude Code mechanics terms (agent, subagent, teammate, spawn,
  orchestrator) are retained wherever precision demands them.
- `.github/workflows/kit-self-verify.yml` → `.github/workflows/engine-self-verify.yml`.
- The integrity probe's banner reads `richos-engine v<x.y.z> — contract
  integrity probe`.
- `scripts/demo.sh`'s throwaway sample repo is created under a
  `richos-engine-demo.XXXXXX` temp prefix (asserted by `scripts/demo.test.sh`).

### Provenance

The upstream product's own changelog — its build-wave history up to the fork
point — is kept with that product and is not carried into this
repository.
It is a historical record of a separate product line that continues to exist
independently; it is not a record of RichOS releases, and nothing in it should
be read as a promise about this engine's future.
