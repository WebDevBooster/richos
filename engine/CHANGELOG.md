# Changelog

All notable changes to the **RichOS engine** are recorded here.

The engine follows [semantic versioning](https://semver.org/) as defined for a
doctrine + hooks product in [`VERSIONING.md`](./VERSIONING.md) (what counts as
MAJOR / MINOR / PATCH), and this file follows
[Keep a Changelog](https://keepachangelog.com/): each release gets a dated
version heading with Added / Changed / Fixed groupings.

## [Unreleased]

### Added

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
