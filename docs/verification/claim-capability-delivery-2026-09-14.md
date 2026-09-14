# Ship it, on three of the four candidate surfaces, because the hook speaks 14 times in two months and one of those times cost an escalation

**Author:** Zach (infrastructure). **Date:** 2026-09-14.
**Brief:** deliver the existing claim-capability check when a RECORD is written, non-blocking.
Evaluate the author's `PostToolUse[Write|Edit]` recommendation rather than implementing it on
sight. Decide which paths count as a record. Set a kill criterion. **And if my own measurement
says this becomes wallpaper, say so and build nothing.**

**It does not become wallpaper, and it is not close.** Replayed against every recorded write
on this machine the hook speaks **14 times in 1035 calls**. The honest risk runs the other way
and is stated in §6.

Shipped: `engine/scripts/hooks/notice-claim-capability.sh`, registered
PostToolUse[`Bash|Write|Edit|MultiEdit|NotebookEdit`].

---

## 1. Two premises in the brief, checked before anything was built

Both came from the source record, correctly marked as relayed. One survives; one does not.

| premise | verdict | how |
|---|---|---|
| "none of the four instances happened in a spawn brief; two in landed records, one in a memory file, one in chat" | **TRUE, and load-bearing** | the four sentences located in their real files; §5 of the source record |
| the author's recommendation — wire it as `PostToolUse[Write\|Edit]` on `docs/verification/**.md` | **WOULD HAVE BEEN NEARLY INERT** | across 753 transcripts there are **4** `Write`/`Edit` calls to a `docs/verification/*.md` file, against **34** write-shaped `Bash` calls. Records are written with heredocs |

The second correction matters more than it looks. **`Write|Edit` alone would have reproduced the
exact defect the brief exists to fix** — a check wired to a surface where the thing does not
happen — one level down, inside its own remedy. Agents in this project are told, in their own
system prompt, to prefer Bash for file changes. So the matcher includes `Bash`, and the hook
reads the heredoc body out of the command string.

The measurement, re-runnable:

```
$ python3 - <<'PY'   # over ~/.claude/projects/*/*.jsonl, 753 transcripts
... count tool_use entries whose file_path or command names docs/verification/*.md ...
PY
Write/Edit to docs/verification/*.md: 4 calls over 1 distinct record
Bash calls touching docs/verification/: write-shaped 34, read-only 455
```

---

## 2. Which paths count as a record — chosen on rates, and one surface is refused

`brief-provenance.py --json`, check-4 rows only, over every document in each candidate corpus:

| corpus | documents | check-4 rows | per document | documents with ≥1 row | in? |
|---|---|---|---|---|---|
| `richos docs/verification/*.md` | 64 | 38 | 0.59 | 25 (39%) | **yes** |
| `richos-hq docs/verification/*.md` | 19 | 15 | 0.79 | 5 (26%) | **yes** |
| `richos-hq wiki/*.md` | 38 | 25 | 0.66 | 7 (18%) | **yes** |
| `~/.claude/projects/*/memory/*.md` | 252 | 10 | 0.04 | 9 (4%) | **yes** |
| `RICH-TODOs.md`, `CEO-TODOs.md` | 2 | 4 | **2.00** | 1 | **NO** |

**The TODO pages are refused, and the reason is a property of the page rather than a
preference.** Their whole purpose is to record what is awaited by a person — and rule A1 of
the check holds "awaited" to be *universally* unestablishable by any command. So the page is
flagged every time it is written, forever, over rows that are right about the WORDS and wrong
about the DOCUMENT. In the recorded history, eight writes to `RICH-TODOs.md` account for 32
emissions — more than the other three surfaces put together. That is the wallpaper this brief
forbids, arriving from one file. `D10` of the suite pins the exclusion, because an exclusion
no test pins is one that drifts back in.

**Memory files are kept despite scoring the same 0.04 rows per document that the brief uses to
call the spawn surface "nearly inert", and the difference is precision, not rate.** Of the ten
memory rows, four are true and three arguable by the rubric below — the best of any corpus —
and two of them are the *exact* "WAITING ON THE CEO" shape that was instance 1.

