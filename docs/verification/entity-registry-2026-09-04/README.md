# The company registry became per-user — measured, 2026-09-04

## What was wrong

`EntityRegistry::CEOS_COMPANIES` was a `const` table of six real companies, each bound to an
absolute root under one man's home directory, and `impl Default for EntityRegistry` returned
it — so that table was **the shipping registry of every copy of RichOS ever built**. On the
machine it was written on it worked. On any other machine it did two things at once:

1. **It published a private list.** The company picker renders `display_name` and `roots` for
   every registered entity, so a second person opening RichOS was shown six companies that
   are not his and the name of a home directory that is not his.
2. **It locked the app.** No path a second person works in is a registered root, so
   `resolve_root` refused — correctly, ECS §3.3 — a Finder launch (working directory `/`)
   resolved no entity at all, and the picker's only answers were another man's companies. The
   two honest states available to him were *refuse every send* and *file my work under
   FemcBoost*.

## The two questions this record answers

Both with a program that ran, not with reasoning.

### 1. Can a person with no configuration reach a working conversation?

`raw/02-fresh-user-first-run.txt` — `cargo run -p richos-core --example fresh_user_first_run`.

A config directory that has never seen RichOS, in this order: the shipping default is checked
and is **empty**; `entities.json` is absent and the load says so; his own folder resolves to
nothing and `/` resolves to nothing; a send is **refused** with nothing filed; he registers his
own company; the file is written; it is **read back from disk** — the next launch, in effect —
his folder now resolves, from the root and from deep inside it, everything else still fails
closed, and a turn lands in the ledger bound to his company.

The last thing it does is check the bytes rather than its own memory of them: neither
`entities.json` nor the ledger contains the string `femcboost`, `deeply`, `prospects`,
`gpt-exporter` or `webinar-booster`.

### 2. Does an install that already ran lose its threads?

`raw/01-migration-against-the-live-ledger.txt` —
`cargo run -p richos-core --example registry_migration_check -- <ledger>`, pointed at **the
live install on this machine**, read-only. It opens the ledger, replays it in memory, writes
nothing to it and nothing near it, and reads no message body.

```
threads        : 3 (1 with no entity home)
entity ids used: richos, femcboost

--- without the migration ---
shipped default: 0 compan(ies)
would be unreachable: richos, femcboost
```

Both would be unreachable — not deleted, which is worse: still on disk, refused by every
scoped read and write, and indistinguishable from gone to the person looking at the screen.
With the migration, both survive a write and a reload from disk.

**The migration invents no root**, and the program asserts that rather than describing it.
Nothing on the machine knows where those companies live, and a guessed root is a wrong entity
waiting to happen. So the display names come out of the ids (`richos` → `Richos`) and the
`roots` lists are empty — the two things a person will want to correct, in a file whose whole
purpose is that he can.

## What this means for the person whose install it is

- **His threads keep working with no action at all.** That is the whole point of the
  migration and it is what the run above shows.
- **Two companies are restored, not six.** Only `richos` and `femcboost` have ever had a
  thread filed under them on this install; the other four exist nowhere in his data, so
  nothing on the machine can honestly assert them. Nothing is orphaned, because nothing
  exists under them to orphan.
- **Root resolution stops selecting a company for him until he adds folders.** In practice
  this costs him nothing today: he launches from Finder, whose working directory is `/`,
  which never resolved by root anyway (measured 2026-09-01,
  `docs/verification/entity-choice-2026-09-01/`). It matters for a terminal launch.
- **His display names come back as `Richos` and `Femcboost`.** A table that knew to write
  `RichOS` and `FemcBoost` would be the compiled-in company list returning in a costume.

**The one-step restore — the exact `entities.json` giving all six their real names and their
roots — is deliberately NOT in this repository.** This tree is the open-source publication
target, and committing a file whose entire content is one man's company list and home
directory would reintroduce, in `docs/`, precisely what was removed from the binary. It is in
the handoff instead, for whoever places it on his machine.

## Where the rest of the evidence is

The two runs above are the artifact-level proof. The property-level proof is in the suites,
and every new assertion was made load-bearing by mutating the shipped source and watching it
go red rather than by being written and believed:

- `app/crates/richos-core/src/entity.rs` unit tests and
  `app/crates/richos-core/tests/entity_registry_tests.rs` — `cargo test -p richos-core`,
  696 passing.
- `app/src-tauri/src/main.rs` `entity_choice_tests` — `cargo test` in `app/src-tauri`,
  48 passing.
- `app/ui/tests` — 21 suites, 407 checks, none skipped, including `affordances.js`, which
  refuses any user-visible state that is not classified with a reason.
