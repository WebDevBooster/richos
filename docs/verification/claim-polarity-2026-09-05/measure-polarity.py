#!/usr/bin/env python3
"""g3: how often does a landing/push sentence assert the NEGATIVE, and what
would a polarity gate cost in recall?

Corpus and method are state-claims.corpus.md's: every non-scratchpad
orchestrator transcript, the LAST assistant text block of each promptId span,
sidechains skipped. Claims are extracted with the hook's own state_claims().
"""
import importlib.util
import json
import os
import re
import sys

ANALYZER = os.environ.get(
    "RICHOS_CLAIMS_ANALYZER",
    os.path.expanduser("~/.claude/richos-engine/scripts/hooks/guard-unresolved-claims.py"))
spec = importlib.util.spec_from_file_location("uc", ANALYZER)
uc = importlib.util.module_from_spec(spec)
sys.modules["uc"] = uc
spec.loader.exec_module(uc)

ROOT = "/Users/alex/.claude/projects"

# ---- the polarity rule AS MEASURED. The shipped copy now lives in the
# ---- analyzer (claim_polarity); this one is kept so the measurement can be
# ---- re-run against a transcript corpus without importing hook internals.
NEG_CUE = re.compile(
    r"\b(?:not|never|no|nor|neither|nothing|none|without|cannot)\b|n[’']t\b",
    re.I)
NEG_EXCEPT = re.compile(r"\bnot\s+(?:only|just|merely|simply|yet\s+another)\b", re.I)
CLAUSE_SPLIT = re.compile(
    r"[.!?:,]|\s+--\s+|\s+—\s+|\bbut\b|\band\b|\bwhile\b|\bthough\b|\balthough\b|\bbecause\b|\bso\b",
    re.I)


def clause_of(sentence, pos):
    bounds = [0]
    for m in CLAUSE_SPLIT.finditer(sentence):
        bounds.append(m.end())
    bounds.append(len(sentence))
    for i in range(len(bounds) - 1):
        if bounds[i] <= pos < bounds[i + 1]:
            return bounds[i], bounds[i + 1]
    return 0, len(sentence)


def polarity(sentence, pos):
    a, b = clause_of(sentence, pos)
    clause = sentence[a:b]
    rel = pos - a
    before = clause[:rel]
    masked = NEG_EXCEPT.sub(" ", before)
    if NEG_CUE.search(masked):
        return "negated"
    after = NEG_EXCEPT.sub(" ", clause[rel:])
    if NEG_CUE.search(after):
        return "unreadable"
    return "positive"


def turns():
    for d in sorted(os.listdir(ROOT)):
        if not d.startswith("-Users-alex-"):
            continue
        p = os.path.join(ROOT, d)
        if not os.path.isdir(p):
            continue
        for fn in sorted(os.listdir(p)):
            if not fn.endswith(".jsonl"):
                continue
            spans = {}
            order = []
            with open(os.path.join(p, fn), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("isSidechain"):
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    pid = (rec.get("promptId") or rec.get("prompt_id")
                           or rec.get("requestId") or rec.get("uuid") or "")
                    msg = rec.get("message") or {}
                    content = msg.get("content")
                    if not isinstance(content, list):
                        continue
                    text = "\n".join(b.get("text", "") for b in content
                                     if isinstance(b, dict) and b.get("type") == "text")
                    if not text.strip():
                        continue
                    if pid not in spans:
                        order.append(pid)
                    spans[pid] = text
            for pid in order:
                yield spans[pid]


counts = {"positive": 0, "negated": 0, "unreadable": 0}
msgs = 0
withclaims = 0
examples = {"negated": [], "unreadable": []}
disagree = []
for text in turns():
    msgs += 1
    claims = uc.state_claims(text)
    if not claims:
        continue
    withclaims += 1
    for claim in claims:
        kind, sha, sentence = claim[0], claim[1], claim[2]
        rx = uc.STATE_INTEGRATED if kind == "integrated" else uc.STATE_PUBLISHED
        m = rx.search(sentence)
        # The SHIPPED reading is the authority when the analyzer carries one
        # (it does, from 2026-09-05); the local draft is kept as a cross-check
        # so a divergence is visible rather than silently overwritten.
        pol = claim[3] if len(claim) > 3 else (
            polarity(sentence, m.start()) if m else "positive")
        if len(claim) > 3 and m:
            draft = polarity(sentence, m.start())
            if draft != pol:
                disagree.append((kind, sha, draft, pol, sentence[:160]))
        counts[pol] += 1
        if pol in examples and len(examples[pol]) < 14:
            examples[pol].append((kind, sha, sentence[:200]))

print("final assistant messages examined :", msgs)
print("messages carrying a state claim   :", withclaims)
print("state claims extracted            :", sum(counts.values()))
print("draft/shipped disagreements       :", len(disagree))
print()
for k in ("positive", "negated", "unreadable"):
    print("  %-11s %d" % (k, counts[k]))
print()
for k in ("negated", "unreadable"):
    print("=== %s ===" % k.upper())
    for kind, sha, s in examples[k]:
        print("  [%s %s] %s" % (kind, sha[:8], s.replace("\n", " ")))
    print()
