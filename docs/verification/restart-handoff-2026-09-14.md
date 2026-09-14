# Type U: can the restart handoff be made to carry measurements rather than recollections?

**Question asked:** the note a session writes for the next one was typed from recollection, the
next session could trust none of it, and the CEO waited 158 seconds for a lookup. The rule that
would have prevented it already exists in `CLAUDE.md` and was broken by its own author. So the
deliverable is a MECHANISM, or an argued finding that no sound one exists.

**Answer, in one line:** *yes, and not by checking what was written — by MEASURING it, because
unlike an agent brief a restart note's facts are a closed set with one fast command behind each,
and because the defect that caused this was a wrong LABEL on a right number, which only a
generated row makes impossible.* Built: `engine/scripts/handoff-facts.py`, fired automatically by
`engine/scripts/hooks/handoff-facts-annotate.sh` (PostToolUse) so nothing depends on anyone
remembering.

**Two premises this work was given turned out to be false, and both are re-derived below with the
commands.** One of them is in the failure record itself and should be corrected there: §6.

---

## 1. What was re-derived, before anything was designed

The assignment supplied two figures and told me to re-derive them rather than trust them. Doing so
changed the design.

### 1a. Docker — the note's figure was never produced by any command

| moment | reclaimable | where it comes from |
|---|---|---|
| 2026-09-13 **21:34:51Z** | **34.3 GB** | `docker system df` in the writing session — the session said "roughly 34 GB" |
| between 21:36 and 22:15 | — | `zach-opus-reap1` reaped containers: 30 containers / 7.04 GB → 26 / 1.40 GB |
| 2026-09-13 **22:15:41Z** | *"32.6 GB"* | first appearance, **in prose**; no command in any transcript produced it |
| 2026-09-13 **22:58:28Z** | *"~32.6 GB"* | the note is written, carrying the same figure |
| 2026-09-13 **23:02:28Z** | **28.2 GB** | `docker system df` in the next session |
| 2026-09-14 **00:49Z** | **28.2 GB** | reproduced here |

Reproduce the two live ones with `docker system df` and sum the RECLAIMABLE column across all four
rows — the tool never totals it for you, which is part of why a remembered total drifts. The
sweep for the origin of the figure:

```
grep -c 'RECLAIMABLE' ~/.claude/projects/-Users-alex-ab-femcboost/*.jsonl   # by timestamp
```

**Exhibit 1 of type U stands, and harder than recorded.** 32.6 GB was not a stale measurement; it
was arithmetic on a pre-reap number, written as an established fact. A command at the write would
have produced 28.2.

### 1b. Escalations — the note's number was RIGHT, and the published correction is a third quantity

The note said: *"79 teammate escalations outstanding, oldest 8 days, explicitly waiting on him."*
The failure record corrects this to *"exactly 10 carry `for=ceo`"*. The assignment repeats it.

The ledger is append-only with timestamps, so the state at the instant the note was written is
reconstructible exactly. Replayed through `escalations.py` — the engine's own `outstanding()`,
not a second implementation — to `2026-09-13T22:58:28Z`, which is when the `cat > …` heredoc that
wrote the note actually ran:

```
outstanding: 85     by audience: {'lead': 79, 'ceo': 6}     oldest: 8.4 days
```

| | |
|---|---|
| the note's "79 … outstanding, oldest 8 days" | **exactly right** — 79 is the count addressed to the LEAD, and the age is right too |
| the note's "explicitly waiting on him" | **wrong** — 6 were his; 79 were Rich's own |
| the record's correction, "exactly 10 carry `for=ceo`" | **a different quantity again** — 10 is a count of RAW LEDGER ROWS ever addressed to the CEO, including the 4 since acknowledged. Outstanding is 6. |

Reproduce:

