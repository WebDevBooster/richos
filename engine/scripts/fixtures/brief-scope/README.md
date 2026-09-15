# The round-9 brief, frozen

`round9-brief-2026-09-13.md` is the brief for round 9 **exactly as it was dispatched on 2026-09-13**.

    sha256  76c8eb46b09f9238b714fe6e5b9322a75f8e8611c2612e62dff307b0d7dea16e
    bytes   6096
    source  /Users/alex/ab/richos-hq/docs/plans/round9-brief-2026-09-13.md
            (private, operator-local; last touched there by 4ffc6114)

## Do not refresh it

This is a record of the past, not a mirror of a live file. `brief-scope.test.sh` uses it to prove one
thing — **the brief that was actually sent would have been refused** — and that claim is about the
bytes that were sent. If the file in `richos-hq` is ever edited, the fixture still holds the right
bytes and the suite's `S19src` case will say the two have diverged. The answer to that is to find out
what edited a dispatched brief, never to copy the new bytes over these.

## Why it is here at all

It used to be read through an absolute path into `richos-hq`. That path is on no CI runner, so the
eight acceptance cases that depend on it never ran there, and the mutation harness silently lost the
property whose sentinel is `S20`. Vendoring makes the suite self-contained; the `S19pin` case makes
the copy honest by asserting the hash above on every run, in every environment.

That last part is the whole point. richos already carries one vendored copy of a `richos-hq` page, at
`docs/plans/worktree-spec-2026-09-11.md`, and round 9's own brief records what is wrong with it: its
sha256 "sits in a comment", so "nothing verifies it automatically — which is exactly why an edit to it
would go unnoticed." A hash nothing checks is a comment. A hash a case asserts is a pin.

## What the suite actually needs from these bytes

Only that they declare nothing:

    parse_declaration(round9_brief)
      -> {"serves": [], "scope": null, "hatch": null, "default_design": null}

Everything else in the file is inert to the mechanism. That is exactly why a small hand-written
fixture could exhibit the same property and would be worthless: the suite already has one at `S2`.
The value of this file is not the property, it is the **provenance** of the bytes that carry it.
