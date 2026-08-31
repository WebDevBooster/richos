# Raw captures — native `claude` stream-json stdio, 2026-08-31

Every line the child process wrote, unedited, in the order it arrived. Nothing here is
summarized; the summary is `../findings.md` and it cites these files by run and line.

Agent binary under test: `/Users/alex/.local/share/claude/versions/2.1.251`,
Mach-O 64-bit executable arm64, 197,171,680 bytes. `otool -L` lists four libraries, all of
them system: `libicucore.A.dylib`, `libresolv.9.dylib`, `libc++.1.dylib`, `libSystem.B.dylib`.
No Node runtime is linked or bundled.

Every run was launched with `ANTHROPIC_API_KEY` **removed from the environment**
(`env -u ANTHROPIC_API_KEY`), because the auth question is one of the four things being
answered and an inherited key would have silently answered it wrong.

Common flags: `--print --output-format=stream-json --verbose --model sonnet
--setting-sources '' --no-session-persistence`. `--setting-sources ''` keeps the operator's
user/project/local settings out of the measurement.

| file | driver | what it establishes |
|---|---|---|
| `run1-text-in-streamjson-out.jsonl` | (inline shell) | the baseline: text prompt in, stream-json out, streamed `text_delta`s, a `result` carrying `stop_reason` and `usage` |
| `run2-multiturn-one-process.jsonl` | `drivers/drive.py` | two turns over ONE long-lived process share one `session_id`; the second turn recalls `4271` from the first |
| `run3-tool-permission-manual.jsonl` | `drivers/drive2.py` | `tool_use` → `tool_result` shape, `input_json_delta` streaming of tool arguments, and the full `result` field inventory |
| `run4-control-initialize.jsonl` | `drivers/drive3.py` | the SDK control protocol answers over this stdio: `control_request{initialize}` → `control_response` with `account`, `models`, `current_permission_mode` |
| `run5-interrupt.jsonl` | `drivers/drive4.py` | `control_request{interrupt}` mid-turn: acked, partial text preserved, `result` is `error_during_execution` |
| `run6-interrupt-then-reuse.jsonl` | `drivers/drive5.py` | the process SURVIVES the interrupt and the next turn still has the session's context (`8813`) |
| `run7-can-use-tool.jsonl` | `drivers/drive6.py` | a NEGATIVE result, kept deliberately: `echo` needed no approval, so no `can_use_tool` fired. This is why run8 exists |
| `run8-can-use-tool-handshake.jsonl` | `drivers/drive7.py` | `can_use_tool` observed end to end on a write outside the working directory — request, our `allow`, and the file actually created |
| `run9-rust-driven.jsonl` + `.timings.tsv` | `../../../spike/native-claude-stdio` | **the definitive run: all of the above, from Rust, in one process.** Timings tsv carries the read offset of every line |
| `run10-control-surface-and-errors.jsonl` | `drivers/drive8.py` | `set_model` succeeds; `set_permission_mode` refuses with a structured error; an unknown subtype returns a structured error. **No API turns — free** |
| `run11-plan-thinking-diff.jsonl` | `drivers/drive9.py` | an `Edit` through `can_use_tool` carries the edit INTENT (`old_string`/`new_string`), not ACP's pre-rendered diff, and no `locations`. `TodoWrite` was unavailable, so `plan` stayed unobserved |
| `run12-malformed-stdin.{stdout.jsonl,stderr,exit}` | (inline shell) | one unparseable stdin line: zero bytes of stdout, a `SyntaxError` on stderr, **exit 1**. **No API turns — free** |

## Reading `run9-rust-driven.timings.tsv`

Column 1 is seconds since the probe took its first timestamp, recorded at the moment the
reader thread finished reading that line — not when the child wrote it. The difference is
below the resolution of anything claimed in `findings.md`, but it is the honest description
of what the number is.