```
python3 - <<'PY'
import sys, collections; sys.path.insert(0, 'engine/scripts/lib')
import escalations as E
rows, _ = E.read_rows()
T = E.parse_iso('2026-09-13T22:58:28Z')
def t(r):
    for k in ('raised','acked','ts'):
        if r.get(k): return E.parse_iso(r[k])
asof = [r for r in rows if t(r) is None or t(r) <= T]
out = E.outstanding(asof, now=T)
print(len(out), collections.Counter(e.get('for') for e in out))
PY
```

**This is the most important finding in this document, and it is not about docker.** The mechanism
that produced the correction is the one the correction was written to condemn: one fast read of a
file, a number lifted out of it, written down as settled. Counting rows in a ledger is not the same
question as counting what is outstanding, and the difference is four acknowledgements.

**It also decides the design.** A mechanism that re-ran the numbers in that note would have printed
79, found 79, and CONFIRMED the sentence that was false.

---

## 2. The three shapes, and why only one survives

### Rejected: CHECKED after writing, the way `brief-provenance.py` checks a brief

`brief-provenance.py` labels the statements in an agent brief that carry no source, in the artifact
the agent receives. Its record argues the shape well and its reasoning holds — for a brief. Pointed
at this genre it fails two ways, both measured.

**a. It does not separate the defective note from the sound ones.** Run over all fifteen
session-handoff notes in the operator's memory directory:

```
for f in ~/.claude/projects/-Users-alex-ab-femcboost/memory/*restart*.md; do
    python3 engine/scripts/brief-provenance.py "$f" --repo ~/ab/richos | head -1
done
```

Findings per note: **47, 22, 12, 11, 11, 11, 9, 8, 8, 8, 5, 3, 3, 2, 2.** The defective note is the
**9**, seventh of fifteen; **six sound notes carry more findings than it does**. That is not a
misconfiguration to tune. A brief is mostly instruction with a few claims in it; a handoff is
nothing but dense claims by genre, so "this sentence carries a count and no command" describes
every sentence in every one of them. At 8–12 rows a note the annotation is wallpaper, which is the
dilution death `brief-provenance`'s own record names as its only real failure mode.

**b. Decisively, re-running the numbers would have confirmed the false sentence** (§1b). The
laundered thing was not the number. It was the audience attached to it.

### Rejected on its own: GENERATED, and nothing else

Generation answers the facts. It says nothing about the half of a restart note that is its actual
content — what he said, what is his to decide, what must not be reported as done, what is
unfinished. That half has no command behind it and never will.

### Adopted: GENERATE the closed set, and CHECK ONLY WHAT A COMMAND CAN SETTLE

The three objections that killed executing commands at spawn time for a brief were examined one by
one, because a prescription inherited from a sibling problem is a hypothesis, not a constraint.

| objection, from `docs/verification/brief-provenance-2026-09-14.md` §1 | does it apply here? |
|---|---|
| **(a) unbounded latency** — spawn cost becomes the sum of whatever commands the brief cites | **No.** A brief can cite anything. This set is fixed and small; the whole run is **0.87 s** measured, and it happens once at the end of a session rather than in front of a waiting spawn. |
| **(b) most evidence is not a command** — a quote, a screenshot, an earlier observation | **Yes, for the prose half** — which is why the prose is not generated, only the facts are. |
| **(c) a re-run answers what is true NOW, not the historical claim** | **Inverted.** At the moment a handoff is written, NOW *is* the claim. This objection is the argument FOR measuring at the write, and it is also why the check half refuses to issue a verdict on a volatile fact after the fact (§4). |

**The set is closed, and that is a measurement rather than a design choice.** Across the fifteen
notes, **15 of 15** carry a repository-state claim and at least one commit SHA
(`grep -oE '\`[0-9a-f]{7,40}\`' <note> | wc -l` is non-zero for every one). Escalation counts,
Docker, and agent liveness account for the rest of the machine-derivable content — including both
figures that failed.

---

## 3. What was built

