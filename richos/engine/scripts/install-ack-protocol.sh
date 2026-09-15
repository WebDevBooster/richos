#!/usr/bin/env bash
#
# install-ack-protocol.sh — put the ack protocol into every teammate definition,
#                           at the seam that was left for it, byte-identically.
#
# ===========================================================================
# WHY A SCRIPT AND NOT AN EDIT
# ===========================================================================
# The protocol has to be identical in 25+ definitions. That is a typed
# inventory in a different costume — the object this engine keeps finding in
# itself — and hand-editing 25 files is how the 26th drifts. So the text lives
# in ONE place, reference/ack-protocol-seam.md, and this installs it.
#
# Re-runnable. Editing the canonical text and re-running is the supported way
# to change the protocol; editing a definition directly is not, and --check
# will report it as drift.
#
# ===========================================================================
# WHAT IT LOOKS FOR
# ===========================================================================
#   FIRST INSTALL: the placeholder paragraph, verbatim —
#       *ACK-PROTOCOL-SEAM — how you acknowledge a correction sent TO you by
#       the lead is defined elsewhere and deliberately not specified here. ...*
#   RE-INSTALL:    an existing block between the BEGIN and END markers.
#
# Only those two shapes are touched. A definition that merely MENTIONS the
# token in prose — dean.md carries a frontmatter rule about it — is left alone,
# because a rule about the seam is not the seam.
#
# Usage:
#   install-ack-protocol.sh [--repo <path>] [--check] [--diff]
#
#   --check   report only; exit 1 if any definition is missing the protocol or
#             carries a stale copy. This is the mode a CI step or a lander runs.
#   --diff    show what would change, write nothing.
#
# Exit: 0 nothing to do / installed cleanly; 1 --check found drift; 2 error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANON="$ENGINE_ROOT/reference/ack-protocol-seam.md"

REPO=""
MODE="install"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)  REPO="${2:-}"; shift 2 ;;
        --check) MODE="check"; shift ;;
        --diff)  MODE="diff"; shift ;;
        -h|--help) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "install-ack-protocol.sh: unrecognized argument '$1'" >&2; exit 2 ;;
    esac
done

[ -f "$CANON" ] || { echo "install-ack-protocol.sh: canonical text missing at $CANON — refusing." >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS="$REPO/.claude/agents"
[ -d "$AGENTS" ] || { echo "install-ack-protocol.sh: no $AGENTS — nothing to install into." >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "install-ack-protocol.sh: python3 required." >&2; exit 2; }

IAP_CANON="$CANON" IAP_AGENTS="$AGENTS" IAP_MODE="$MODE" python3 <<'PY'
import difflib
import os
import re
import sys

canon_path = os.environ["IAP_CANON"]
agents = os.environ["IAP_AGENTS"]
mode = os.environ["IAP_MODE"]

raw = open(canon_path, encoding="utf-8").read()
# The canonical file's own leading comment explains itself to a human reading
# reference/; the BEGIN marker line that carries it is rewritten to a bare
# marker on install, so 25 definitions do not each carry a note about how to
# edit a file they are not.
body = re.sub(r"<!-- ACK-PROTOCOL-SEAM:BEGIN.*?-->", "<!-- ACK-PROTOCOL-SEAM:BEGIN -->",
              raw, count=1, flags=re.S).strip("\n")

PLACEHOLDER = re.compile(
    r"\*ACK-PROTOCOL-SEAM — how you acknowledge a correction sent TO you by the lead is defined\n"
    r"elsewhere and deliberately not specified here\. Escalation \(you → lead, unprompted\) and\n"
    r"acknowledgement \(lead → you → proof\) are different problems; do not collapse them\.\*"
)
INSTALLED = re.compile(r"<!-- ACK-PROTOCOL-SEAM:BEGIN -->.*?<!-- ACK-PROTOCOL-SEAM:END -->", re.S)

files = sorted(f for f in os.listdir(agents) if f.endswith(".md"))
if not files:
    sys.stderr.write("install-ack-protocol.sh: no *.md under %s — refusing to report success over nothing.\n" % agents)
    sys.exit(2)

changed, already, drifted, untouched = [], [], [], []
for name in files:
    p = os.path.join(agents, name)
    src = open(p, encoding="utf-8").read()
    n_ph = len(PLACEHOLDER.findall(src))
    n_in = len(INSTALLED.findall(src))
    if n_ph == 0 and n_in == 0:
        untouched.append(name)
        continue
    new = PLACEHOLDER.sub(lambda m: body, src)
    new = INSTALLED.sub(lambda m: body, new)
    if new == src:
        already.append((name, n_in))
        continue
    if n_in and not n_ph:
        drifted.append(name)
    if mode == "check":
        changed.append((name, n_ph + n_in))
        continue
    if mode == "diff":
        changed.append((name, n_ph + n_in))
        sys.stdout.write("".join(difflib.unified_diff(
            src.splitlines(keepends=True), new.splitlines(keepends=True),
            fromfile=name + " (current)", tofile=name + " (installed)", n=2)))
        continue
    open(p, "w", encoding="utf-8").write(new)
    changed.append((name, n_ph + n_in))

total_seams = sum(n for _, n in changed) + sum(n for _, n in already)
print("ack protocol — %s" % agents)
print("  canonical text : %s (%d lines)" % (canon_path, body.count("\n") + 1))
print("  definitions    : %d" % len(files))
print("  seams found    : %d" % total_seams)
if untouched:
    print("  no seam        : %d (%s)" % (len(untouched), " ".join(untouched[:8]) + (" …" if len(untouched) > 8 else "")))
for name, n in already:
    print("  up to date     : %s (%d)" % (name, n))
for name, n in changed:
    verb = {"check": "WOULD INSTALL", "diff": "WOULD INSTALL", "install": "installed"}[mode]
    tag = " (STALE COPY REPLACED)" if name in drifted else ""
    print("  %-14s : %s (%d)%s" % (verb, name, n, tag))

if not total_seams:
    sys.stderr.write(
        "\ninstall-ack-protocol.sh: NOT ONE seam found in %d definitions.\n"
        "  That is not 'nothing to do' — it means the escalation contract that carries\n"
        "  the seam has not been installed here, or its placeholder text has changed.\n"
        "  Refusing to report success over an inventory of nothing.\n" % len(files))
    sys.exit(2)

if mode == "check" and changed:
    sys.stderr.write(
        "\nack protocol: %d definition(s) are missing it or carry a stale copy.\n"
        "  Run: scripts/install-ack-protocol.sh --repo %s\n" % (len(changed), os.path.dirname(os.path.dirname(agents))))
    sys.exit(1)
sys.exit(0)
PY
