# Raw captures — intermediate tool status through the ACP adapter, 2026-08-31

Every JSON-RPC message the `claude-agent-acp` child exchanged with the client, unedited, in
arrival order, each stamped with the offset at which the client READ it. This is the missing
half of `../../native-claude-tool-status-2026-08-31/`: that artifact measured the **native**
binary and closed with *"that missing run is against the adapter, not the binary"* (§6 case 3,
§8 bullet 1). These four runs are that run.

Recorded by **`app/acp-adapter/probe-machinery.js`, unmodified** — the same instrument, byte for
byte, that produced the five captures in `../../acp-emission-probe-2026-08-28/`, driven only
through its `PROBE_PROMPT` environment variable. Nothing about the client policy changed:
permissions are auto-approved with the first `allow*` option, exactly as `acp.rs:469-479` does.

Adapter under test: `@agentclientprotocol/claude-agent-acp` **0.70.0** — the same version the
2026-08-28 probe recorded (`../../acp-emission-probe-2026-08-28/observed-kinds.json:5`), so the
two compose. It fronts the same `claude` **2.1.251** the native artifact measured.

`cwd` was the neutral scratch directory the native runs used, **not** the 2026-08-28 probe's
`/Users/alex/ab/richos/engine`. That is deliberate and it is the one environmental difference
from the earlier ACP baseline: it makes the cwd identical to the native runs', so the only
variable between these captures and run13/run15 is the transport.

The workload is the native artifact's workload, unchanged, so the two sets are directly
comparable:

```
for i in $(seq 1 14); do echo tick-$i; sleep 5; done
```

14 × 5 s = **70.000 s** expected.

| file | prompt | shape | result |
|---|---|---|---|
| `acp-run-a-longtool-toplevel.jsonl` | `drivers/prompt-a-toplevel.txt` | one **top-level** Bash tool, 70.265 s | **2 `in_progress` frames**, at allow+30.008 s and allow+60.011 s |
| `acp-run-b-longtool-subagent.jsonl` | `drivers/prompt-b-subagent.txt` | the identical command **nested inside a `Task` subagent**, 70.297 s | **0 frames.** 70.292 s with nothing on the wire at all |
| `acp-run-c-longtool-subagent-repeat.jsonl` | `drivers/prompt-b-subagent.txt` | run B repeated, 70.280 s | **0 frames.** 70.252 s of silence — the negative reproduces |
| `acp-run-d-longtool-toplevel-repeat.jsonl` | `drivers/prompt-a-toplevel.txt` | run A repeated, 70.252 s | **2 frames**, allow+30.008 s and allow+60.008 s — the positive reproduces |

Runs A and B are a controlled pair whose only variable is nesting: 70.265 s against 70.297 s,
**32 ms apart.**

`.timings.tsv` (offset, direction, kind, `toolCallId`, `status`) and every number in the table
are regenerated from the JSONL by `drivers/analyse.py`; nothing is hand-transcribed.
`.summary.json` is `probe-machinery.js`'s own summary, written by the probe itself.

The summary is `../findings.md`, and it cites these files by run and line.