**`engine/scripts/handoff-facts.py`.** Two modes, and the first one is the answer:

**`--emit` — the measured block.** One row per fact, each carrying the command that produced it and
its value, under a timestamp. Nothing is silently omitted: a fact that cannot be measured on this
machine emits a row saying `UNMEASURED` and names the command, because a missing row reads as
"nothing to report". Measured live:

```
| fact | measured | command |
|---|---|---|
| `richos` tip | `4018cc78` on `main`, clean, in sync with origin | git -C ~/ab/richos rev-parse --short=8 HEAD && … |
| `femcboost` tip | `53fae74c` on `main`, clean, in sync with origin | …
| escalations outstanding | 88 — 82 `for=lead`, 6 `for=ceo`; oldest 8.5 days | escalate.sh list |
| docker reclaimable | 28.2 GB | docker system df |
| agents alive | no agent worktrees registered. (entity: …/sage-opus-y1/engine) | agent-liveness.sh |
```

Two properties of that block are load-bearing:

- **A generated row cannot mislabel its own number.** The escalation row says `79 for=lead, 6
  for=ceo` because that is what the split is; there is no step at which a human decides which of
  them is "waiting on him". This is the defect from §1b, made unreachable rather than detected.
- **The agent row discloses WHERE it asked.** The registry is per-checkout, so the same command run
  from a worktree and from the main checkout answer about different sets. The disclosure is the
  protection: a reader can see the question that was asked, instead of inheriting an answer to a
  question they cannot see.

**The escalation row goes through `scripts/lib/escalations.py`**, never a second implementation of
`outstanding()`. A mechanism written to stop a wrong count, carrying its own private definition of
the count, is the defect one level up — which is exactly what §1b caught.

**`--check <note>` — the residue**, for prose that states a fact of a class a command owns. It
issues a verdict only where a verdict is sound after the fact (§4), and it appends its output to
the note as a delimited block, refreshed rather than duplicated on re-run, with the author's words
byte-identical outside the delimiters.

**`engine/scripts/hooks/handoff-facts-annotate.sh`** (PostToolUse, `Bash|Write|Edit|MultiEdit|
NotebookEdit`) is what makes it a mechanism and not a rule. **The defective note was written with a
`cat > … <<'EOF'` heredoc** — verified in the writing session's transcript — so a `Write`-only
matcher would have missed it entirely; both forms are read. The fast path is one `grep` over the
payload, because this is registered against every write-shaped tool and the common answer is "not a
restart note". It never blocks and exits 0 on every path, including when the measurement itself is
broken (case H16).

**It writes into the operator's own memory directory, and that is said plainly rather than buried.**
`~/.claude/projects/<project>/memory/` belongs to the operator. The addition is one delimited,
append-only section; deleting the block is a complete opt-out for that note; nothing else in the
file is touched.

---

## 4. What the check half will not claim, and why that is the point

| class | after the fact | what the tool does |
|---|---|---|
| a commit SHA | **soundly settleable forever** — it exists or it does not | verdict |
| escalation counts | **soundly settleable** — append-only ledger, replayable to any instant | verdict, and this is the one that catches the mislabel |
| docker, tree cleanliness, which agents were alive | **no ledger exists** | says `NOT RE-CHECKABLE` and names why |

A checker that compared today's disk usage against a figure written last night and called the
difference an error would be manufacturing a defect out of two different instants — the same
mistake as counting ledger rows and calling it outstanding. **The classes nothing can settle later
are precisely the classes where being measured at the write is the only thing that ever will be.**
That asymmetry is why `--emit` is the primary mode and `--check` is the smaller half.

---

## 5. Acceptance, on the note that caused this

Reproduce from the `richos` repository root, with the ledger replayed to the instant the note was
actually written:

```
python3 engine/scripts/handoff-facts.py \
    ~/.claude/projects/-Users-alex-ab-femcboost/memory/project_restart_2026-09-13_late.md \
    --as-of 2026-09-13T22:58:28Z --no-agents
```

