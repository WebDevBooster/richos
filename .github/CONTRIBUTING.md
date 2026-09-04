# Contributing to RichOS

Thank you for looking. Read the two short sections before the long ones: they
are the ones that change whether you want to contribute at all.

## Where this project actually is

RichOS is an **early source snapshot**. There are no releases and no tags, the
continuous-integration workflows were disabled before publication, and parts of
the application are still personalized to its author. It is one person's
project that has been made public, not a product with a team behind it.

What that means for you, in practice:

- A pull request may sit for a while. There is no rota and no service level.
- A pull request may be declined for direction rather than for quality. If you
  are about to spend real time on something, **open an issue first and ask.**
  That is not a formality here; it is the difference between work that lands and
  work that does not.
- Small, self-contained changes land far more easily than large ones. A fix with
  a test beats a refactor with a rationale.

## The license, said plainly

RichOS-authored software is **GNU AGPL v3, and no later version** — SPDX
`AGPL-3.0-only`. The full text is `LICENSE` at the repository root and
`docs/legal/LICENSING.md` explains its scope. Three consequences are worth
stating before you open a pull request rather than after.

**1. Your contribution is licensed under the AGPL too.** There is no separate
contributor agreement to sign. By opening a pull request against this repository
you are offering your change under the same license the project uses — this is
GitHub's own default for public repositories (Terms of Service, section D.6),
and it is the arrangement in force here.

**2. You keep your copyright.** Contributing does not assign it and does not
grant anyone a license beyond the AGPL. The practical consequence is worth being
blunt about: **the maintainer cannot relicense your contribution under
commercial terms without asking you.** He can do that with his own code, because
a copyright holder is not bound by the license he offers to others. He cannot do
it with yours. If that arrangement ever changes — a Developer Certificate of
Origin, a contributor license agreement — it will be stated in this file and it
will apply to contributions made after it appears, never retroactively to yours.

**3. The AGPL's network clause travels with the code.** If you run a modified
RichOS and let other people interact with it over a network, section 13 requires
you to offer those users the corresponding source of your modified version. This
is the term a permissive license does not have, and it is deliberate.

### The brand is not covered by the license

The RichOS name, the mark, the application icons, the banner artwork and the
Rich Hand avatar are **excluded** from the AGPL and remain all rights reserved.
`docs/legal/BRAND-ASSETS.md` names every excluded file exactly.

The short version: **take the software, rebrand your fork.** And please do not
add brand material to a pull request — new logos, marks, or artwork that
reproduces the RichOS identity will be declined regardless of how good it is,
because the licensing boundary is the thing being kept clean.

## Before you open a pull request

### Run the checks that exist

The authoritative build-and-test documentation is `app/README.md`; this is the
short path, not a second copy of it.

```sh
# The runtime spine. Seconds, no network, no native dependencies.
cd app && cargo test --locked -p richos-core

# The Tauri shell. A detached workspace with its own lockfile.
cd app/src-tauri && cargo check --locked

# The packaging and signing suites. macOS only, and they say so rather
# than skipping on other platforms.
bash app/scripts/run-tests.sh

# The browser suites for the frontend.
cd app/ui/tests && npm install && npm test

# The engine's own suites. Be warned: this is not a quick check —
# the contract-integrity suite alone runs for the better part of an hour.
bash engine/scripts/run-all-tests.sh
```

**`--locked` is not optional and not decoration.** Both `app/Cargo.lock` and
`app/src-tauri/Cargo.lock` are tracked, and the flag makes cargo *refuse* to
resolve a version dynamically instead of quietly doing it. If a command fails
with "the lock file needs to be updated", the fix is to update and commit the
lockfile, never to drop the flag.

### If your change touches dependencies

Three things belong in the same commit:

1. the manifest change,
2. the regenerated `Cargo.lock` for that workspace, and
3. a regenerated dependency inventory:

```sh
app/scripts/dependency-license-inventory.sh          # regenerate
app/scripts/dependency-license-inventory.sh --check  # must pass
```

The generator **refuses** to produce a document if a new package declares no
license, or declares one that has never been reviewed against AGPL-3.0-only.
That refusal is the point of it: a dependency whose license forbids combination
with the AGPL cannot be added, however convenient it is. If you hit that
refusal, say so in the pull request rather than editing the reviewed table to
make it go away.

### If you are vendoring somebody else's work

`docs/legal/LICENSING.md` sets the rule and `docs/legal/THIRD-PARTY-NOTICES.md`
is the inventory. Three things in the same commit: the upstream license file
next to the work, a row in the notices table with a pinned revision or a
declared version, and — if your copy differs from upstream at all — a notice in
that directory saying how.

### If your change adds or removes a file the documentation cites

```sh
bash engine/scripts/publication-completeness.sh --root .
```

It fails on a document that cites a file the published tree does not contain.
That check exists because the tree had four separate places claiming a
capability it did not deliver.

## Opening the pull request

- **One change per pull request.** A branch that fixes a bug and tidies four
  unrelated files is two reviews pretending to be one.
- **Say what and why, not just what.** The commit history here is written in
  full sentences that explain the reasoning; read a few before writing yours.
  A message that says what changed is available from the diff for free.
- **Include the test that would have failed before.** A test named for the
  invariant it protects is worth more than three named `test_thing_works`.
- **Expect the automated checks not to run at first.** The workflows are
  disabled — `.github/workflows/README.md` says why — so a green tick may be
  absent for reasons that have nothing to do with your change. Run the suites
  locally and say in the description which ones you ran.

## Reporting problems

- **A security vulnerability does not go in an issue or a pull request.**
  `.github/SECURITY.md` has the private routes and what to expect back.
- **A bug** goes in an issue. Include the commit SHA you were on — there are no
  releases to name — your operating system, and what you expected instead.
- **An idea** is welcome as an issue too, especially before you build it.

## Language

Documentation and user-facing text in this project are written in **American
English**. Code identifiers, third-party names and quoted external material stay
as they are; renaming a variable to match a dialect is churn nobody benefits
from.

## Related documents

- `LICENSE` — GNU AGPL v3.
- `docs/legal/LICENSING.md` — what the license covers, and the two carve-outs.
- `docs/legal/BRAND-ASSETS.md` — the brand and trademark exclusion.
- `docs/legal/THIRD-PARTY-NOTICES.md` — bundled third-party work and its terms.
- `docs/legal/THIRD-PARTY-RUST-DEPENDENCIES.md` — the compiled dependency
  inventory, keyed to the tracked lockfile digests.
- `.github/SECURITY.md` — how to report a vulnerability.
- `app/README.md` — the application's own build, layout and test documentation.
