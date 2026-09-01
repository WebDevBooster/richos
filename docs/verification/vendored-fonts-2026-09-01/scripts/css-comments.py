"""Do the two stylesheets parse -- specifically, are all comments balanced?

An unbalanced `*/` is what broke :root once tonight: prose landed after a comment
had already closed, WebKit dropped every declaration from that point, and
`--font` silently became nothing. It looked completely fine in a diff.
"""
import re
import sys

for p in sys.argv[1:]:
    s = open(p, encoding="utf-8").read()
    opens = len(re.findall(r"/\*", s))
    closes = len(re.findall(r"\*/", s))
    # Walk it properly rather than trusting the counts: nested-looking text
    # inside a comment is legal and would skew a naive count.
    i, depth, stray = 0, 0, []
    line = 1
    while i < len(s) - 1:
        if s[i] == "\n":
            line += 1
        if depth == 0 and s[i:i + 2] == "/*":
            depth, i = 1, i + 2
            continue
        if depth == 1 and s[i:i + 2] == "*/":
            depth, i = 0, i + 2
            continue
        if depth == 0 and s[i:i + 2] == "*/":
            stray.append(line)
            i += 2
            continue
        i += 1
    status = "OK" if depth == 0 and not stray else "BROKEN"
    print("%-6s %s   /*=%d  */=%d  unterminated=%s  stray-close-at-lines=%s"
          % (status, p.split("/")[-1], opens, closes, depth == 1, stray or "none"))
    if status == "BROKEN":
        sys.exit(1)
