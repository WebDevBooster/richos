# Session startup and dispatch recovery

The femcboost terminal session `b8526f54-0b4a-44b9-bf92-aee6a35961dc`
exposed three contradictory interfaces:

1. SessionStart claimed all dispatches were refused until a CEO question was put,
   but guard-ceo-ask-first already supported authorized per-spawn deferral.
2. create-teammate-worktree recommended cwd-only spawns after the lifecycle guard
   had explicitly forbidden them.
3. A new spawn discovered a missing acknowledgement contract, then discovered
   missing native isolation on its next attempt. Readers repeated the first error.

Startup and ceo-asks-status now describe the existing deferral accurately. OPEN
remains exit 1; cancelled questions remain unanswered. No guard exemption is added.
The announcement reminds the lead to read the full queue and check active owners.

Prepare new isolated Agent input with:

```sh
python3 "$HOME/.claude/richos-engine/scripts/prepare-agent-spawn.py" --file '/tmp/task-input.json'
```

The input supplies name, subagent_type and prompt plus other task-specific fields.
The output adds native worktree isolation and a durable acknowledgement instruction.
It preserves task fields, rejects conflicting cwd/isolation modes and refuses resume
requests. It creates no worktree, sends no message and invokes no Agent tool. The
live guards still validate the resulting call. For cross-repository work, first
prepare/register the external worktree and include its cross-repo-worktree prompt
line. Startup and prompt-verification refusals now point to the helper with resolved
engine paths, which also work when Claude is seated in femcboost.

The previous shell-evidence change also omitted its registration from
engine-status.test.sh's acknowledged set. This branch adds that acknowledgement;
the production banner was already deriving the correct fraction from hooks.json.

Validation uses the real prompt verifier on raw and prepared payloads, the existing
CEO ask tests and mutations, worktree creation tests and mutations, engine banner
tests and by-reference plugin tests. The new Python test has a .test.sh entry point
so the repository's discovered suite runner includes it.

The paired ECS branch `codex/ecs-session-start-recovery` fixes host context overflow,
adds visible ECS startup status and provides fenced editable checkpoint requests.
Merge the paired changes, run scripts/hooks/install.sh from the engine main
checkout to refresh its ignored checksum sidecars, then require contract-integrity-probe.sh exit 0 and engine-status.test.sh 16/16
on main. Start a new session to exercise the new SessionStart text; plugin reload
alone is not evidence that SessionStart ran. The
five-record live ECS repair and backed-up memory correction are documented in the
femcboost review `docs/reviews/ecs-startup-recovery-2026-09-06.md`.

Sage review follow-up: retain the imperative CEO-ask instruction and its
2026-08-31 history, then state the logged exception without weakening its default.
Recognize either verifier-accepted acknowledgement form when preparing a spawn.
