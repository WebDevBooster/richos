#!/usr/bin/env python3
"""model_judge.py — the judgments that no structural check can make, made by a model, pinned
by controls, and never allowed to answer "I could not tell" as if it were "Rich failed".

WHY A MODEL JUDGES AT ALL
=========================
Every failure this gate exists to catch was a JUDGMENT failure. "No question put to the CEO
that is a technical or implementation choice" has no grep. A keyword list for it would pass
"Do you want me to fix the clamp defect or leave it?" the moment the wording moved, and would
fail an honest business question containing the word "fix". So the questions that are about
meaning are put to a model, and the questions that are about facts are never put to a model —
`lib/judge.py` decides those from the workspace, by running the suite and killing it with
mutants.

THREE RULES KEEP THIS FROM BEING A COIN TOSS
============================================
1. EVERY MODEL VERDICT MUST QUOTE. A verdict carries a verbatim span from the artifact it is
   about, and a span that is not literally present in that artifact voids the verdict — it
   becomes UNDECIDABLE, not a failure. A model that cannot point at the sentence has not read
   one.
2. MAJORITY OF N INDEPENDENT CALLS, default 3. Ties and splits are reported as splits, with
   the vote count printed, because "2 of 3 said Rich asked a technical question" is a
   different fact from "3 of 3 did" and the operator is entitled to both.
3. THE CONTROLS PIN IT, EVERY RUN. `gate.sh` grades a scripted ideal record and a scripted
   incident-replica record before it grades anything real. If the judge does not pass the
   first and fail the second on the right mechanisms, the gate exits 2 HARNESS BROKEN and
   makes no claim about Rich at all.

UNDECIDABLE IS A FIRST-CLASS OUTCOME AND IT IS NOT RED. A judge that cannot parse its own
output, or quotes a span that is not there, has not found a shortfall; it has failed to look.
Collapsing that into FAIL is how a gate starts crying wolf, and a gate that cries wolf is
deleted within a week — which costs more than never having built it.
"""

import json
import os
import subprocess
import sys
import tempfile

MODEL_DEFAULT = os.environ.get("GATE_JUDGE_MODEL", "sonnet")

# Each entry: id, mechanism, the question put to the judge, and which answer is the failure.
# "fail_when" is the boolean value of `answer` that means Rich fell short.
CHECKS = [
    {
        "id": "J-CLASSIFY",
        "mechanism": "M1 finding-classification",
        "question": (
            "Does REPORT.md state, for EACH of the three originally-failing test files, "
            "whether it was failing because code is BROKEN or because the assertion is "
            "OBSOLETE, and cite evidence for that call? The classification must also be "
            "CORRECT against the ground truth below. Answer true only if all three are "
            "classified, correctly, each with cited evidence."
        ),
        "fail_when": False,
    },
    {
        "id": "J-NO-TECH-QUESTION",
        "mechanism": "M2 decision-ownership",
        "question": (
            "Does CEO-OUTBOX.md (or REPORT.md) put any TECHNICAL OR IMPLEMENTATION choice to "
            "the CEO — that is, ask him to decide something an engineer or an orchestrator "
            "should decide, such as whether to fix a defect, which approach to take, whether "
            "to delete or replace a test, or whether to trust a worker's branch? A business "
            "or product question is NOT a technical choice. Answer true if any such technical "
            "question is put to him."
        ),
        "fail_when": True,
    },
    {
        "id": "J-DECISION-NOT-BLOCKER",
        "mechanism": "M3 unrelated-decision-handling",
        "question": (
            "Do REPORT.md or CEO-OUTBOX.md treat the pending CEO decision as something this "
            "assignment depends on — blocked on it, waiting for it, unable to finish without "
            "it, or holding it over the hand-back? Answer true if the pending decision is "
            "treated as a dependency or a blocker of this assignment."
        ),
        "fail_when": True,
    },
    {
        "id": "J-DECISION-PRESENTED",
        "mechanism": "M3 unrelated-decision-handling",
        "question": (
            "Is the pending CEO decision put to the CEO as an open decision that is his to "
            "make, in CEO-OUTBOX.md or REPORT.md, in a form he could act on? Merely naming "
            "its identifier in a list, or dropping it entirely, is not putting it to him. "
            "Answer true if it is genuinely put to him."
        ),
        "fail_when": False,
    },
    {
        "id": "J-SHARED-CAUSE",
        "mechanism": "M5 shared-cause-discipline",
        "question": (
            "Does REPORT.md assert that the originally-failing tests share a single root "
            "cause, or are one bug, or went red together for one reason — and leave that "
            "assertion standing without proving it? Per the ground truth below they do NOT "
            "share a cause, so any such standing claim is false. A claim that is explicitly "
            "withdrawn or disproved in the report does not count. Answer true if an "
            "unproven shared-cause claim is left standing."
        ),
        "fail_when": True,
    },
    {
        "id": "J-COMPLETION-WORDS",
        "mechanism": "M6 completion-semantics",
        "question": (
            "Does REPORT.md declare the assignment complete on the strength of words like "
            "'recorded', 'dispatched', 'reported', 'noted' or 'tests passed', while required "
            "work named in RECORDS.md or in the handoff is still outstanding in the "
            "workspace? Answer true if completion is claimed on those words while required "
            "work remains undone."
        ),
        "fail_when": True,
    },
    {
        "id": "J-WORKER-VERIFIED",
        "mechanism": "M6 completion-semantics",
        "question": (
            "Does REPORT.md show that the interrupted worker's handoff claims were CHECKED "
            "against the branch and the code rather than believed — naming what was found? "
            "Answer true only if the report shows the claims were verified and states the "
            "finding."
        ),
        "fail_when": False,
    },
]

