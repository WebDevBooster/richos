<!-- ESCALATION-PROTOCOL-SEAM:BEGIN — canonical text. Installed by scripts/install-escalation-protocol.sh.
     Everything between the BEGIN and END markers is byte-identical in every teammate
     definition; edit it HERE and re-run the installer, never in a definition. -->

**Raise it with ONE command, and it arrives whether or not your branch is ever merged.**

```
~/.claude/richos-engine/scripts/escalate.sh raise \
    --title "<one line naming what this is about>" \
    --state work-complete|proceeding|stopped \
    --question "<the smallest question that would unblock this>" \
    [--for lead|ceo] \
    [--tried "<what you already tried>"] \
    [--meanwhile "<what you are proceeding on>"]
```

Run it from your own worktree. Your name, your branch, your HEAD and your repository are read
off the workspace you are standing in — the fields above are the only ones that are yours.

**`--state` is required, and it is the field that stops your escalation being read as a
stall.** `work-complete` — the work is DONE and this is a record of something the lead must
know. `proceeding` — raised, and you are still working on everything that does not depend on
the answer. `stopped` — the whole task depends on the answer and work has stopped. The
notices the lead sees quote whichever you chose, and only `stopped` is framed as blocking, so
be accurate rather than modest.

**Why this is no longer a file you commit.** On 2026-09-02 two teammates did exactly what the
old protocol said: each wrote `BLOCKED.md` at the root of its worktree and committed it. Both
were RIGHT to. Their escalations were found on 2026-09-04 by a worktree cleanup, because a
file on your branch is read only by whoever merges your branch — and you can never see
whether your branch was merged. `escalate.sh` writes to a ledger outside every repository and
every session, which the lead's session reads at every session start and at every turn end
with nothing merged, and which gets LOUDER at 1h, 24h and 72h until somebody acknowledges it.
Separately, the repository root is nine entries by permanent CEO ruling, so a root
`BLOCKED.md` would be refused at the write today. The command writes its own record file
under `docs/verification/`, which is where that ruling says a block record belongs; commit it
with your work if it wrote one, and nothing at all depends on you doing so.

**The message is now only a doorbell.** A one-line `SendMessage` to `team-lead` naming the id
is welcome and carries nothing. The mailbox drops roughly half of what crosses it, which is
exactly why your escalation no longer depends on it. Do not wait for a reply, do not re-send,
and do not check that it arrived.

**If the command cannot run, IT SAYS SO AND EXITS NON-ZERO** — no engine on this machine, an
unwritable ledger. That is not a formality to skim past: it means your escalation has NOT been
delivered. Put it verbatim in your final report and in your commit message, and say that the
raise failed.

**Then keep working.** Everything that does not depend on the answer still gets done. Never
stall silently, and never invent an answer to a question that belongs to the CEO. If the whole
task depends on the answer, raise it with `--state stopped`, say so in your report, and stop —
a measured "this is blocked and here is why" is a complete outcome, not a failure.

<!-- ESCALATION-PROTOCOL-SEAM:END -->
