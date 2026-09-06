# Contributing to RichOS

Thank you for looking. Read the first two sections before the long ones. The
first decides whether you *can* open a pull request here; the second decides
whether you want to.

## Who may open a pull request, and what is open to everybody

**Issues are open to everyone. Pull requests are not.** Both halves of that
matter, and the first half is the one people miss.

**Anybody may open an issue.** A bug report, a question, a design proposal, a
"would you take a pull request for this?", a typo — first visit or hundredth,
nobody has to be approved, and nothing in this repository closes an issue
automatically. That door is deliberately unlocked, and it is the one to use.

**Pull requests come only from approved accounts.** A pull request from an
account that is not approved is **closed automatically, usually within a minute,
by a bot, before a human has read a line of it.** That is not a judgment of your
change — nothing has looked at your change. It is a filter on who can put work
into a review queue that one person empties. You will get a comment explaining
it and linking back here, your commits are not deleted, and the pull request can
be reopened once you are approved.

Saying that here, plainly, is the point of this section. Discovering it by
having a weekend's work shut by a bot is not.

### How to get approved

1. **Open an issue** describing what you want to change — the "Idea or question"
   form exists for exactly this — and say you would like to be added to the
   contributor list.
2. **Wait for a reply.** There is one maintainer, so this can take a while.
   Approval normally follows a conversation about the change itself, because a
   pull request here can be declined for direction rather than for quality, and
   that conversation is what stops you spending an evening on something that was
   never going to land.
3. **A maintainer adds your GitHub username to `.github/VOUCHED.td`.** One line,
   committed to `main`. That is the entire mechanism: no form, no agreement to
   sign, no account to create anywhere else.
4. **Open your pull request.** It stays open and joins the normal review queue.

**If you have already written the change**, it is not wasted. Open the issue,
link your fork or your branch from it, and say what you did. If the gate has
already closed a pull request of yours, reopening it after you are approved
brings back every commit that was in it.

**What approval is not.** It is not a promise to review on any schedule, and not
a promise to merge anything. It means your work reaches a person instead of a
bot.

### Who is already approved without appearing on the list

Repository collaborators with write or admin access pass automatically — that is
checked before the file is read. Accounts whose username ends in `[bot]`, such
as Dependabot, are skipped entirely.

### Where the mechanism lives, so you can check it yourself

- `.github/VOUCHED.td` — the list. Its format is documented at the top of it.
- `.github/workflows/vouch-pr.yml` — the workflow that reads it, using
  [Vouch](https://github.com/mitchellh/vouch). Its header says what it does, how
  it fails, and what it deliberately does not do.

Both are public on purpose. A rule that can close somebody's work should be one
that person can read.

## Where this project actually is

RichOS is an **early project, recently made public**. Three releases have been
published — `v1.0.0`, `v1.0.1` and `v1.0.2`, all on 2026-09-04 — and parts of
the application are still personalized to its author. It is one person's project
that has been made public, not a product with a team behind it.

Three of the five continuous-integration workflows run on pushes and pull
requests. Two, `engine-self-verify` and `packaging-ci`, are disabled in their own
files, each for a measured reason. `.github/workflows/README.md` says which is
which and why, and it is kept current rather than written once.

What that means for you, in practice:

- **Open an issue before you write anything.** Here that is not the polite
  suggestion it is in most projects: an unapproved pull request is closed
  automatically, and the issue is the route to being approved. The section above
  has the steps.
- A pull request may sit for a while. There is no rota and no service level.
- A pull request may be declined for direction rather than for quality — which
  is the real reason the conversation comes first.
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

Everything from here on assumes your account is approved. If it is not, the
first section is the one you need — an unapproved pull request never reaches any
of this.

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
- **Do not read the checks as a verdict on your change alone.** Three workflows
  run on pull requests — `app-spine-ci`, `ui-suite-ci` and
  `windows-companion-ci` — each behind its own path filter, so a pull request
  that touches nothing they watch gets no tick at all, and that is normal rather
  than a problem. Two more are disabled in their own files and will not run for
  anybody. Before assuming a red tick is yours, check whether `main` is red for
  the same job. Either way, run the suites locally and say in the description
  which ones you ran.

## Reporting problems

- **A security vulnerability does not go in an issue or a pull request.**
  `.github/SECURITY.md` has the private routes and what to expect back.
- **A bug** goes in an issue, and you do not need to be approved to open one.
  Name the release you were on — `v1.0.2`, say — or the commit SHA if you built
  from source, plus your operating system and what you expected instead.
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
- `.github/VOUCHED.td` — the accounts approved to open a pull request.
- `.github/workflows/vouch-pr.yml` — the workflow that enforces it, and its own
  account of how it fails.
- `.github/workflows/README.md` — which workflows run, which do not, and why.
- `app/README.md` — the application's own build, layout and test documentation.
