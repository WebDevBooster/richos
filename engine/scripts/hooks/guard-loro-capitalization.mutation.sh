#!/usr/bin/env bash
#
# guard-loro-capitalization.mutation.sh — PROVES THE SUITE CAN FAIL.
#
# 61 green ticks are evidence of nothing until somebody shows them turning red
# for the right reason, and this guard has a specific way of being useless while
# looking healthy. A shape quietly dropped from the scan loop, an exemption
# widened by one character, an `exit 2` that became `exit 0`: every one of those
# leaves the hook wired, registered, present, executable and PASSING, over zero
# enforcement. That is the exact shape of the defect it was built for — a rule
# that a sweep cleaned and nothing constrained afterwards.
#
# So: take the SHIPPED source, remove ONE property at a time, and assert that
#   1. guard-loro-capitalization.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement that matched nothing gives a
#      green run that looks like a green run, which is the same trap again).
#
# HALF THESE MUTANTS TARGET AN EXEMPTION, on purpose. The exemptions are what
# keeps the guard from crying wolf, and a guard that cries wolf is switched off
# within a day — at which point the rule has no chokepoint again and we are back
# at 2026-09-01.
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/guard-loro-capitalization.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t guard-loro-caps-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# mutant <name> <expected-failing-case> <rel-file> <old> <new> <why>
mutant() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib" "$dir/hooks" "$dir/.claude"
    cp "$ENGINE_ROOT/scripts/hooks/guard-loro-capitalization.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-loro-capitalization.test.sh" \
       "$ENGINE_ROOT/scripts/hooks/loro-capitalization.corpus.md" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/hooks/hooks.json" "$dir/hooks/"
    cp "$ENGINE_ROOT/.claude/settings.local.json" "$dir/.claude/"
    cp "$ENGINE_ROOT/orchestration.config" "$dir/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    bash "$dir/scripts/hooks/guard-loro-capitalization.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

echo "=== the loro capitalization guard: every property, proven by removing it ==="

G="scripts/hooks/guard-loro-capitalization.sh"
C="orchestration.config"

# --- 1. IT BLOCKS AT ALL ---------------------------------------------------
mutant refuses-to-refuse "A1. " "$G" \
    '      echo "  Rule: wiki/loro-concept.md. (hook: scripts/hooks/guard-loro-capitalization.sh)"\n    } >&2\n    exit 2' \
    '      echo "  Rule: wiki/loro-concept.md. (hook: scripts/hooks/guard-loro-capitalization.sh)"\n    } >&2\n    exit 0' \
    "the guard would find every violation, print it, and let the write through — a warning wearing a guard's clothes."

# --- 2. EACH BLOCKING SHAPE IS SEPARATELY LOAD-BEARING ---------------------
mutant no-heading-shape "A5. " "$G" \
    '    for shape, rx in (("HEADING", HEADING_RE), ("LIST", LIST_RE), ("SENTENCE", SENTENCE_RE)):' \
    '    for shape, rx in (("LIST", LIST_RE), ("SENTENCE", SENTENCE_RE)):' \
    "'# loro architecture' would sail through, and headings are where the drift was most visible."

mutant no-sentence-shape "A1. " "$G" \
    '    for shape, rx in (("HEADING", HEADING_RE), ("LIST", LIST_RE), ("SENTENCE", SENTENCE_RE)):' \
    '    for shape, rx in (("HEADING", HEADING_RE), ("LIST", LIST_RE)):' \
    "the sentence start is the single commonest drift site in the record — 26 of the 63 corrected in richos-hq."

# --- 3. A SENTENCE CAN END INSIDE A BOLD RUN -------------------------------
# Worth its own mutant because leaving it out is invisible: the guard still
# blocks, still reports, still passes most cases, and silently misses 8 of the
# true positives it was measured on.
mutant no-emphasis-closer "A7. " "$G" \
    'SENTENCE_RE = re.compile(r"[.!?]" + SENT_CLOSERS + r"\s+" + EMPH + r"(" + WORD + r")\b")' \
    'SENTENCE_RE = re.compile(r"[.!?]" + r"[)]*" + r"\s+" + EMPH + r"(" + WORD + r")\b")' \
    "'**Push, not just pull.** loro feeds' ends its sentence inside a bold run; 8 measured true positives are on the other side of this character class."

