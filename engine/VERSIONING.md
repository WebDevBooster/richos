# Versioning — how the engine is versioned and released

The RichOS engine is a *product*: a set of enforcement hooks, doctrine,
scaffolds, and skills that adopters copy into their own repositories and then
keep in sync with releases. A product that can be upgraded needs a version an adopter can
name ("I'm on 1.2.0, what changed in 1.3.0?") and a release ritual that makes
each version's contents legible. This document defines both. For the mechanics
of *pulling* a new version into an already-adopted repo, see
[`UPGRADING.md`](./UPGRADING.md); for the per-version contents, see
[`CHANGELOG.md`](./CHANGELOG.md).

## Where the version lives

The engine's version is a single line in the top-level [`VERSION`](./VERSION) file:

```
1.0.0
```

**`VERSION` is engine-owned, not adopter-owned.** It is deliberately a standalone
file rather than an `ENGINE_VERSION=` line in `orchestration.config`, because
`orchestration.config` is the one file an adopter *fills in with their own
values* — mixing the engine's identity into it would blur the ownership boundary
that [`UPGRADING.md`](./UPGRADING.md) relies on (engine-owned files are safe to
overwrite on upgrade; adopter-owned files must be merged carefully). Keeping the
version in its own file means a future release's `VERSION` lands cleanly on
upgrade with zero merge risk, and an adopter can answer "which version am I on?"
by reading one line they never edited.

**The probe prints it.** `scripts/hooks/contract-integrity-probe.sh` reads
`VERSION` and prints a `richos-engine v<x.y.z> — contract integrity probe`
banner at the top of every run (informational only — a missing `VERSION` prints
a cosmetic "VERSION file absent" note and never fails a layer). Because the CI
workflow (`.github/workflows/engine-self-verify.yml`) runs the probe on every
push/PR, an adopter's own CI logs are self-identifying about which engine version
is installed — useful when an upgrade goes wrong and you need to know your
starting point.

## The scheme — semantic versioning for a doctrine + hooks engine