Output:

```
| escalations outstanding | 85 — 79 `for=lead`, 6 `for=ceo`; oldest 8.4 days | escalate.sh list (replayed to 2026-09-13T22:58:28Z) |
| docker reclaimable      | 28.2 GB                                          | docker system df |

**Prose in this note that the measurements do not support:**

- MISLABELED — "79 teammate escalations outstanding, oldest 8 days, explicitly waiting on him."
  79 is the count addressed to the lead; the count addressed to the CEO is 6. The number is
  right and the audience is not.
- NOT RE-CHECKABLE — "~32.6 GB of reclaimable Docker on his machine."
  disk usage has no ledger, and this note was not written just now. Only a measurement taken
  AT THE WRITE could have settled it.
```

**Both wrong figures are surfaced, and the diagnosis of the first is better than the one in the
failure record.** The second is surfaced as what it honestly is: with `--fresh-seconds` raised so
the note counts as just-written, the same run says `CONTRADICTED — measured 28.2 GB reclaimable`,
and that verdict is only sound at the write, which is the whole argument for `--emit`.

---

## 6. The correction the failure record needs

`richos-hq/docs/verification/lifecycle-failure-record-2026-09-13.md` §10e (type U) tabulates:

> "79 teammate escalations outstanding… waiting on him" → **10** carry `for=ceo`; 125 are addressed
> to the lead; 50 carry no audience field

Those are counts of raw ledger rows. The row count includes 51 `EscalationAck` rows (which carry no
`for` field — that is the "50", off by one) and every acknowledged escalation. The quantity the
note was asserting is *outstanding*, and at the write instant it was **85: 79 lead, 6 CEO**.

**The row belongs in the record either way — the note WAS defective** — but for the opposite
reason from the one printed. The number was right and the audience was invented, which is a
different failure with a different fix, and the fix the printed diagnosis implies (re-run the
count) would not have caught it.

Raised as **`esc-20260914T010738Z-a08adbaa`** rather than edited here: §10e is another team's
record, and a teammate silently correcting the page that indicts him is its own bad shape.

---

## 7. The false-positive rate, measured, with every finding adjudicated

Run `--check` against all fifteen notes, each with the escalation ledger replayed to that note's
own mtime:

| | |
|---|---|
| notes | **15** |
| total findings | **3** |
| notes with any finding | **2** |
| findings adjudicated FALSE | **0 of 3** |

Every one, checked by hand with the command that settles it:

| finding | verdict |
|---|---|
| `project_restart_2026-09-13_late`: MISLABELED, the escalation audience | **TRUE** — §1b |
| `project_restart_2026-09-13_late`: NOT RE-CHECKABLE, the docker figure | **TRUE**, and correctly hedged — §1a shows it was never measured at all |
| `project_richos_v1_restart_2026-08-24`: "11 commits this note attributes to `richos` are not there; they are in `richos-hq`" | **TRUE.** `git -C ~/ab/richos cat-file -e 16c2af5^{commit}` fails; `git -C ~/ab/richos-hq log -1 16c2af5` returns *"Merge hugh/round-0-verdict… 2026-08-25"*. A reader following that note to `richos` finds nothing. |

**Two false positives were found by this measurement and removed rather than reported**, and both
came from running against real notes instead of against cases written by the same imagination that
wrote the check:

1. *"landed by a prospects session; extension HEAD `a333e62`"* was bound to `prospects`, where that
   commit genuinely is not — it is in `li-profile-data-grabber`, which the sentence calls
   "extension". Fixed by distinguishing ATTRIBUTION from MENTION: a repository name counts as an
   attribution only when nothing but connective words separates it from the SHA. Case H8.
2. A bare repository name was being resolved relative to the current directory, so the checker's
   answer depended on where it was invoked from — standing in a teammate worktree, it bound a
   teammate's name to that worktree. Fixed; a bare name now resolves only under the repository
   root.

