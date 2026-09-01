# Changelog

All notable changes to the **RichOS engine** are recorded here.

The engine follows [semantic versioning](https://semver.org/) as defined for a
doctrine + hooks product in [`VERSIONING.md`](./VERSIONING.md) (what counts as
MAJOR / MINOR / PATCH), and this file follows
[Keep a Changelog](https://keepachangelog.com/): each release gets a dated
version heading with Added / Changed / Fixed groupings.

## [Unreleased]

### Fixed

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
