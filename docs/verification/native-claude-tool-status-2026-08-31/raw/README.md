# Raw captures — intermediate tool status on the native `claude` stream-json stdio, 2026-08-31

Every line the child process wrote, unedited, in the order it arrived, plus a `.timings.tsv`
carrying the offset at which each line was READ. The offsets are not decoration: C2 is a
question about what arrives *between* two events, and a capture without timestamps cannot
answer it. Column 1 is seconds since the driver took its first timestamp, recorded when the
reader finished reading that line — not when the child wrote it.

Agent binary under test: `/Users/alex/.local/share/claude/versions/2.1.251`, Mach-O arm64,
197,171,680 bytes — the same binary the 2026-08-31 spike measured, unchanged.

Every run was launched with `ANTHROPIC_API_KEY` **removed from the environment**
(`env.pop`), and with the spike's flags unchanged: `--print --input-format=stream-json
--output-format=stream-json --include-partial-messages --verbose --model sonnet
--setting-sources '' --no-session-persistence --permission-prompt-tool stdio`. Nothing was
added or removed, so this observation composes with `../native-claude-stream-json-2026-08-31/`
rather than replacing it.

The summary is `../findings.md` and it cites these files by run and line.

| file | driver | what it establishes |
|---|---|---|
| `run13-longtool-bash-ticking.jsonl` + `.timings.tsv` | `drivers/drive-longtool.py` | **the answer.** One top-level `Bash` tool held for 70.228 s. `tool_progress` heartbeats arrive at +30.004 s and +60.006 s |
| `run14-longtool-task-subagent.jsonl` + `.timings.tsv` | `drivers/drive-longtool.py` | a NEGATIVE kept deliberately, for the same reason the spike kept `run7`: the design failed. The subagent was told to `sleep 70`, a built-in Bash guard refused a standalone `sleep`, the subagent backgrounded it and returned in 6 s — so no long tool ever ran. It is kept because it is where `system/task_progress` was first seen |
| `run15-longtool-task-foreground.jsonl` + `.timings.tsv` | `drivers/drive-longtool.py` | run13's control. **The identical Bash command, for 70.208 s (20 ms from run13's 70.228 s), nested inside a `Task` subagent — and zero `tool_progress` frames.** The longest silent gap is 67.131 s |
| `run16-rust-longtool.jsonl` + `.timings.tsv` | `../../../tools/native-claude-stdio` (`src/bin/tool_status.rs`) | **the definitive run: from Rust, through an `acp.rs`-shaped reader that maintains a live activity row.** The row opens, takes 2 intermediate updates at +30.021 s / +60.022 s, and closes after 70.268 s |
