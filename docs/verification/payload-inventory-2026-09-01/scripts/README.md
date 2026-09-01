# These are the scripts as they were RUN, not as they would be tidied

Every file here is committed byte-for-byte as it was executed on 2026-09-01, including its
absolute paths. That is deliberate: a tidied-up script is a different script from the one
that produced the numbers, and the point of this directory is that the numbers can be
reproduced rather than believed.

Two paths are baked in and must be substituted to re-run anywhere else:

| baked-in path | what it is |
|---|---|
| `/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-.../scratchpad` | the scratch directory (`SCRATCH`) — any writable directory works |
| `/Users/alex/ab/richos/.worktrees/echo-opus-p1` | the worktree the bundle was built in |

Order of execution, and what each one answers, is in `../README.md` §9.

Nothing here installs anything. `measure-installer.sh` downloads 261 MB of Anthropic release
artifacts into `SCRATCH` and never touches `~/.local/share/claude`.
