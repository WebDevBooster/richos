# BLOCKED — the seed line cannot be committed from this branch, and why

**Branch:** `zach-opus-pb1` · **Worktree:** `/Users/alex/ab/richos-wt/zach-opus-pb1`

## What I am blocked on

The mechanism is done and tested. **The one-line seed that arms it for the CEO's
file cannot be committed from this worktree**, and the reason is version skew,
not disagreement:

```
PRIVATE_FILES="74d5d76ea4f55c82dcaa18e4e2ab58ffca5525b3db6b0b4c60191b495cb156fc:RichOS-logo-wordmark_v3.5_font-info.md"
```

The moment that line exists in `.publication-boundary` on disk, **every commit in
`richos` is refused** — by three live hooks, all of which load
`scripts/lib/publication-boundary.sh` from `~/.claude/richos-engine`, which is a
symlink to the MAIN checkout's engine. Main's copy predates this branch, so
`PRIVATE_FILES` is an unknown key to it, and an unknown key is BROKEN by design:

```
=== RICHOS ENGINE: PUBLICATION BOUNDARY BROKEN — REFUSING TO GUESS ===
  hook   : scripts/hooks/guard-completeness-commits.sh
  file   : .publication-boundary
  reason : unknown key 'PRIVATE_FILES'. Known keys: PRIVATE_RECORD PRIVATE_SOURCES
           MIN_SPEECH_LINES MIN_QUOTE_WORDS ALLOWLIST CORPUS_MAX_FILES
           CORPUS_MAX_BYTES CORPUS_MAY_BE_EMPTY. A key this guard does not read is
           a setting that silently does nothing — refusing rather than pretending
           it took effect.
```

That refusal is CORRECT. A declaration must never be ahead of the engine reading
it, and the guard saying so loudly is the behavior this whole mechanism is built
on. It resolves by itself the instant the engine change is on main.

## What I already tried

- **Committing the seed anyway** — refused by `guard-publication-commits.sh` and
  `guard-completeness-commits.sh`, reproduced twice, with the key present and
  again with it removed to prove the key is the whole cause.
- **Staging the new declaration while leaving the old content in the working
  tree**, so the guard would parse the old file and record the new one.
  **Rejected deliberately.** It works, and it is a human deciding in the moment
  that a particular payload is safe to publish because he can see it is only a
  hash — which is precisely the failure mode this mechanism replaces. Doing it
  once to install the thing that forbids doing it would be self-refuting.
- **Putting the entries in a separate file the old engine ignores.** Rejected:
  it would leave a permanent second declaration file behind to buy one
  afternoon's convenience, and split one contract's declaration across two
  places.

## The smallest question that would unblock me

**None — this is a landing-order dependency, not a question.** It needs one
action from Rich, after the merge and before the deploy:

```bash
# in the MAIN checkout, AFTER merging zach-opus-pb1 (main's engine now knows the key):
printf '\n# The CEO's logo-wordmark font note. His instruction, twice: it stays in\n# richos-hq only. Minted with: python3 engine/scripts/lib/publication-boundary.py --digest <file>\nPRIVATE_FILES="74d5d76ea4f55c82dcaa18e4e2ab58ffca5525b3db6b0b4c60191b495cb156fc:RichOS-logo-wordmark_v3.5_font-info.md"\n' >> .publication-boundary
git add .publication-boundary && git commit -m "Arm the identity rule with the file the CEO named twice"
```

Verify it took, without needing the private file:

```bash
bash engine/scripts/hooks/publication-boundary.test.sh   # 121/121
grep -c '^PRIVATE_FILES=' .publication-boundary          # 1
```

**Until that line is committed, the mechanism is installed and disarmed.** That
is the risk worth naming out loud: machinery that looks armed and is not is
worse than none, which is this engine's own sentence. The digest and the
reasoning are also in the commit message of the mechanism commit, so the step
survives losing this file.

## What I proceeded on meanwhile

Everything else, and the seed is proven end-to-end without being committed: the
seed line was placed in the worktree declaration, both guards were run against
byte-for-byte copies of the CEO's file (under its own name and renamed), both
refused with exit 2, the probe was removed and `git status` is empty. The full
evidence is in the handoff report.
