"""Review candidates, never semantic verdicts.

Public references: ee375927 (positive control), 4f75bec8 (runner retries),
5a7a40cf (absence wording). Tests can share controls or exercise product retry.
"""
import re

RULES = {"test-positive-control": "advisory", "test-retry": "advisory", "ui-absence": "advisory"}


def scan(text, role, language):
    findings = []
    # Keep line numbers but do not turn prose about a past defect into a live
    # assertion or UI string. Inline and complex block comments remain candidates.
    text = "\n".join("" if line.lstrip().startswith(("#", "//", "/*", "*")) else line for line in text.splitlines())
    if role == "suite":
        refusal = re.search(r"assert[^\n]*(?:refus|reject|denied|is_err|not\.ok)|(?:refus|reject)[^\n]*assert", text, re.I)
        accepting = re.search(r"assert[^\n]*(?:accept|success|is_ok|allowed)|(?:accept|success)[^\n]*assert", text, re.I)
        if refusal and not accepting:
            findings.append(("test-positive-control", text.count("\n", 0, refusal.start()) + 1))
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r"(?:--retries|retries\s*:|retry\s*\(|\bsleep\s+\d+)", line) and not line.lstrip().startswith(("#", "//")):
                findings.append(("test-retry", number))
    if language == "javascript" and role == "production":
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r"['\"`](?:No (?!thanks\b)|Nothing |You have no |There (?:is|are) no )[^'\"`]+['\"`]", line):
                findings.append(("ui-absence", number))
    return findings
