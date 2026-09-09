# How long agents actually run, and what a land actually costs — measured 2026-09-09

The record said nothing recorded how long an agent runs. The worktree ledger cannot
(13,099 of its 13,570 rows are `finished` events emitted on every `SubagentStop`). But
every subagent transcript under `~/.claude/projects/<project>/<session>/subagents/`
carries a timestamp on every message, and `tool_use`/`tool_result` pairs give the wait on
every command. These scripts read that.

Eight days, 260 agents (`results/agent-active-time.txt`):

```
ACTIVE 195.1 h   suite/poll-wait 84.8 h   => 43 % of all active agent time
active minutes: median 22   p75 67   p90 116   max 368
```

The instrument reproduces the hand-timed record exactly: `zach-opus-ob1` 338 min active
(RICH-TODOs: "5 h 37 m"), `zach-opus-cg1` 181, `zach-opus-rg1` 178 ("181 and 178").

The mechanical land, merge → push, from Rich's own transcripts
(`results/land-cost.txt`): **0.8 min median, 3.0 min p75**, n = 174. Ten of 174 lands had a
full-suite call between merge and push.

Engine PreToolUse[Bash] hooks: **0.76 s per Bash call** for all twelve
(`results/hook-latency.txt`). Guard refusals: 843 in 8 days, median 4 s to recover.

The plan these numbers support: `docs/plans/land-cost-architecture-2026-09-09.md`.

## Tools

| script | reads | writes |
|---|---|---|
| `tools/agent-active-time.py` | subagent transcripts (8 days) + worktree ledger for names | `results/agent-active-time.txt` |
| `tools/land-cost.py` | main-session transcripts | `results/land-cost.txt` |
| `tools/rich-full-passes.py` | main-session transcripts | `results/rich-full-passes.txt` |
| `tools/hook-latency.sh [worktree]` | the installed engine at `~/.claude/richos-engine` | `results/hook-latency.txt` |

`results/scoped-only-python3.log` is the one scoped suite run taken while writing the plan:
`contract-integrity.test.sh --only python3`, exit 3, 1 s.

Caveats: "suite-wait" is a regex over command text; active time treats gaps over 15 minutes as
idle. Both are stated in the plan's Method section and neither moves the headline share by
more than a few points.
