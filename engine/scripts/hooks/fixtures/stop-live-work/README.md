# What a PreToolUse hook can actually see — the captured evidence

`pretooluse-payload-probe.json` is a **real** `PreToolUse` payload, captured on
2026-09-10 from a live one-shot `claude -p` session with a probe hook wired to
the `Bash` matcher. It is here because two facts about it decide the entire
shape of `guard-stop-live-work.sh`, and neither is guessable from the docs.

Read the `tail` array in it. At the moment the hook fired:

| | |
|---|---|
| the transcript | **readable**, 23 lines |
| the user's message | **present** (line 11 of that transcript) |
| this turn's assistant text | **absent** — written at line 25, *after* the hook returned |
| the `tool_use` itself | **absent** — line 26 |

So a `PreToolUse` hook can answer *"did the user actually say it?"* and can
**never** read one word of the orchestrator's reasoning for the call it is
about to make. Combined with `TaskStop` carrying a single `task_id` key and no
free text (measured across all 100 real `TaskStop` calls on this machine), that
is why the ack for a stop is a **command that writes a file**
(`scripts/stop-work-ack.sh`) rather than a marker line like `resume-ack:` or
`model-ceiling-ack:`, which ride inside tools that have a text field.

The payload key set is also captured, and is the reason the guard reads
`cwd` to recognize a teammate stopping itself:

```
cwd, hook_event_name, permission_mode, prompt_id,
session_id, tool_input, tool_name, tool_use_id, transcript_path
```

**This is captured evidence, not a test fixture.** Nothing loads it. It is kept
so that the next person to doubt the claim in the module header can check the
claim instead of re-running the experiment — and so that if a future harness
changes what a hook can see, the difference is visible against a dated
baseline rather than argued from memory.
