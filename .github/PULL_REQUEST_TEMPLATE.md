<!--
BEFORE YOU POST THIS. Pull requests here are accepted only from approved
accounts, and an unapproved one is closed automatically within about a minute,
before anybody reads it. Whether you are approved is one short file:
.github/VOUCHED.td. If your username is not in it, open an ISSUE instead —
issues are open to everyone, and an issue is the route to being approved.
.github/CONTRIBUTING.md has the four steps, and none of them is a form.

Two more things from that file that decide whether this lands:

  * Opening it offers your change under AGPL-3.0-only. You keep your copyright.
  * A large change is worth an issue BEFORE the work, not after it.

A security vulnerability never goes in a pull request. Use the security policy.
-->

## What this changes, and why

<!-- Why, not just what — the diff already says what. -->

## How you know it works

<!--
Name the checks you actually ran and paste the result. "Should be fine" is the
sentence this section exists to replace.

  cd app && cargo test --locked -p richos-core
  cd app/src-tauri && cargo check --locked
  bash app/scripts/run-tests.sh                     # macOS only
  cd app/ui/tests && npm install && npm test
  bash engine/scripts/run-all-tests.sh              # slow: allow the better part of an hour
  bash engine/scripts/publication-completeness.sh --root .

The workflows that run here are path-filtered, so a pull request can
legitimately finish with no tick at all, and two of the five are disabled for
everybody. An absent or red tick may mean nothing about your change — check
whether main is red for the same job. Either way, say what you ran locally.
-->

## Checklist

- [ ] My GitHub username is in `.github/VOUCHED.td`, or I have an open issue
      asking to be added. (Without this, a bot closes this pull request.)
- [ ] One change, not several unrelated ones.
- [ ] A test that would have failed before this change, where the change is testable.
- [ ] Documentation updated if this makes an existing sentence untrue.
- [ ] No RichOS brand material added (see `docs/legal/BRAND-ASSETS.md`).

### Only if this touches dependencies

- [ ] The `Cargo.lock` for that workspace is regenerated and committed.
- [ ] `app/scripts/dependency-license-inventory.sh --check` passes.
- [ ] Anything newly vendored carries its upstream license file and a row in
      `docs/legal/THIRD-PARTY-NOTICES.md`.
