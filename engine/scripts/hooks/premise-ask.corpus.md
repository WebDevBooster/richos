# The PREMISE check — the corpus, the rate, and why it does not refuse

The premise check is check 1 of 2 inside `guard-ceo-ruled-ask.sh`, the
PreToolUse gate on `AskUserQuestion`. Its predicate is
`scripts/lib/premise-ask.py`; its argument, scope and escape hatch are
`scripts/lib/premise-ask.sh`.

**This page exists because the obvious build was measured and thrown away.**
The brief asked for a blocking gate: refuse a question to the CEO that does not
carry its premise, and the evidence for it when the premise is a claim about
something that happened. Against the real corpus that gate refuses genuine
business decisions and lets both target questions through. The numbers are
below, and they are the reason the shipped thing interrupts once and blocks
nothing.

---

## The failure being engineered out

2026-09-10. Two questions reached the CEO that could not affect him.

| # | The question | Why it could not affect him |
|---|---|---|
| 1 | *"G0 came back BLOCKED … how do you want to handle the native terminal?"* (07:41), and its reframing *"the decision is what to promise about this terminal"* (07:54) | The blocked capability was a safety net for the orchestrator's own misjudgment, not part of the job |
| 2 | Work surviving him **quitting mid-flight** — called *"the capability the whole thing rests on"*, with a design constraint briefed from it | The scenario was constructed by a probe in a disposable environment. Nothing said he produces it |

He asked how many times he had ever quit while work was running. **Nobody had
looked.** The measurement, run afterwards:

```
grep -oE 'session[_ ]gone' ~/.claude/state/worktree-reconciler.log   -> 0
grep -ciE 'dead pid|locked by dead' ~/.claude/state/worktree-reconciler.log -> 0
```

Zero, over that log's whole history, against 47 femcboost session transcripts.
His closing question was *"When will I stop being bothered by … this nature?"*

**One of the two was an `AskUserQuestion` call. The other was PROSE** — a
sentence in a reply — and no `PreToolUse` event exists for a sentence. Stated
here rather than discovered later: this check would have interrupted the first
and could never have seen the second.

---

## The corpus — every `AskUserQuestion` ever asked on this machine

Extracted from every transcript under `~/.claude/projects`: **2,492 files, 72
calls, 85 questions**, 2026-07-27 to 2026-09-10. Every one is a real question
really put to a person. Each was flattened exactly as the hook flattens it —
header, question, and every option label and description.

### Four blocking predicates, measured, all rejected

| Predicate | Fires | Refuses genuine decisions | Catches the two targets |
|---|---|---|---|
| no declarative premise sentence anywhere | 10/85 (11.8%) | **7** — Q2 guided calls, Q15 purge scope, Q17 gate strength, Q19 entity, Q27 latitude, Q44 his machine, Q60 panel fix (the other 3 are sandbox probe artifacts, not real questions) | **neither** |
| no evidence token anywhere | 32/85 (37.6%) | **29** (same 3 artifacts excluded) | **neither** |
| hypothetical framing without evidence | 21/85 (24.7%) | **19** (1 artifact excluded) | **1 of 2** — Q85 only |
| occurrence claim without observation evidence | 11/85 (12.9%) | **11**, including Q16 the ACP adapter, Q20 the license, Q26 the wordmark font, Q67 worker trust | **neither** |

**The last row is the one that settles it.** It is the narrowest predicate that
expresses the brief's own rule, and it fires on eleven real business decisions
while letting both targets through — because both targets carry observation
words (*"today"*, *"measured"*, a pinned host version).

### Why no text predicate can work here

The two questions that had to be refused are in the **top decile of the corpus
for premise richness**:

| | declarative premise sentences in the question field | evidence tokens |
|---|---|---|
| Q84 "G0 blocked" | 4 | a pinned version `2.1.267`, a measured `six seconds`, four reproduced failure paths |
| Q85 "Terminal promise" | 6 | — |
| corpus median | 1 | — |

They are textually BETTER than the average genuine business decision. What was
wrong with them is not in the text: the premise was true, reproducible, and
irrelevant to him. **A question's text does not carry whether its premise
matters.** Three guards have already died in this project by being shipped
broader than their evidence (`g11`/`g12`/`g13`, all on one day); a gate refusing
11 of 85 real questions to catch neither target would have been the fourth.

---

## What is shipped instead, and what it costs

**One interruption per episode, blocking nothing.** The check prints what the
question does and does not carry, asks the three questions a machine cannot
answer, and stands down: re-issuing — changed or unchanged — goes straight
through.

**The cost, replayed against the real calls** (72 orchestrator calls, worker
calls excluded as the gate excludes them, 46 days):

