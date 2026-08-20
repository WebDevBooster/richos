# Changelog

All notable changes to the **RichOS engine** are recorded here.

The engine follows [semantic versioning](https://semver.org/) as defined for a
doctrine + hooks product in [`VERSIONING.md`](./VERSIONING.md) (what counts as
MAJOR / MINOR / PATCH), and this file follows
[Keep a Changelog](https://keepachangelog.com/): each release gets a dated
version heading with Added / Changed / Fixed groupings.

## [Unreleased]

Nothing yet.

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