**And one dilution defect was fixed the same way:** the first version put **thirteen** rows on the
2026-08-24 note, one per commit, for a single event — a history that moved between repositories.
Repeats now collapse to one row naming the count (case H9). **Dilution, not false positives, is how
this mechanism would die**, so the row count per note is the number to watch: 0 on thirteen of
fifteen notes today.

---

## 8. Cost, and the suite

| | |
|---|---|
| full run — 2 repositories, escalations, docker, agent liveness | **0.87 s** (`/usr/bin/time -p`) |
| the hook's fast path on a call that names no restart note | one `grep`; python3 is never started |
| `handoff-facts.test.sh` | **22 passed, 0 failed** |
| mutation probe 1 — escalation check disabled | **4 cases go red** (H1, H1b, H4, H14b) |
| mutation probe 2 — docker sums only its first row | **H2 goes red** |
| `contract-integrity.test.sh --only base`, with the new hook registered | **11 passed, 0 failed, exit 3** — including `SC1.every-registered-hook-starts-in-a-sandbox` and both install/probe rc-0 cases |

**No inventory anywhere was edited to register the hook.** `scripts/lib/registered-hooks.sh` derives
the guard inventory from `hooks/hooks.json`, which is the file the host actually loads; the new hook
appears in it at position 36 of 67 with no second list to maintain. The test suite reaches CI the
same way — `ci-units.sh` discovers `*.test.sh` by `find`, never a typed list.

**`install.sh` must be re-run at land** so the new hook gets its sha256 sidecar; the sidecars are
gitignored, so a merge alone leaves the probe's BR4 layer red until it is.

---

## 9. What this does not do

Stated here, not discovered later.

1. **It cannot tell a true account from a false one.** Nothing textual can. It measures a closed set
   of facts, and it settles claims in that set. Everything else in a restart note it does not touch.
2. **It does nothing about the prose half** — what he said, what is his to decide, what is
   unfinished. That is the note's real content and it is not machine-derivable. Deliberately: the
   generated block's job is to take the facts OUT of the prose so the prose can be what only a
   person can write.
3. **`NOT RE-CHECKABLE` is a real gap, not a hedge.** If a volatile fact was never measured at the
   write, nothing afterwards can settle it. That is the argument for `--emit` and it is also the
   admission that `--check` arrives too late for that class.
4. **It is not blocking and must not become one.** Its whole viability rests on a finding being
   cheap: the cost of a false positive is one re-derivation, and there is no waiver to grant, so the
   `g11`/`g12`/`g13` death has nothing to bite on. Making it blocking would trade that for a waiver
   habit.
5. **It cannot stop a session writing a note at all**, and a handoff that is never written is a
   different failure from one written badly.
6. **The `AGENTS` row is only as good as `agent-liveness.sh` at that moment**, including its
   `INDETERMINATE` verdicts, which it passes through and never collapses.

---

## 10. Recommendation

**Land it, and do not write a rule anywhere.** The rule exists, it is correct, and the note that
caused this was written by its author. What changes is that the facts are now produced by the
machine that is already running when the note is written, at 0.87 s, into the artifact the next
session actually reads.

**Correct §10e of the failure record** (§6 above), because the printed diagnosis implies a fix that
would not have worked.

**A restart note should now carry fewer facts, not more.** With the block generated, the prose has
no reason to restate a tip, a count, or a disk figure — and every restatement is a fresh surface for
exactly the drift this exists to remove. The note that is left is the part worth a person's hand:
what he decided, what is his, what is unfinished, and what must not be reported as done.

**Watch the rows-per-note number, not the false-positive number.** Three findings over fifteen notes
is readable. If a note starts carrying ten, the block is wallpaper and the mechanism is dead without
anyone deciding to kill it. §7's measurement is the baseline to re-run against.
