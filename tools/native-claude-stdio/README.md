# `native-claude-stdio-probe` — spike harness, not a product

Drives the **native `claude` binary** (`/Users/alex/.local/share/claude/versions/2.1.251`,
Mach-O arm64, 197,171,680 bytes) over its `--input-format=stream-json
--output-format=stream-json` stdio, **from Rust**, to answer one question:

> Can RichOS delete `app/acp-adapter` — its last shipped npm dependency,
> `@agentclientprotocol/claude-agent-acp` — by speaking to the native binary directly?

The findings and the raw captured evidence live in
`docs/verification/native-claude-stream-json-2026-08-31/`. Read that first; this directory
is only the instrument that produced it.

## Why it is shaped like `acp.rs`

Deliberately: spawn → one reader thread → dispatch → a per-turn channel, and the same
in-harness auto-approve policy (`acp.rs:469-479`, first `allow*` option). Half of what the
spike tests is whether the *structure* ports, not just whether the bytes arrive. It does not
share a line of code with `acp.rs` and nothing here is a port.

## Running it

```
cargo run --release -- <out_dir> <child_cwd>
```

It costs four real API turns. `<child_cwd>` should be a scratch directory: the probe asks
the agent to write one file, and it will.

## Isolation

`Cargo.toml` carries an empty `[workspace]` table, exactly as `app/src-tauri/` does, so this
crate is invisible to `cargo test -p richos-core` and to the `app/` workspace. It is not
built by any gate, and it ships nowhere.
