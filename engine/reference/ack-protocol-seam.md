<!-- ACK-PROTOCOL-SEAM:BEGIN — canonical text. Installed by scripts/install-ack-protocol.sh.
     Everything between the BEGIN and END markers is byte-identical in every teammate
     definition; edit it HERE and re-run the installer, never in a definition. -->

## Acknowledging a Correction — Your Ack Protocol

The lead may message you mid-task to say `main` moved under you, or that a fact you were
given has changed. **Your worktree is a snapshot — nothing else will tell you.** When that
message arrives the lead needs proof you hold the new fact, and it cannot use your reply as
that proof: the mailbox drops roughly half of what crosses it, and a reply the lead never
receives proves nothing to the lead. This is the mirror of escalation above and NOT the same
problem — escalation is you → lead, unprompted; acknowledgement is lead → you → an artifact
the lead can `stat`.

**Run one command. It records your acknowledgement where your worktree cannot take it with
it.**

```
~/.claude/richos-engine/scripts/inflight-ack.sh --sha <sha> --impact <kind> \
    --detail "<your own words>" --paths "<paths or none>"
```

**It writes to TWO places, and only one of them survives you.** The record that counts is an
append-only row in `~/.claude/state/inflight-acks.jsonl` — outside every repository, every
worktree and every session, the same substrate the escalation ledger and the worktree
ownership ledger use. The second is a readable copy in your own worktree, which is a
convenience and never the evidence:

```
<your worktree>/.claude/inflight-acks/<first-12-characters-of-the-sha>.<your name>.ack
```

**Until 2026-09-05 there was only the second one, and it was deleted the moment you
finished.** Both governed repositories gitignore `.claude/*`, so an ack is an untracked write;
the harness auto-cleans an isolation worktree that is UNCHANGED at completion; and a
gitignored write does not make a tree changed. So an agent whose only writes were acks had its
worktree, and every ack in it, removed on completion. One teammate wrote three acks, reported
them by path, and named the ignore rule itself in its handoff — all three are gone. Another
found this command REFUSING its next ack with "worktree does not exist", so it could not
answer at all. **An ack that was written, confirmed and then deleted reads at the timeout
exactly like an ack that was never written, and the operator is sent to chase somebody who
already complied.**

**So do not hand-write the file.** The format is still the contract for READING an ack, but a
file on its own is no longer an acknowledgement — it is an acknowledgement that is about to be
deleted. If the helper is genuinely unavailable, append the durable row yourself, one JSON
object on one line, to `~/.claude/state/inflight-acks.jsonl`:

```
{"timestamp":"<UTC ISO-8601>","event":"InflightAck","sha":"<full 40-char sha>",
 "impact":"<kind>","detail":"<your own words>","paths":"<paths or none>",
 "teammate":"<your name>","worktree":"<your worktree path>","repo":"<main checkout path>"}
```

**If the command exits non-zero, YOUR ACK WAS NOT RECORDED.** It says so rather than leaving
you with a file in a tree that is about to be removed. Put that verbatim in your handoff.

**Your name is in the filename and in the row, and it is there for a reason that cost real
evidence.** The
key used to be the sha alone. Two teammates acknowledging the same land — which is correct,
both were told and both answered — then wrote two different files at one path, and the merge
was an add/add conflict; a lander in a hurry resolves that with `--ours` and the proof that
one of them answered is gone without a trace. An ack is per-teammate-per-sha. Use your
worktree's directory name if you have nothing better.

Five lines, exactly these keys:

```
sha: <the FULL 40-character commit the lead named>
impact: conflict | stale-record | grew-scope | none
detail: <at least 40 characters, in your own words, naming which of YOUR assumptions this breaks>
paths: <space-separated repo-relative paths this lands on, or the word none>
teammate: <your name — the same one the filename carries>
```

`impact` forces a judgment where "got it" forces none. **conflict** — it touched files I have
also changed, so I will hit a merge conflict I can avoid now. **stale-record** — a record I
was told to READ changed after my worktree was cut, so my copy is wrong. **grew-scope** — the
thing I am consuming got bigger, so work sized at spawn time would ship incomplete. **none** —
I have read it and it does not affect me. Every path in `paths` must really exist in your
worktree or in what moved; it is the one field that cannot be filled by copying the message
back, which is exactly why it is there.

**Be honest in `detail`.** A machine checks that the file exists, that `sha` matches the
commit exactly, that `impact` is one of the four, that `detail` is long enough, and that
`paths` are real. **No machine checks whether what you wrote is TRUE** — the lead reads that
line itself, under the words HUMAN JUDGMENT REQUIRED. An ack that passes the shape check and
says nothing true is worse than no ack at all: it converts a known unknown into a false green.

**Then carry on.** Acknowledging costs you one command. It does not pause your work, it does
not need a reply from anyone, and — now that the record lives outside your worktree — it is
still there after the session that messaged you has ended AND after your own workspace has
been cleaned up.

<!-- ACK-PROTOCOL-SEAM:END -->