# --- 4. THE LIST SHAPE MUST NOT BLOCK --------------------------------------
mutant list-shape-blocks "C1. " "$G" \
    '            if shape == "LIST":\n                REPORT.append((shape, site))\n            else:\n                BLOCK.append((shape, site))' \
    '            BLOCK.append((shape, site))' \
    "a 60%-false-positive shape would become a hard block, and a guard with a false-positive class gets waived — which is how a defense decays into a formality."

# --- 5. THE DECLARED EXEMPTION MUST CARRY A REASON -------------------------
mutant bare-marker-exempts "B29. " "$G" \
    'DECLARED_EXEMPT_RE = re.compile(r"loro-caps-exempt:\s*[A-Za-z0-9]")' \
    'DECLARED_EXEMPT_RE = re.compile(r"loro-caps-exempt:")' \
    "a bare 'loro-caps-exempt:' would exempt anything, so the escape hatch becomes an off switch anyone can type."

# --- 6. THE EXEMPTIONS ARE THE PRODUCT, NOT THE TRIMMINGS ------------------
mutant no-blockquote-exemption "B11. " "$G" \
    '    if QUOTE_RE.match(line):\n        continue' \
    '    if False:\n        continue' \
    "quoted material — including the CEO's own verbatim words — would be re-cased by a machine."

mutant quote-without-comment-lead "B12. " "$G" \
    'QUOTE_RE = re.compile(r"^\s*(?://+!?|\#+|\*|--|;+)?\s*>")' \
    'QUOTE_RE = re.compile(r"^\s*>")' \
    "loro/lib/privacy.js quotes the architecture page as ' * > …'; without the comment lead that was a measured false positive."

mutant no-hyphen-rule "B13. " "$G" \
    '    if "-" in tok:\n        return True' \
    '    if False:\n        return True' \
    "'loro-context' and 'loro-correction' are command names; flagging them cost 3 false positives when measured and gained nothing."

mutant code-lines-are-prose "B16. " "$G" \
    '                if not prose_line:\n                    continue' \
    '                if False:\n                    continue' \
    "a string literal inside a code line would be read as a sentence — the test-fixture page body in loro/test/run.js was exactly that."

mutant already-capital-reflagged "B5. " "$G" \
    '            if word[0].isupper():\n                continue' \
    '            if False:\n                continue' \
    "the guard would start arguing with an already-capital Loro, and deciding when to LOWERCASE is precisely the judgment it cannot make."

mutant no-abbreviation-rule "B18. " "$G" \
    '                if prev_word.lower() in ABBREV or ABBREV_SHAPE.search(prev_word):\n                    continue' \
    '                if False:\n                    continue' \
    "'e.g. loro' would be read as a sentence boundary, and the guard would demand a capital in the middle of a clause."

mutant no-evidence-paths "B21. " "$G" \
    '    for seg in low_path.split("/"):' \
    '    for seg in []:' \
    "wiki/raw/ is the CEO's own dropped source material, and a machine re-casing his words is the one thing this rule exists to prevent."

# --- 7. THE OFF SWITCH IS REAL, AND SILENT ---------------------------------
mutant always-on "D1. " "$G" \
    '[ "$LORO_CAPS" = "on" ] || exit 0' \
    '[ "$LORO_CAPS" = "on" ] || true' \
    "a repository that never declared a loro would be governed by a vocabulary rule it never adopted — the policy expansion every jurisdiction section in this engine refuses."

mutant switch-not-declared "E3. " "$C" \
    'LORO_CAPS="on"' \
    'LORO_CAPS_UNSET="on"' \
    "the switch would exist only in the guard's own head, and no adopter could find it to turn it off."

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d properties proven load-bearing\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d properties proven, %d NOT load-bearing\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