The engine follows [semantic versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`
— but "breaking" means something specific for a product whose surface area is
enforcement behavior, config keys, and doctrine rather than a code API. An
adopter's mental model is: *"will pulling this release change how the machinery
behaves, or require me to change something I filled in?"*

### MAJOR — a bump that can break an adopter's setup or reverse a rule they built on

Increment MAJOR when a release would, without adopter action, change enforced
behavior, invalidate existing configuration, or reverse doctrine an adopter has
organized their team around. Concretely:

- **Hook enforcement behavior changes** — a guard starts blocking (or stops
  blocking) something it previously allowed (or refused); a hook's exit-code
  contract changes; a fail-open path becomes fail-closed or vice versa. Anything
  that changes what an existing, correctly-configured repo experiences at a
  spawn/write/resume.
- **Config key renames or removals** — an `orchestration.config` key is renamed,
  removed, or has its meaning/format changed; a `.claude/settings.local.json`
  key the doctrine depends on is added-as-required or moved. An adopter's
  filled-in config would need editing to keep working.
- **Doctrine reversals** — a load-bearing rule is inverted or removed: e.g. the
  single-writer land model, worktree-per-worker isolation, the "commit is the
  handoff" contract, the QA-pipeline ordering, or the model-tiering defaults
  change in a way that makes an adopter's existing process wrong.
- **Probe/CI contract changes** — a new HARD probe layer that an
  otherwise-healthy adopter repo would now fail, or a change to what the CI
  workflow asserts such that a previously-green adopter goes red without doing
  anything wrong.
- **Structural removals** — a scaffold directory, meta-role, or shipped skill an
  adopter's doctrine references is removed or renamed.

### MINOR — new capability, backward-compatible

Increment MINOR when a release *adds* without breaking:

- **New hooks or guards** that are additive (they gate a previously-ungated
  action but ship OFF-by-default, or gate only genuinely-new surface) — plus any
  new *warn-only* probe layer.
- **New skills** added to `skills/`, or new role templates in
  `.claude/agents/templates/`.
- **New docs, scaffolds, or tooling** (a new `docs/` reference, a new scaffold
  directory, a new `tools/` utility) that an adopter can ignore with no effect.
- **New optional config keys** that default to today's behavior when unset.
- **Meaningful expansions** of existing doctrine that add guidance without
  reversing any existing rule.

### PATCH — fixes and clarifications, no behavior or interface change

Increment PATCH for:

- **Bug fixes** to a hook, script, or the demo/probe that restore *intended*
  behavior (a fail-open path that should have been fail-closed; a false-positive
  in the secrets scanner) — the fix corrects a defect, it doesn't redefine the
  contract.
- **Doc corrections, typos, wording, and non-behavioral clarifications** —
  including README/CHANGELOG/skill prose fixes and the currency refreshes that
  keep vendored skills accurate.
- **Test-only additions** that increase coverage without changing shipped
  behavior.
- **Internal refactors** with no observable change to enforcement, config, or
  doctrine.

### The judgment call

When a change sits on a boundary, ask the adopter-impact question, not the
diff-size question: *does a correctly-configured adopter who pulls this release
have to change something, or experience different enforcement, to stay healthy?*
If yes → MAJOR. If they gain something they can ignore → MINOR. If nothing they
can observe changes except a defect being fixed → PATCH. A one-line hook edit
that flips a fail-open to fail-closed is MAJOR; a 500-line new skill is MINOR.

## The release ritual

A release is cut in a fixed order so `CHANGELOG.md`, `VERSION`, and the tag can
never disagree with each other:

1. **Land all the release's content first.** Every commit that belongs in the
   release is merged to `main` and the suites are green
   (`for t in scripts/hooks/*.test.sh; do bash "$t"; done`, `scripts/demo.sh`
   → 7/7, `scripts/hooks/contract-integrity-probe.sh` → exit 0). A release only
   ever tags a green tree.
2. **Update `CHANGELOG.md`.** Move the accumulated entries out of
   `## [Unreleased]` into a new dated `## [x.y.z]` section, group them
   Added / Changed / Fixed, reference the SHAs, and pick the MAJOR/MINOR/PATCH
   bump per the scheme above based on the aggregate adopter impact of everything
   in the section.
3. **Bump `VERSION`.** Set the single line in `VERSION` to the new `x.y.z`. This
   is the commit that "is" the release — its message names the version.
4. **Tag.** `git tag -a vx.y.z -m "richos-engine vx.y.z"` on that commit,
   then push the tag. The tag is the durable, immutable pointer an adopter's
   upgrade mechanic (`UPGRADING.md`) fetches and diffs against.

Keep the order: **CHANGELOG → VERSION bump → tag.** The changelog names what
shipped, the VERSION bump records it in the tree, and the tag freezes that exact
tree as the named release. Never tag a tree whose `VERSION` and `CHANGELOG.md`
don't already reflect the version being tagged.

### The first tag is pending — deliberately

**No git tag exists yet, and none should be created until the CEO's license
decision lands.** The engine's contents are complete and recorded in
`CHANGELOG.md` under `## [1.0.0] — 2026-08-20 — the fork`, but a *release* — a
distributable, tagged artifact — is precisely what a license governs, and the
license choice is an explicit CEO business/legal decision sequenced LAST (see
[`LICENSE-TODO.md`](./LICENSE-TODO.md)). Tagging `v1.0.0` before there is a
`LICENSE` file would ship a distributable release under the all-rights-reserved
default with no stated terms — exactly the ambiguity `LICENSE-TODO.md` exists to
prevent. So the ritual above is fully wired and ready, and step 4 (the first
tag) fires only once the CEO has chosen a license and the package is declared
complete. Until then the engine lives at `1.0.0` in `VERSION` and `CHANGELOG.md`
as the finished-but-unreleased state.
