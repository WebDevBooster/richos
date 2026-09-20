"""Literal process-selection rules. Ownership repair: public commit 6902bbcf.

Supported: direct pkill, kill $(pgrep ...), simple scalar assignments followed
by kill $variable and for-variable loops fed by pgrep. Indirect functions,
arrays and eval are outside this syntax contract. Self-match is only blocking
inside a literal sh/bash -c command, where the pattern is in the command line.
"""
import re
import shlex

RULES = {"process-pattern-kill": "blocking", "process-self-wait": "blocking"}


def scan(text):
    findings = []
    selected = set()
    # Joining explicit continuations preserves shell's command spelling.
    for number, line in enumerate(text.replace("\\\n", " ").splitlines(), 1):
        try:
            words = shlex.split(line, comments=True)
        except ValueError:
            continue  # multiline strings are outside the supported syntax
        if not words:
            continue
        stripped = line.strip()
        command = words[0]
        if command in {"echo", "printf", "#"}:
            continue
        assignment = re.match(r"([A-Za-z_]\w*)=", stripped)
        if assignment:
            variable = assignment[1]
            selected.discard(variable)
            if re.search(r"\$\(\s*pgrep\s", stripped):
                selected.add(variable)
        loop = re.match(r"for\s+(\w+)\s+in\s+\$\(\s*pgrep\s", stripped)
        if loop:
            selected.add(loop[1])
        kill = re.match(r"(?:then\s+|do\s+)?kill\s+(.+)", stripped)
        direct = command == "pkill" and "-0" not in words[1:]
        if direct or (kill and (re.search(r"\$\(\s*pgrep\s", kill[1]) or any(
                re.search(r"\$\{?" + re.escape(v) + r"\}?(?!\w)", kill[1]) for v in selected))):
            findings.append(("process-pattern-kill", number))
        if command in {"sh", "bash"} and len(words) == 3 and words[1] == "-c":
            body = words[2]
            match = re.search(r"\b(?:while|until)\s+pgrep\s+-f\s+(['\"]?)([\w./-]+)\1(?:\s|;|$)", body)
            if match and match[2] in line:
                findings.append(("process-self-wait", number))
    return findings
