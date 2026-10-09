#!/usr/bin/env python3
"""fake-claude-bug-report.py - the guest's `claude` for the Bust a bug walk (bug-report-walk.sh).

Rich's write-up is ONE printed turn (`richos_core::bug_report::writer_args`: `--print
--output-format json`, no tools). For that call this answers like Claude Code does, one JSON
object whose `result` is Rich's report, and records the prompt it was given in
<dir>/writer-prompts.log so the walk can show what Rich was told (the user's words, the screen,
the version). The report names the company the walk registered and a person, so the walk can
see both replaced by stand-ins on the card and absent from what reaches the issues endpoint.

Every other call (the conversation, its quota reads, sign-in status) goes to the fill-first fake
(`fake-claude-fill-first.pl`, beside this file in the guest), unchanged.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
one_shot = any(a == "--output-format" and i + 1 < len(args) and args[i + 1] == "json" for i, a in enumerate(args))
if not one_shot:
    os.execv("/usr/bin/perl", ["/usr/bin/perl", os.path.join(HERE, "claude-fill-first"), *args])

prompt = sys.stdin.read()
with open(os.path.join(HERE, "writer-prompts.log"), "a") as log:
    log.write(json.dumps({"argv": args, "prompt": prompt}) + "\n")

if "Answer with ONLY a JSON object, no other text: {\"section\"" in prompt:
    report = {"section": "What happened", "add": "It happens in the light theme too."}
else:
    report = {
        "title": "Conversation names in the sidebar are cut off at larger text sizes",
        "what_happened": "With Text size raised, longer conversation names in the left sidebar are cut off, "
        "so they can no longer be read. The user saw it in the Northwind Traders conversations, "
        "and Dana Whitfield noticed it too.",
        "where": "The list of conversations in the left sidebar.",
        "steps": ["Open any conversation.", "In Settings, raise Text size to 135%.", "Look at a long conversation name in the sidebar."],
        "expected": "Every conversation name can still be read at any text size.",
        "private": [{"text": "Dana Whitfield", "kind": "person"}],
    }
print(json.dumps({"type": "result", "is_error": False, "result": json.dumps(report)}))
