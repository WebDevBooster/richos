#!/usr/bin/env bash
#
# install-escalation-protocol.sh — put the escalation protocol into every
#                                   teammate definition, byte-identically.
#
# ===========================================================================
# WHY A SCRIPT AND NOT AN EDIT — the same argument as install-ack-protocol.sh
# ===========================================================================
# The protocol has to be identical in 25+ definitions. That is a typed
# inventory in a different costume — the object this engine keeps finding in
# itself — and hand-editing 25 files is how the 26th drifts. So the text lives
# in ONE place, reference/escalation-protocol-seam.md, and this installs it.
#
# Re-runnable. Editing the canonical text and re-running is the supported way
# to change the protocol; editing a definition directly is not, and --check
# will report it as drift.
#
# ===========================================================================
# WHAT IT REPLACES, AND WHY THAT EXACT SPAN
# ===========================================================================
# The three paragraphs of the OLD protocol — the two that specify `BLOCKED.md`
# and the "Then keep working" paragraph that ends with "say so in the file".
# That last one is in the span because the file it refers to no longer exists,
# and a paragraph left behind pointing at a removed mechanism is worse than no
# paragraph: it reads like a second, still-valid option.
#
# WHAT IT DOES NOT TOUCH, deliberately:
#   * "Raise when …" — WHEN to escalate is unchanged and is good doctrine.
#   * The ACK-PROTOCOL-SEAM block or its placeholder, which sits immediately
#     after this span. Escalation (you -> lead, unprompted) and acknowledgement
#     (lead -> you -> proof) are different problems and the definitions say so;
#     collapsing them here would be the mistake that comment exists to prevent.
#
# ===========================================================================
# WHAT IT LOOKS FOR
# ===========================================================================
#   FIRST INSTALL: the old three-paragraph protocol, verbatim.
#   RE-INSTALL:    an existing block between the BEGIN and END markers.
#
# MULTIPLE SEAMS PER FILE ARE NORMAL AND ALL ARE REPLACED. dean.md carries two:
# its own copy and the definition TEMPLATE it hands to every new hire. Missing
# the second would install the fix everywhere except the file that reproduces
# the defect into every future teammate.
#
# Usage:
#   install-escalation-protocol.sh [--repo <path>] [--check] [--diff]
#
#   --check   report only; exit 1 if any definition is missing the protocol or
#             carries a stale copy. This is the mode a CI step or a lander runs.
#   --diff    show what would change, write nothing.
#
# Exit: 0 nothing to do / installed cleanly; 1 --check found drift; 2 error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANON="$ENGINE_ROOT/reference/escalation-protocol-seam.md"

REPO=""
MODE="install"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)  REPO="${2:-}"; shift 2 ;;
        --check) MODE="check"; shift ;;
        --diff)  MODE="diff"; shift ;;
        -h|--help) sed -n '3,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "install-escalation-protocol.sh: unrecognized argument '$1'" >&2; exit 2 ;;
    esac
done

[ -f "$CANON" ] || { echo "install-escalation-protocol.sh: canonical text missing at $CANON — refusing." >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS="$REPO/.claude/agents"
[ -d "$AGENTS" ] || { echo "install-escalation-protocol.sh: no $AGENTS — nothing to install into." >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "install-escalation-protocol.sh: python3 required." >&2; exit 2; }

IEP_CANON="$CANON" IEP_AGENTS="$AGENTS" IEP_MODE="$MODE" python3 <<'PY'
import difflib
import os
import re
import sys

canon_path = os.environ["IEP_CANON"]
agents = os.environ["IEP_AGENTS"]
mode = os.environ["IEP_MODE"]

raw = open(canon_path, encoding="utf-8").read()
# The canonical file's own leading comment explains itself to a human reading
# reference/; the BEGIN marker line that carries it is rewritten to a bare
# marker on install, so 25 definitions do not each carry a note about how to
# edit a file they are not.
body = re.sub(r"<!-- ESCALATION-PROTOCOL-SEAM:BEGIN.*?-->", "<!-- ESCALATION-PROTOCOL-SEAM:BEGIN -->",
              raw, count=1, flags=re.S).strip("\n")

OLD = (
    "**Raise BOTH ways, because the mailbox is lossy.** Write `BLOCKED.md` at the root of your\n"
    "worktree and commit it — that is the durable record and the one that counts — and send a\n"
    "one-line `SendMessage` to `team-lead` saying it exists. The file is the proof; the message is\n"
    "the doorbell. Never let the message be the only copy.\n"
    "\n"
    "**Put four things in `BLOCKED.md`:** what you are blocked on; what you already tried; the\n"
    "smallest question that would unblock you; and what you are proceeding on meanwhile.\n"
    "\n"
    "**Then keep working.** Everything that does not depend on the answer still gets done. Never\n"
    "stall silently, and never invent an answer to a question that belongs to the CEO. If the whole\n"
    "task depends on the answer, say so in the file, stop, and report — a measured \"this is blocked\n"
    "and here is why\" is a complete outcome, not a failure."
)
INSTALLED = re.compile(r"<!-- ESCALATION-PROTOCOL-SEAM:BEGIN -->.*?<!-- ESCALATION-PROTOCOL-SEAM:END -->", re.S)

files = sorted(f for f in os.listdir(agents) if f.endswith(".md"))
if not files:
    sys.stderr.write("install-escalation-protocol.sh: no *.md under %s — refusing to report success over nothing.\n" % agents)
    sys.exit(2)

changed, already, drifted, untouched = [], [], [], []
for name in files:
    p = os.path.join(agents, name)
    src = open(p, encoding="utf-8").read()
    n_old = src.count(OLD)
    n_in = len(INSTALLED.findall(src))
    if n_old == 0 and n_in == 0:
        untouched.append(name)
        continue
    new = src.replace(OLD, body)
    new = INSTALLED.sub(lambda m: body, new)
    if new == src:
        already.append((name, n_in))
        continue
    if n_in and not n_old:
        drifted.append(name)
    if mode == "check":
        changed.append((name, n_old + n_in))
        continue
    if mode == "diff":
        changed.append((name, n_old + n_in))
        sys.stdout.write("".join(difflib.unified_diff(
            src.splitlines(keepends=True), new.splitlines(keepends=True),
            fromfile=name + " (current)", tofile=name + " (installed)", n=2)))
        continue
    open(p, "w", encoding="utf-8").write(new)
    changed.append((name, n_old + n_in))

total_seams = sum(n for _, n in changed) + sum(n for _, n in already)
print("escalation protocol — %s" % agents)
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
        "\ninstall-escalation-protocol.sh: NOT ONE seam found in %d definitions.\n"
        "  That is not 'nothing to do' — it means these definitions do not carry the\n"
        "  escalation contract at all, or its text has been edited by hand and no longer\n"
        "  matches. Refusing to report success over an inventory of nothing.\n" % len(files))
    sys.exit(2)

if mode == "check" and changed:
    sys.stderr.write(
        "\nescalation protocol: %d definition(s) still carry the old BLOCKED.md protocol or a stale copy.\n"
        "  Every teammate booted from one of them will write an escalation nobody reads.\n"
        "  Run: scripts/install-escalation-protocol.sh --repo %s\n" % (len(changed), os.path.dirname(os.path.dirname(agents))))
    sys.exit(1)
sys.exit(0)
PY
