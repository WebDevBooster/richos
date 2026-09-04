<!--
Read .github/CONTRIBUTING.md first if you have not. Two things from it that
decide whether this pull request lands:

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

The workflows are currently disabled, so an absent green tick may mean nothing
about your change. Say what you ran locally.
-->

## Checklist

- [ ] One change, not several unrelated ones.
- [ ] A test that would have failed before this change, where the change is testable.
- [ ] Documentation updated if this makes an existing sentence untrue.
- [ ] No RichOS brand material added (see `docs/legal/BRAND-ASSETS.md`).

### Only if this touches dependencies

- [ ] The `Cargo.lock` for that workspace is regenerated and committed.
- [ ] `app/scripts/dependency-license-inventory.sh --check` passes.
- [ ] Anything newly vendored carries its upstream license file and a row in
      `docs/legal/THIRD-PARTY-NOTICES.md`.
