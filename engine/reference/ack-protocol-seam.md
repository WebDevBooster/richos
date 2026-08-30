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

**Write a file in your own worktree. That file IS the acknowledgement.**

```
<your worktree>/.claude/inflight-acks/<first-12-characters-of-the-sha>.ack
```

Four lines, exactly these keys:

```
sha: <the FULL 40-character commit the lead named>
impact: conflict | stale-record | grew-scope | none
detail: <at least 40 characters, in your own words, naming which of YOUR assumptions this breaks>
paths: <space-separated repo-relative paths this lands on, or the word none>
```

`impact` forces a judgment where "got it" forces none. **conflict** — it touched files I have
also changed, so I will hit a merge conflict I can avoid now. **stale-record** — a record I
was told to READ changed after my worktree was cut, so my copy is wrong. **grew-scope** — the
thing I am consuming got bigger, so work sized at spawn time would ship incomplete. **none** —
I have read it and it does not affect me. Every path in `paths` must really exist in your
worktree or in what moved; it is the one field that cannot be filled by copying the message
back, which is exactly why it is there.

Write it with any tool you have — it is a plain text file, and the FORMAT is the contract, not
any particular script. If the engine is installed on this machine there is a helper that writes
and validates it for you:

```
~/.claude/richos-engine/scripts/inflight-ack.sh --sha <sha> --impact <kind> \
    --detail "<your own words>" --paths "<paths or none>"
```

**Be honest in `detail`.** A machine checks that the file exists, that `sha` matches the
commit exactly, that `impact` is one of the four, that `detail` is long enough, and that
`paths` are real. **No machine checks whether what you wrote is TRUE** — the lead reads that
line itself, under the words HUMAN JUDGMENT REQUIRED. An ack that passes the shape check and
says nothing true is worse than no ack at all: it converts a known unknown into a false green.

**Then carry on.** Acknowledging costs you one file. It does not pause your work, it does not
need a reply from anyone, and it is still there after the session that messaged you has ended.

<!-- ACK-PROTOCOL-SEAM:END -->
