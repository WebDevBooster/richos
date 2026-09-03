# Moved to the private record — 2026-09-03/04

The `PRIVATE_FILES` seed for `.publication-boundary` was blocked on a landing-order dependency
on 2026-09-01 (the declaration carried a key the installed engine did not yet know, and an
unknown key is BROKEN by design). **That is resolved** — `PRIVATE_FILES` is committed in
`.publication-boundary` today, and `engine/scripts/hooks/publication-boundary.test.sh` proves the
mechanism is armed rather than merely installed.

The blocker note that used to be here is now in the private record, at
`docs/verification/publication-identity-2026-09-01-SEED.md`, for two reasons:

1. It is an internal process artifact — a worktree path, an agent name, the operator's private
   file named and discussed.
2. **It described, and confirmed as working, a way to defeat the publication commit guard.** The
   approach was correctly rejected at the time. Publishing the steps is a different thing from
   publishing the guard's honest coverage limits, and only the second belongs in an open
   repository.

The rule that decides which of those two a file is: `engine/CLAUDE.md.template`, *"Writing for a
Repository That PUBLISHES — the same doctrine, in two modes"*.