| stand-down window | checks fired | stood down | busiest single day | interrupts 07:41 |
|---|---|---|---|---|
| 300s | 65 | 7 | 15 | yes |
| 900s | 60 | 12 | 15 | yes |
| **1800s — shipped** | **51** | **21** | **10** | **yes** |
| 3600s | 47 | 25 | 8 | yes |
| 7200s | 39 | 33 | 5 | **no** |

51 interruptions in 46 days — a mean of 1.1 a day, on 16 of those days, on the
rarest tool in the system. The upper bound is measured rather than assumed: at
two hours the question that had to be interrupted collapses behind an unrelated
one asked 74 minutes earlier.

### What the predicate says about each question — findings, not verdicts

| Finding | Rate over the 85 |
|---|---|
| `PREMISE-UNSOURCED` — states a fact, cites nothing for it | 44/85 (51.8%) |
| `PREMISE-ONLY-IN-OPTIONS` — the question asserts nothing; the options do | 20/85 (23.5%) |
| `OCCURRENCE-CLAIMED-WITH-EVIDENCE` — rests on something happening, cites observation | 6/85 (7.1%) |
| `OCCURRENCE-CLAIMED-UNMEASURED` — rests on something happening, cites nothing | 4/85 (4.7%) |
| `NO-PREMISE-ANYWHERE` | 3/85 (3.5%) |
| no finding at all | 14/85 (16.5%) |

**Both targets produce findings.** Q84 → `OCCURRENCE-CLAIMED-WITH-EVIDENCE`;
Q85 → that plus `PREMISE-UNSOURCED`. That finding's text is written for exactly
their case: *check it is observation of the THING* — a pinned version and a
measured latency are not evidence that the failure ever occurs.

**Every one of the genuine business decisions passes.** Not because the
predicate approves of them — it approves of nothing — but because nothing here
refuses. The 14 questions that produce no finding include Q13 (the upstream PR),
Q32/Q33 (the transcription default), Q43 (the app version), Q47 (git history),
Q48 (README drift), Q71 and Q79 — every one a decision whose answer changed what
got built, and every one of them premise-rich enough that the predicate has
nothing to say.

---

## Reproducing the measurement

The corpus is the machine's own transcripts, so it is not vendored here: a
vendored copy would go stale and start reporting a rate that is no longer true.
`scripts/hooks/premise-ask.test.sh` section 5 replays it against the live
transcripts whenever `~/.claude/projects` is on the machine, prints the rates
above, and says plainly when it is not there rather than passing. Sections 1–4
run against a sandbox and are deterministic anywhere.

By hand:

```
# 1. every AskUserQuestion tool_use in every transcript
python3 - <<'PY' > /tmp/asks.jsonl
import json, glob, os
for p in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    for line in open(p, encoding="utf-8", errors="replace"):
        if "AskUserQuestion" not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        for b in (d.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "AskUserQuestion":
                print(json.dumps({"ts": d.get("timestamp",""), "session": d.get("sessionId",""),
                                  "agent_id": d.get("agentId",""), "input": b.get("input", {})}))
PY

# 2. each question, flattened header+question+options, through the predicate
#    scripts/lib/premise-ask.py check  <<< '{"question": "...", "whole": "..."}'
```

---

## What this does NOT do — said here, not in a postmortem

1. **It does not judge, and it never refuses.** The corpus is the reason. If a
   later reader wants a blocking gate, the ledger
   (`.claude/state/premise-ask-ledger.jsonl`) is the evidence base to argue from:
   it records every question, its findings, and whether the re-issue was
   `CHANGED` or `UNCHANGED`. **If re-issuing becomes a reflex, that field is
   where it will show, in numbers.**
2. **It cannot see a question asked in prose**, which is one of the two failures
   it was built for.
3. **It says nothing about a worker's question.** A teammate's clarifying
   question is not the orchestrator putting a decision to the CEO — the same
   line `guard-ceo-ruled-ask.sh`'s other check and `notice-ceo-asks.sh` draw.
4. **A measured lead it deliberately does NOT act on.** Both target questions,
   and ~17 of the 85, are about the machinery — hooks, guards, worktrees, CI,
   suites, the landing. On 2026-09-10 the CEO ruled that plumbing never reaches
   him at all: *"never volunteer a word about landing, suites, CI, guards,
   mutation harnesses or verification again."* A topic filter on that basis
   would have refused both targets. It is not shipped here because it would also
   refuse Q42 (his email address in a public repo), Q68 (his personal
   subscription token) and Q20 (the license) — all plumbing-shaped, all his to
   answer — and separating "a mechanism" from "his money, his name, his
   credential" is judgment rather than grammar. **Recorded as a measurement, not
   built as a guard**, so the next person starts from the number instead of the
   idea.
