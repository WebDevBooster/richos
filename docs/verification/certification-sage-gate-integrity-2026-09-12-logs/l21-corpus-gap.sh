#!/usr/bin/env bash
#
# l21-corpus-gap.sh — L21 in land-completeness.test.sh asks "does any sibling
# suite write to the operator's real registry?" over a corpus it derives with a
# regex. This asks what the tree actually contains.
#
# L21's INVOKE half recognizes four spellings of the command and nothing else:
#
#     workspaces.sh | $WORKSPACES | $WS | $WORKSPACES_SH
#
# and its other half recognizes the library's python entry points called in
# process. A suite that holds the script's path in any OTHER variable and runs a
# writer subcommand through it is not in the corpus at all -- neither flagged nor
# cleared, just absent from a count that is then reported as an answer. The tree
# already uses a fifth spelling, `$WS_PY`, in five suites.
#
# THE PREDICATE HERE IS DELIBERATELY LOOSE AND EVERY HIT IS PRINTED IN FULL, so a
# reader decides what is a writer call rather than a second regex deciding and
# being believed. Continuation lines are joined first, because a `\` before the
# newline is exactly how a subcommand hides from a line-oriented pattern.
#
#   usage: l21-corpus-gap.sh <engine-scripts-root>
#
# Exit 0 = every writer-shaped invocation in the tree sits inside L21's corpus.
# Exit 1 = at least one does not (the finding). Whether each is sandboxed ANYWAY
#          is printed, because the finding is about the corpus and not about an
#          incident.
set -uo pipefail
ROOT="${1:?usage: l21-corpus-gap.sh <engine-scripts-root>}"

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]

# L21's own two predicates, copied verbatim from land-completeness.test.sh so
# that this is a comparison and not a re-implementation.
INVOKE = r"(?:workspaces\.sh|\$\{?(?:WORKSPACES|WS|WORKSPACES_SH)\}?)[\"']?\s+"
L21_WRITERS = re.compile(
    INVOKE + r"(?:integration|land|discard|pause|resume|stop|wait|retry)\b"
    r"|\b(?:register_spawn|register_cc|record_start|record_end|bind_agent|record_integration)\(")
L21_SANDBOXED = re.compile(
    r"\b(RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)="
    r"|['\"](RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)['\"]\s*:"
    r"|['\"](RICHOS_WORKSPACES_DIR|CLAUDE_CONFIG_DIR|HOME)['\"]\s*\]\s*=")

# Any variable that could hold the command, and any writer subcommand, on the
# same logical line.
HOLDER = re.compile(r"\$\{?(WS_PY|WORKSPACES|WS|WORKSPACES_SH|W)\}?")
WORDS = ("integration", "land", "discard", "pause", "resume", "stop", "wait", "retry")

outside = []
for dirpath, _dn, fns in os.walk(root):
    for fn in sorted(fns):
        if not (fn.endswith(".test.sh") or fn.endswith(".test.py")
                or fn.endswith(".mutation.sh")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        rel = os.path.relpath(p, root)
        joined = text.replace("\\\n", " ")
        hits = [(i, line.strip()[:150])
                for i, line in enumerate(joined.splitlines(), 1)
                if HOLDER.search(line)
                and any(re.search(r"(?<![-\w])%s(?![-\w])" % w, line) for w in WORDS)]
        if not hits:
            continue
        if L21_WRITERS.search(text):
            continue
        outside.append((rel, bool(L21_SANDBOXED.search(text)), hits))

print("writer-shaped invocations OUTSIDE the corpus L21 derives:\n")
for rel, sandboxed, hits in outside:
    print("  %s   (sandboxed anyway: %s)" % (rel, "YES" if sandboxed else "NO"))
    for i, line in hits:
        print("      :%-5d %s" % (i, line))
    print("")
print("%d suite(s) outside the corpus." % len(outside))
print("")
print("READ THE LINES. Some are false positives of this loose predicate -- a")
print("`$FIN_REPORT\\n\\nstop` or a prose mention of the word `land` is not a writer")
print("call. A `python3 \"$WS_PY\" ... integration --repo ...` is one, and so is a")
print("`python3 \"$WS_PY\" ... pause <agent> --until ...`.")
sys.exit(1 if outside else 0)
PY
