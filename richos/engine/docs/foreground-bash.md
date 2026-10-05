# Six-second Bash foreground grace

Ordinary CLI subagent Bash commands get a six-second foreground grace by default
through `shell-evidence.sh`. Installed acceptance passed on Claude Code 2.1.289.
Use a directly delivered result immediately. If the host moves the command to
the background, it continues running; use
`python3 ~/.claude/richos-engine/scripts/lib/agent_hold.py wait` with the Bash
tool's timeout set to `600000` before dependent work. The collector returns the
bound task's output and exit status once. Direct results are marked consumed
at the next tool boundary without another collection call.

SDK and other entrypoints retain forced background execution because their
transcripts lack authoritative task metadata for foreground handoffs. Explicit
background requests and pause/resume ownership keep their existing behavior.
Six seconds bounds foreground waiting, while the host's background execution
limits still apply. Set `RICHOS_AGENT_BASH_FOREGROUND=0` to restore forced
background execution for ordinary subagent commands.
