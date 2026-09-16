# ECS app protocol 1

Run `python3 ecs/bin/ecs --state-root /absolute/private/state` and supply one JSON
object on stdin. Requests are limited to 1 MiB. Every request names `protocol: 1`
and `command`. Success returns `{protocol:1, ok:true, result:...}`. Failure returns
`{protocol:1, ok:false, error:{kind,message}}` with exit 2. An unavailable component
or unreadable store is distinct from an empty result. The Rust bridge applies a
20-second deadline and a 4 MiB response bound.

| Command | Purpose |
|---|---|
| `hello` | Read-only delivery/protocol identity without creating state |
| `current` | Host reads the current binding for compare-and-set activation |
| `bind` | Host binds entity, thread, session, turn and audience with expected revision |
| `checkpoint` | Persist typed operational statements with a stable request ID |
| `receipt` | Read a previous checkpoint receipt in the same entity and thread |
| `brief` | Bounded continuity text, counts and an inspection route |
| `inspect` | Scoped paginated records with sequence fencing |
| `observe` | Host-issued provider observation, never verified assignment completion |
| `import-preview` | Read-only neutral envelope validation and mapping preview |
| `import-apply` | Fenced application with durable partial receipts |

After binding, commands other than the read-only preview carry the exact
`binding` object returned by `bind`: entity_id, thread_id, session_id, turn_id,
audience and revision. Each mutation checks its scope transactionally. A scope
switch invalidates the old binding. Read results are fenced again before return.
A previous successful binding receipt cannot reactivate a superseded scope.

The model-facing MCP server exposes only `checkpoint` and `inspect`. It takes
its state location and binding from an app-owned scope file. Tool arguments
cannot override either. The app grants access only during a visible turn and
revokes it when the turn returns. Hidden context preparation has no write grant.
This is an application protocol boundary, not an operating-system sandbox.

Checkpoints contain `statements: [{verb, fields}]` or an explicit
`{no_changes:true, reason:...}`. Fields are strings. Opening verbs are priority,
initiative, open_loop, commitment, decision, deadline and blocker. Updates name
the existing `id`. A model-authored checkpoint cannot mark external work
completed, including through an update. Provider exit is not a Git verification
receipt. Completion and correction routing must use their owning app adapters.

A repeated checkpoint ID with identical content returns its receipt. Changed
content is rejected. Interrupted multi-statement checkpoints reconcile existing
statement events before continuing. ECS does not claim a transaction spanning
the app ledger, Loro, a provider or Git.

Schema upgrades hold a migration lock and back up existing SQLite state before
applying new migrations. Individual migrations are transactional. Missing or
unknown migrations are errors, including code downgrade over newer state. Restore
a backup into a separate state root with compatible code; do not overwrite later
work. The tests verify that restoration preserves the previous active scope.