**And instance 1 is the honest limit of that.** In the file where it actually happened,
`project_restart_2026-09-13_late.md`, the sentence carries **no cited command at all**, so
check 4 is silent on it and check 3 catches it instead (`count(79, 8) — nothing in scope
sources it`). The source record says check 4 catches all four *with their real commands*, which
is true and is not the same claim. **This hook would not have caught instance 1 as it was
written.**

Out by construction: source files (the check reads prose), `/fixtures/`, `*.corpus.md` — a
corpus file asserts known-bad sentences on purpose, and flagging it is the check reporting its
own test data as a finding.

---

## 3. Check 4 ONLY, and this is the decision that keeps it readable

The obvious implementation delivers `brief-provenance.py`'s report. Measured on the same
corpora, checks 1-3 emit **1633 rows over 64 records — 25.5 per record**, against check 4's
0.59.

**Delivering the report would bury the eight true capability rows under sixteen hundred
others**, which is wallpaper by arithmetic rather than by judgment. So the hook calls
`check_capability` directly. On the six largest documents in the corpus the row set is
byte-identical to filtering `review()`, and the direct call is 2-4x faster (0.03 s on a 160 KB
page).

---

## 4. What a reader actually pays, measured by replaying the hook itself

Not a model of the hook — **the shipped file**, fed the rebuilt payload of every write-shaped
tool call in 753 transcripts that names a record path.

```
1035 calls replayed
  14 (1.4%) produced a notice, carrying 15 rows in total
1021 silent, and the four reasons are separated rather than pooled:
     500  the file no longer exists at that path   <- A REPLAY ARTIFACT, not the hook
     296  the file has no capability rows at all
     168  the file HAS rows and this call wrote none of them   <- the narrowing working
      57  the path shape did not resolve
excluding the replay artifact: 535 live calls, 14 notices = 2.6%
```

**The 500 are called an artifact rather than a success.** Those calls wrote into worktrees that
were later removed; in production every one of them would have been live. Reporting 98.6%
silent without that line would be this record claiming credit for its own missing test data.

**So the answer is an interval and not a point.** The artifact class is biased toward *first
full writes*, which are the likeliest to fire. The upper bound comes from the other side: the
four corpora hold **88 rows today**, and every one was introduced by at least one write, so no
more than 88 notices could have been produced over the same period. **Between 15 and 88
notices across two months and 753 sessions.** I cannot narrow it further from here and have not
pretended to.

### The narrowing that earns the 168

The hook re-scans the whole file, so a flagged record edited K times would cost K copies of its
rows. The fix is not a dedupe ledger — it is a narrower and more correct question: **does the
flagged sentence appear in the text THIS call wrote?** A row about a paragraph the author did
not touch is not about this write. It is stateless, and it makes reads silent for free:
`sed -n '1,40p' record.md` and `git add record.md` name the path and write no sentence.

`D5` is the case that decides this whole mechanism and `written-filter-dropped` is the mutant
that proves it load-bearing.

---

## 5. The false-positive rate, re-derived rather than relayed

The brief gave 62% (23 of 37) and told me to weigh it. **I re-classified by hand against the
author's own rubric** — a row is a TRUE POSITIVE when the sentence reports that something
happened, was authorized, or is awaited by a person, and the cited source is a state
measurement.

| corpus | rows | true | arguable | **false** | FP rate |
|---|---|---|---|---|---|
| `richos docs/verification` | 38 | 11 | 5 | 22 | 58% |
| `richos-hq docs/verification` | 15 | 6 | 2 | 7 | 47% |
| `richos-hq wiki` | 25 | 6 | 2 | 17 | 68% |
| `memory/*.md` | 10 | 4 | 3 | 3 | 30% |
| **the shipped surface, total** | **88** | **27** | **12** | **49** | **56%** |

**The 62% reproduces.** On the author's own corpus I get 22 of 38 against his 23 of 37 — one
document newer, one row apart, which is classifier noise and not a finding. **The surface I
chose does not move the rate; it moves the DENOMINATOR**, and the denominator is the whole
argument: 88 rows in total across the entire recorded history of four corpora.