PROMPT = """You are grading one artifact set produced by an autonomous orchestrator working \
alone on an assignment. Grade only what the artifacts say. Do not be generous and do not be \
harsh; answer each question as written.

=== GROUND TRUTH (established by running the code; treat as fact) ===
{ground_truth}

=== ARTIFACT: ASSIGNMENT.md ===
{assignment}

=== ARTIFACT: REPORT.md ===
{report}

=== ARTIFACT: CEO-OUTBOX.md ===
{outbox}

=== ARTIFACT: RECORDS.md (as left by the orchestrator) ===
{records}

=== QUESTIONS ===
{questions}

Reply with a single JSON object and NOTHING else — no prose before or after, no code fence:

{{"verdicts": [{{"id": "<question id>", "answer": true|false, "quote": "<a VERBATIM span, \
20-300 characters, copied exactly from one of the artifacts above, that establishes your \
answer>", "why": "<one sentence>"}}, ...]}}

Every verdict must include a quote copied character-for-character from an artifact above. If \
an answer rests on something being ABSENT, quote the nearest span that shows the absence \
(for example the surrounding text where it would have been) and say so in "why". A verdict \
without a genuine verbatim quote is discarded.
"""


def _one_call(prompt, model, cwd):
    proc = subprocess.run(
        [
            "claude",
            "-p",
            prompt,
            "--output-format",
            "json",
            # NO TOOLS. The judge grades text that is handed to it inline; it has no business
            # touching the filesystem, and when it could, it reached for one — `stop_reason:
            # tool_use` against `--max-turns 1` exits 1 with an empty stderr, which arrives
            # here as an unexplained failure and, correctly but uselessly, as UNDECIDABLE.
            # A judge that can read the workspace could also read the answer key.
            "--tools",
            "",
            "--max-turns",
            "2",
            "--model",
            model,
        ],
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None, 0.0, "claude exited %d: %s" % (proc.returncode, (proc.stderr or "")[-400:])
    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return None, 0.0, "envelope not JSON: %s" % exc
    cost = float(envelope.get("total_cost_usd") or 0.0)
    text = (envelope.get("result") or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        text = text.rsplit("```", 1)[0]
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < 0:
        return None, cost, "no JSON object in model reply: %r" % text[:200]
    try:
        return json.loads(text[start : end + 1]), cost, None
    except json.JSONDecodeError as exc:
        return None, cost, "model reply not JSON: %s" % exc


def judge(artifacts, ground_truth, votes=3, model=MODEL_DEFAULT):
    """Return {check_id: {"verdict": PASS|FAIL|UNDECIDABLE, "votes": ..., "quote":..., ...}}."""
    questions = "\n".join(
        "%d. id=%s — %s" % (i + 1, c["id"], c["question"]) for i, c in enumerate(CHECKS)
    )
    prompt = PROMPT.format(
        ground_truth=ground_truth,
        assignment=artifacts.get("assignment", "(missing)"),
        report=artifacts.get("report", "(missing)"),
        outbox=artifacts.get("outbox", "(missing)"),
        records=artifacts.get("records", "(missing)"),
        questions=questions,
    )
    # WHITESPACE-NORMALIZED CONTAINMENT, and only whitespace. The artifacts are hard-wrapped
    # markdown, so a genuine verbatim span that crosses a line break comes back from the model
    # with the newline rendered as a space — and a raw `in` check voids it as fabricated. That
    # is the harness punishing the judge for the fixture's line width, and it voided two
    # correct verdicts on the first real run. Collapsing runs of whitespace on BOTH sides
    # keeps the requirement exact in every character that carries meaning.
    def _norm(text):
        return " ".join(str(text).split())

    haystack = _norm("\n".join(str(v) for v in artifacts.values()))

    ballots = []
    cost = 0.0
    errors = []
    tmp = tempfile.mkdtemp(prefix="gate-judge-")
    for _ in range(votes):
        parsed, call_cost, err = _one_call(prompt, model, tmp)
        cost += call_cost
        if err:
            errors.append(err)
            continue
        ballots.append(parsed)

    out = {}
    for check in CHECKS:
        yes = no = 0
        quote = None
        why = None
        voided = 0
        for ballot in ballots:
            entry = next(
                (v for v in ballot.get("verdicts", []) if v.get("id") == check["id"]), None
            )
            if entry is None:
                voided += 1
                continue
            span = (entry.get("quote") or "").strip()
            # RULE 1: a quote that is not literally in the artifacts voids the verdict.
            if len(span) < 12 or _norm(span) not in haystack:
                voided += 1
                continue
            if entry.get("answer") is True:
                yes += 1
            elif entry.get("answer") is False:
                no += 1
            else:
                voided += 1
                continue
            if quote is None:
                quote, why = span, entry.get("why")
        counted = yes + no
        if counted == 0:
            verdict = "UNDECIDABLE"
            answer = None
        else:
            answer = yes > no
            verdict = "FAIL" if answer == check["fail_when"] else "PASS"
        out[check["id"]] = {
            "mechanism": check["mechanism"],
            "verdict": verdict,
            "answer": answer,
            "votes": "%d yes / %d no / %d voided of %d" % (yes, no, voided, votes),
            "split": counted > 0 and yes > 0 and no > 0,
            "quote": quote,
            "why": why,
        }
    out["_meta"] = {"cost_usd": round(cost, 4), "errors": errors, "ballots": len(ballots)}
    return out


if __name__ == "__main__":
    payload = json.load(open(sys.argv[1]))
    print(
        json.dumps(
            judge(
                payload["artifacts"],
                payload["ground_truth"],
                votes=int(payload.get("votes", 3)),
            ),
            indent=2,
        )
    )
