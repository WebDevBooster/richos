# Executive Continuity System

ECS owns durable operational obligations and pending decisions. It supplies a
bounded brief to a fresh reasoning process and paginated inspection for omitted
records. The app ledger owns conversation evidence, the provider owns execution
observations, Mega Lander owns workspaces and Git owns integration facts. Loro
owns organizational knowledge.

`core/` contains the event store, projections and structured checkpoints.
`migrations/` contains ordered SQLite schema changes. `adapters/app.py` accepts
explicit app-issued scope. `adapters/mcp.py` exposes checkpoint and inspection
tools using a private scope file written by the app. `bin/ecs` is the bounded
one-request local JSON protocol. Python and its standard library are required.

State is private and external to the installed engine. Every app invocation must
provide an absolute `--state-root`; it never adopts terminal state through the
working directory or `ECS_HOME`. No personal database or agent roster ships here.

Run `bash ecs/tests/run.test.sh` from the engine directory. These tests use
fictional records and temporary state. The Rust bridge tests run with
`cargo test -p richos-core --test delivered_ecs_tests` from the app directory.
Component tests do not certify installed app orchestration or release readiness.

See [the app protocol](CONTRACT.md) and [neutral import contract](IMPORT.md).
