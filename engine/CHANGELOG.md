# Changelog

All notable changes to the **RichOS engine** are recorded here.

The engine follows [semantic versioning](https://semver.org/) as defined for a
doctrine + hooks product in [`VERSIONING.md`](./VERSIONING.md) (what counts as
MAJOR / MINOR / PATCH), and this file follows
[Keep a Changelog](https://keepachangelog.com/): each release gets a dated
version heading with Added / Changed / Fixed groupings.

## [Unreleased]

### Added

- **The CEO queue, part two: REACHABLE, and READ FROM OUTSIDE**
  (`scripts/ceo-queue-render.sh`, `scripts/ceo-queue-init.sh`,
  `scripts/cold-open.sh`, `scripts/lib/cold-open-prompt.md`,
  `reference/ceo-queue/`) — MINOR, still inert without a `.ceo-queue`.

  The first release of the CEO queue enforced that every item waiting on the
  CEO was PREPARED, and shipped with nowhere for him to look: the items lived
  inside a long record mixed with everything else, and the only new artifact was
  a dotfile. The report read *"the contract is live, 9 prepared items"* — true
  of the record, false of his experience. The reason the other half fell out
  silently is the general case and the reason this release exists: **every
  acceptance criterion in that landing was internal.** Lint exit codes, guard
  tests, probe layers, git state. A view has no exit code, so it had no test
  that could fail, so it was never in scope and nothing said so.

  Three things now have exit codes that did not:

  1. **One entry point, enforced.** `QUEUE_VIEW` is a bare top-level, un-dotted
     file name, generated from the record by `ceo-queue-render.sh` and refused
     at commit unless it is byte-identical to what the record renders to,
     singular (no second file carrying the generated marker), and named in the
     first 40 lines of `ROOT_README`. The renderer moved INTO the engine and
     shares the predicate's single parse: the previous repo-local generator was
     a second parser of the same file, the gate would have had to trust code
     supplied by the repository it was checking, and — worst — adopters received
     the enforcement without the page.
  2. **The cold open.** `cold-open.sh` puts the CEO-facing surface in front of a
     reader with **no context by construction** — a fresh, customisation-free
     process, or a person via `--record` — and files a transcript stamped with a
     fingerprint of the front door it describes. Change the front door and the
     next commit is refused until somebody reads the new one: the freshness
     contract, identity-or-refuse, applied to a judgment. **The gate enforces
     that the reading happened and never what it concluded** — a gate that
     demanded a favourable verdict would get one every time, and the finding is
     the entire product. Undeclared `COLD_OPEN_DIR` never blocks and is printed
     as an unchecked limit on every clean verdict.
  3. **An adopter actually gets one.** `ceo-queue-init.sh` plus
     `reference/ceo-queue/` install the declaration, a starter record, the
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

- **The CEO queue** (`scripts/lib/ceo-queue.sh`, `scripts/lib/ceo-queue.py`,
  `scripts/ceo-queue-lint.sh`, `scripts/hooks/guard-ceo-queue-commits.sh`) —
  MINOR: purely additive, and inert in any repository that does not declare a
  `.ceo-queue`. Makes "waiting on the CEO" a **checkable claim** instead of an
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
  so "nothing to check" can never be read as "clean". `ceo-queue.test.sh`
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

### Fixed

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
