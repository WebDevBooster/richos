"""Timeout-success syntax from the wait-helper repair in a0b51998.

Blocking syntax: a shell if comparison with a named elapsed/SECONDS value
against a timeout/deadline, or a named remaining value against zero, whose
first then-command is literal exit 0. Function calls, traps and complex branch
flow are advisory. No inference from a filename or a nearby prose sentence.
"""
import re
from shell_source import statements

RULES = {"timeout-success": "blocking", "timeout-indirect": "advisory"}
BRANCH = re.compile(r"\bif\s+(\[\[?.*?\]\]?|\(\(.*?\)\))\s*;?\s*then\s+([^\n;]+)", re.S)


def scan(text):
    findings = []
    # Only shell commands at line starts; comments and echoed examples cannot
    # create a branch. Newlines in conditions are supported.
    source = "\n".join(line if not line.lstrip().startswith(("echo ", "printf ")) else "" for line in statements(text).splitlines())
    for match in BRANCH.finditer(source):
        condition, command = match.groups()
        expired = ((re.search(r"\b(?:elapsed|SECONDS|now)\b", condition)
                    and re.search(r"\b(?:TIMEOUT|timeout|deadline|DEADLINE)\b", condition)
                    and re.search(r"-ge|-gt|>=|>(?!=)", condition))
                   or (re.search(r"\bremaining\b", condition)
                       and re.search(r"(?:-le|<=)\s*0", condition)))
        if not expired:
            continue
        line = source.count("\n", 0, match.start()) + 1
        if re.fullmatch(r"exit\s+0\s*(?:#.*)?", command.strip()):
            findings.append(("timeout-success", line))
        elif not re.fullmatch(r"exit\s+[1-9][0-9]*\s*(?:#.*)?", command.strip()):
            findings.append(("timeout-indirect", line))
    return findings
