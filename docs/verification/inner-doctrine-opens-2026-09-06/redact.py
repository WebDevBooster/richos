#!/usr/bin/env python3
"""Redact the operator's identity from captured stream-json frames before they are committed.

The `initialize` control_response carries an `account` object with the operator's email
address, organization name and subscription type. This repository is public. Following
`echo-opus-sn1`'s precedent, that ONE object is replaced with a marker naming what it held;
nothing else in the frame is touched. Idempotent, and it verifies its own result.

Usage: redact.py raw/*.jsonl
"""
import json, re, sys

MARKER = "REDACTED: the initialize reply's `account` object held the operator's email address, organization and subscription type. Removed before commit; RichOS keeps nothing from it either (native.rs:40-45)."
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# A SECOND site, not present in `echo-opus-sn1`'s single-turn cells and found only because
# the check was run: the post-compaction summary quotes the `system-reminder` that names the
# operator's email address, so the address appears in a `user` frame's text as well as in the
# `account` object. Replaced in place with this marker.
EMAIL_MARKER = "<REDACTED-OPERATOR-EMAIL>"


def scrub(obj):
    """Replace any dict value keyed `account` with the marker, anywhere in the frame,
    and any email-shaped string in any text with EMAIL_MARKER."""
    if isinstance(obj, dict):
        return {k: (MARKER if k == "account" else scrub(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub(v) for v in obj]
    if isinstance(obj, str):
        return EMAIL.sub(EMAIL_MARKER, obj)
    return obj


for path in sys.argv[1:]:
    out = []
    changed = 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            frame = json.loads(line)
        except Exception:
            out.append(line)
            continue
        new = scrub(frame)
        if new != frame:
            changed += 1
        out.append(json.dumps(new))
    open(path, "w").write("\n".join(out) + "\n")
    body = open(path).read()
    leaks = sorted(set(EMAIL.findall(body)))
    print("%s: %d frame(s) redacted, %d email-shaped strings remaining" % (path, changed, len(leaks)))
    if leaks:
        print("   STILL PRESENT — do not commit:", leaks)
        sys.exit(1)