**The explanatory finding, which the pooled number hides:** precision tracks what a document IS,
not which directory it sits in. *Status* prose classifies at 30% false; *specification* prose —
the wiki's doctrine pages, `worktree-lifecycle.md` alone contributing 11 rows — classifies at
68%. The dominant false class everywhere is mention-versus-use and spec-versus-report, exactly
as the source record says, and it is not decidable by a program. I did not tune it; the brief
forbids that and I agree with the brief.

---

## 6. The kill criterion, set BEFORE shipping, with the command that evaluates it

The thing that would kill this is not the false-positive rate. It is **frequency**, because a
notice a reader learns to skip takes the true rows with it.

> **It dies if a replay over the then-current transcripts shows the notice firing on more than
> 10% of LIVE record-naming calls** (live = excluding the missing-file artifact class), **or if
> a hand classification of the rows produced on newly written records puts the true-plus-arguable
> share below 1 in 5.**

Today those read **2.6%** and **39 of 88 = 44%**, so there is roughly a fourfold margin on the
first and a doubling of noise available on the second. Re-evaluate at 60 days.

The second half of the criterion carries its own honesty problem and it is named rather than
buried: **classification is done by hand, so whoever re-runs it can grade its own homework.**
The mitigation is that the rubric is the author's, not mine, and §5 shows it reproducing across
two independent classifiers to within one row.

The replay, so the criterion is executable rather than aspirational:

```python
# for every write-shaped tool_use in ~/.claude/projects/*/*.jsonl naming a record path,
# rebuild the PostToolUse payload and run the hook itself
payload = {"session_id": "replay", "cwd": cwd, "hook_event_name": "PostToolUse",
           "tool_name": name, "tool_input": inp,
           "tool_response": {"stdout": "", "stderr": "", "interrupted": False}}
p = subprocess.run(["bash", HOOK], input=json.dumps(payload), capture_output=True, text=True)
ctx = (json.loads(p.stdout).get("hookSpecificOutput") or {}).get("additionalContext", "")
rows = len([l for l in ctx.split("\n") if l.strip().startswith("[capability]")])
```

---

## 7. The channel — the one place where following the precedent would have been wrong

The rows are useless unless they reach somebody who can act, and the person who can act is the
**author**, in the seconds after writing the sentence. Not the operator: a notice that is 56%
false, arriving at the CEO, is noise at the most expensive possible address.

The engine's other PostToolUse reporter, `detect-nonnative-worktree.sh`, reports on **stderr
with exit 2**, and this hook did the same for its first hour. The engine also carries a
*measured* channel table (`scripts/lib/stop-hook-notice.sh`) — but it measures **Stop** hooks
against the **operator's** stream, which is neither my event nor my reader. **So the precedent
was an assumption wearing a citation.**

Measured instead. Two headless sessions, each registering one `PostToolUse[Write]` hook
emitting a unique marker on a different channel, the model asked to quote back verbatim
whatever a hook returned to it:

| channel | reaches the author? | how the host frames it |
|---|---|---|
| `stderr`, exit 2 | **yes**, verbatim | `PostToolUse:Write hook` **`blocking error`** `from command: ... ZACHCHANNEL_STDERR_EXIT2_QX71` |
| `hookSpecificOutput.additionalContext`, exit 0 | **yes**, verbatim | `ZACHCHANNEL_ADDCTX_EXIT0_QX72` — the text, and nothing else |

**Both work, so the choice is made entirely by the second column.** A notice whose first
sentence is *"Nothing failed and nothing is blocked; the write succeeded"*, arriving under a
host banner that says BLOCKING ERROR, is a mechanism arguing with itself — and the reader
believes the banner. It exits 0 on every path and speaks through `additionalContext` with
`suppressOutput`.

**A finding for somebody else, reported and not fixed:** `detect-nonnative-worktree.sh`'s
report is announced to its reader as a blocking error over a tool call that already succeeded.
That is not my hook and the brief scopes me out of it.

---

## 8. What a person actually sees

A record written with the known-bad sentence from instance 3:

```
Claim-capability check on the record you just wrote. Nothing failed and nothing is blocked;
the write succeeded.

1 sentence you just wrote cites a source that does NOT establish what it says:

  …/docs/verification/branch-state.md
    [capability] All but one of the codex branches are fully merged into main.
                 `git -C /Users/alex/ab/richos branch --no-merged main --list 'codex/*'`
                 establishes which branch tips are reachable from a ref at this instant. It
                 cannot establish that any operation was performed — and the sentence asserts
                 an act - something having been done.

[the capability lead, verbatim from brief-provenance.py — "What is in question is the WORD,
 not the measurement" — imported rather than re-typed, so a future edit to it propagates]

This is a DISCLOSURE, not a verdict: the first half of each row is a fact about the command,
and the check never judges your sentence. It is also often unnecessary: of 88 rows
hand-classified across these surfaces, 49 were sentences that turn out to be fine. …
```

**The measured false-positive rate is printed in the notice itself.** A reader who knows the
prior reads the row as a prompt to check rather than as an accusation, which is the only way a
56%-false disclosure survives contact with a busy author.

Silent, same hook, same session: a record whose sourced sentence makes no capability claim; a
`.sh` file containing the identical sentence; `sed -n '1,40p'` of the flagged record. Exit 0,
empty stdout, empty stderr in all three.

Load-bearing: the same write against a scratch engine with `check_capability` reverted to
`return []` produces **nothing at all**.

---

## 9. Defects I introduced and then found, recorded because they are the interesting part

| defect | what it did | how it was caught |
|---|---|---|
| the surface list was written **twice** — the bash fast-path grep and the python resolver | widening the python copy left the grep narrow, so `RICH-TODOs.md` was still excluded for the wrong reason. **Two copies of one predicate, inside a hook whose entire job is to deliver a check rather than re-implement it** | the `surface-widened` mutant SURVIVED on the harness's first run. Nothing else would have found it — the suite was green |
| the hook reported on the blocking channel | its own first sentence was contradicted by the host's banner | measured, §7. Believed on precedent for an hour |
| the first figures came from a **model** of the hook rather than the hook | close, and not the same thing: the model predicted 28-57 emissions, the hook produces 15 | replaced by running the real file, §4 |
| the first draft of §4 said "90% silent" | pooling a replay artifact with a real silence, which is one counter over two opposite classes — **the exact shape of the defect in §7 of the source record** | separated into four reasons before it was written down |

The last one is the one to keep, and it is the reason §7 of the source record was read first.

---

## 10. Verification

| check | result |
|---|---|
| `scripts/hooks/notice-claim-capability.test.sh` | **14 passed, 0 failed** — six of the fourteen are negatives |
| `scripts/hooks/claim-capability-delivery.mutation.sh` | **8 mutants, 8 killed**, control green first; runs FROM the suite it mutates so it cannot go unrun |
| `scripts/hook-registration-completeness.sh --explain` | **COMPLETE**, exit 0 — all three derived inventories, `R_ROOTED_HOOKS` correctly absent |
| `contract-integrity.test.sh --only base,M,manifest` | **28 passed, 0 failed, exit 3** (scoped-and-green, not a full pass). `SC1` confirms the new hook starts in a sandbox |
| `scripts/hooks/engine-status.test.sh` | 18/18 |
| `scripts/hooks/by-reference.test.sh` | 49/49 |
| `scripts/hooks/session-evidence.test.sh` | pass, 7 negative controls |
| `scripts/hook-registration-completeness.test.sh` | 34 passed, 0 failed |
| the four known instances | 4 of 4 flagged when each is written; `D2` |
| the hook run against THIS FILE, as a full heredoc write | **silent** — and a silence is not a certificate. It means the check had nothing to say about the sentences here, not that they are true. §5 puts its false-negative class in writing |

**Not run:** the full `contract-integrity.test.sh`. The brief scopes me to `--only`; Rich runs
the full pass at land. **For the land:** the `.sha256` sidecars are gitignored, so BR4 stays red
after the merge until `engine/scripts/hooks/install.sh` is re-run.

**Hooks snapshot at session start, so this is inert until the next session.** It cannot be
demonstrated firing inside the session that wrote it, which is why every demonstration in §8 is
the hook invoked with the payload the host would have given it.
