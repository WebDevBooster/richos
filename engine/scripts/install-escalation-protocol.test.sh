#!/usr/bin/env bash
#
# install-escalation-protocol.test.sh — the suite for
#                                        scripts/install-escalation-protocol.sh.
#
# ===========================================================================
# WHAT IS ACTUALLY AT RISK HERE
# ===========================================================================
# This installer rewrites 25+ teammate definitions in place. Three ways it
# could be worse than doing nothing, and there is a case for each:
#
#   IT MISSES A SEAM. A teammate booted from a definition that still says
#   "write BLOCKED.md" writes an escalation nobody reads — the original defect,
#   surviving in exactly the file nobody re-reads. dean.md carries TWO seams
#   (its own, and the template it hands to every new hire) and the second one
#   reproduces the defect into every future teammate, so "all occurrences" is
#   a requirement rather than a nicety.
#
#   IT EATS SOMETHING ELSE. The ACK-PROTOCOL-SEAM sits immediately after the
#   span being replaced. Escalation and acknowledgement are deliberately
#   different problems; an installer that swallowed the adjacent block would
#   collapse them silently.
#
#   IT REPORTS SUCCESS OVER NOTHING. An inventory of zero is the failure this
#   engine keeps finding in itself, so a run that matches no seam at all must
#   be an ERROR and not a clean "nothing to do".
#
# Usage:  scripts/install-escalation-protocol.test.sh [-v]

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SRC_DIR/.." && pwd)"
INSTALLER="$SRC_DIR/install-escalation-protocol.sh"
CANON="$ENGINE_ROOT/reference/escalation-protocol-seam.md"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }
say() { [ "$VERBOSE" -eq 1 ] && printf '\n----- %s -----\n%s\n' "$1" "$2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
[ -f "$CANON" ] || { echo "FATAL: canonical text missing at $CANON" >&2; exit 1; }

SANDBOX="$(cd "$(mktemp -d -t install-escalation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"
mkdir -p "$REPO/.claude/agents"

# --- the fixture: the OLD protocol, verbatim, as it stands in every shipped
# definition today, plus the adjacent ack placeholder that must survive.
write_definition() { # <file> <how-many-copies>
    local f="$1" n="${2:-1}" i
    : > "$f"
    printf -- '---\nname: fixture\n---\n\n# Fixture\n\n' >> "$f"
    i=0
    while [ "$i" -lt "$n" ]; do
        cat >> "$f" <<'DEF'
## Raising a Blocker — Your Escalation Channel

You have `SendMessage`. Use it for one purpose: telling the lead something it must know BEFORE
your final report.

**Raise when** you are blocked; when a premise in your brief turns out to be false; when a
decision is needed that only the CEO can make; or when you discover something that makes the
task WRONG rather than merely hard. Do not raise progress updates or narration — those are
noise, and noise is what makes a real signal get ignored.

**Raise BOTH ways, because the mailbox is lossy.** Write `BLOCKED.md` at the root of your
worktree and commit it — that is the durable record and the one that counts — and send a
one-line `SendMessage` to `team-lead` saying it exists. The file is the proof; the message is
the doorbell. Never let the message be the only copy.

**Put four things in `BLOCKED.md`:** what you are blocked on; what you already tried; the
smallest question that would unblock you; and what you are proceeding on meanwhile.

**Then keep working.** Everything that does not depend on the answer still gets done. Never
stall silently, and never invent an answer to a question that belongs to the CEO. If the whole
task depends on the answer, say so in the file, stop, and report — a measured "this is blocked
and here is why" is a complete outcome, not a failure.

*ACK-PROTOCOL-SEAM — how you acknowledge a correction sent TO you by the lead is defined
elsewhere and deliberately not specified here. Escalation (you → lead, unprompted) and
acknowledgement (lead → you → proof) are different problems; do not collapse them.*

## Identity

DEF
        i=$((i + 1))
    done
}

write_definition "$REPO/.claude/agents/zach.md" 1
write_definition "$REPO/.claude/agents/dean.md" 2      # the two-seam case
printf -- '---\nname: nothing\n---\n\nNo escalation section here at all.\n' \
    > "$REPO/.claude/agents/stranger.md"

# ===========================================================================
# 1. --check reports the drift and writes NOTHING
# ===========================================================================
BEFORE="$(cat "$REPO/.claude/agents/zach.md")"
OUT="$("$INSTALLER" --repo "$REPO" --check 2>&1)"
RC=$?
say "1 check" "$OUT"
if [ "$RC" -eq 1 ]; then ok "1a  --check exits 1 over definitions carrying the old protocol"
else bad "1a  --check exit 1" "rc=$RC"; fi
case "$OUT" in
    *"seams found    : 3"*) ok "1b  it finds all THREE seams — one in zach.md, TWO in dean.md" ;;
    *) bad "1b  seam count" "expected 3: $OUT" ;;
esac
case "$OUT" in
    *"no seam        : 1"*) ok "1c  and reports the definition that has none, rather than passing over it" ;;
    *) bad "1c  no-seam reported" "$OUT" ;;
esac
if [ "$BEFORE" = "$(cat "$REPO/.claude/agents/zach.md")" ]; then ok "1d  --check wrote nothing"
else bad "1d  --check is read-only" "the file changed"; fi

# ===========================================================================
# 2. THE INSTALL — every seam, in every file
# ===========================================================================
OUT="$("$INSTALLER" --repo "$REPO" 2>&1)"
RC=$?
say "2 install" "$OUT"
if [ "$RC" -eq 0 ]; then ok "2a  install exits 0"; else bad "2a  install exit 0" "rc=$RC: $OUT"; fi
# THE INSTRUCTION, not the string. The new text names `BLOCKED.md` on purpose —
# it explains why that file is no longer the mechanism — so an assertion that
# the two words are absent would be asserting the wrong thing and would force
# the explanation out of the definition.
if grep -qF 'Write `BLOCKED.md` at the root of your' "$REPO/.claude/agents/zach.md"; then
    bad "2b  old protocol gone" "zach.md still INSTRUCTS the teammate to write BLOCKED.md at the root"
else
    ok "2b  the instruction to write BLOCKED.md at the root is GONE"
fi
N="$(grep -c 'ESCALATION-PROTOCOL-SEAM:BEGIN' "$REPO/.claude/agents/dean.md")"
if [ "$N" = "2" ]; then ok "2c  BOTH of dean.md's seams were replaced — including the template every new hire is built from"
else bad "2c  all occurrences" "dean.md has $N installed blocks, expected 2"; fi
if grep -qF 'Write `BLOCKED.md` at the root of your' "$REPO/.claude/agents/dean.md"; then
    bad "2d  dean.md clean" "an old seam survived in the file that reproduces itself"
else
    ok "2d  and neither of dean.md's copies still instructs it"
fi
if grep -q 'escalate\.sh raise' "$REPO/.claude/agents/zach.md"; then ok "2e  the new command is in the definition"
else bad "2e  new command" "escalate.sh raise not found"; fi

# ===========================================================================
# 3. WHAT SITS BESIDE IT SURVIVED. Escalation and acknowledgement are
#    different problems and the definitions say so; an installer that ate the
#    ack placeholder would collapse them without anybody noticing.
# ===========================================================================
if grep -q 'ACK-PROTOCOL-SEAM' "$REPO/.claude/agents/zach.md"; then
    ok "3a  the ACK-PROTOCOL-SEAM placeholder immediately after the span is untouched"
else
    bad "3a  ack seam survives" "the installer swallowed the block beside it"
fi
if grep -q 'Raise when' "$REPO/.claude/agents/zach.md"; then
    ok "3b  and WHEN to escalate — unchanged doctrine — is still there"
else
    bad "3b  'Raise when' survives" "the installer replaced more than the mechanism"
fi
if grep -q '^## Identity' "$REPO/.claude/agents/zach.md"; then ok "3c  the section after it is intact"
else bad "3c  following section" "## Identity is gone"; fi

# ===========================================================================
# 4. IDEMPOTENT — and --check goes green
# ===========================================================================
AFTER1="$(cat "$REPO/.claude/agents/zach.md")"
"$INSTALLER" --repo "$REPO" >/dev/null 2>&1
if [ "$AFTER1" = "$(cat "$REPO/.claude/agents/zach.md")" ]; then ok "4a  a second install changes nothing"
else bad "4a  idempotent" "the file changed on re-install"; fi
"$INSTALLER" --repo "$REPO" --check >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "4b  --check now exits 0"; else bad "4b  --check green" "rc=$RC"; fi

# ===========================================================================
# 5. DRIFT — a definition edited by hand is REPLACED and SAID OUT LOUD
# ===========================================================================
python3 - "$REPO/.claude/agents/zach.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("Run it from your own worktree.", "Someone edited this by hand.")
open(p, "w", encoding="utf-8").write(s)
PY
OUT="$("$INSTALLER" --repo "$REPO" --check 2>&1)"
RC=$?
if [ "$RC" -eq 1 ]; then ok "5a  a hand-edited definition is reported as drift"
else bad "5a  drift detected" "rc=$RC: $OUT"; fi
OUT="$("$INSTALLER" --repo "$REPO" 2>&1)"
case "$OUT" in
    *"STALE COPY REPLACED"*) ok "5b  and re-installing says which one it overwrote" ;;
    *) bad "5b  stale copy named" "$OUT" ;;
esac
if grep -q 'Someone edited this by hand' "$REPO/.claude/agents/zach.md"; then
    bad "5c  drift repaired" "the hand edit survived the re-install"
else
    ok "5c  the hand edit is gone — the canonical text is the only source"
fi

# ===========================================================================
# 6. AN INVENTORY OF NOTHING IS AN ERROR, NOT A CLEAN RUN.
#    The failure this engine keeps finding in itself.
# ===========================================================================
EMPTY="$SANDBOX/empty"
mkdir -p "$EMPTY/.claude/agents"
printf -- '---\nname: x\n---\n\nnothing to seam here\n' > "$EMPTY/.claude/agents/x.md"
OUT="$("$INSTALLER" --repo "$EMPTY" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then ok "6a  no seam anywhere is exit 2, not a quiet success"
else bad "6a  empty inventory" "rc=$RC: $OUT"; fi
case "$OUT" in
    *"NOT ONE seam found"*) ok "6b  and it says so in words" ;;
    *) bad "6b  says so" "$OUT" ;;
esac
OUT="$("$INSTALLER" --repo "$SANDBOX/does-not-exist" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then ok "6c  a repository with no .claude/agents is exit 2 too"
else bad "6c  missing agents dir" "rc=$RC: $OUT"; fi

# ===========================================================================
# 7. THE SHIPPED CANONICAL TEXT ACTUALLY CARRIES THE COMMAND.
#    A seam installed everywhere that told teammates nothing useful would pass
#    every case above.
# ===========================================================================
for want in 'escalate.sh raise' '--state' 'work-complete' 'docs/verification/' 'EXITS NON-ZERO'; do
    if grep -qF -e "$want" "$CANON"; then ok "7   the canonical text names: $want"
    else bad "7   canonical text" "missing: $want"; fi
done

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
