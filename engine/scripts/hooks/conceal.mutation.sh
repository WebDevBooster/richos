#!/usr/bin/env bash
#
# conceal.mutation.sh — PROVES THE CONCEALMENT CLAUSE'S SUITE CAN FAIL.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# The concealment clause is the answer to a question the CEO asked out loud on
# 2026-09-10: how does he know that a brief telling a teammate to make a
# warning "invisible to him" will never happen again. A row of green ticks is
# not an answer to that question either. Ticks prove a suite ran; they do not
# prove it would have gone red had the property been absent.
#
# And this particular guard has an unusually cheap way of looking healthy while
# deciding nothing. Its blocking cases assert EXIT 2 — which is also what
# verify-agent-prompt.sh exits when it cannot start at all, when python3 is
# missing, when the root will not resolve, and when any of the OTHER six checks
# refuses. A concealment clause deleted outright would leave most of this
# suite's shape intact. That is precisely the confusion that left probe Layer K
# green for weeks over a secrets scanner that never ran (2026-08-31).
#
# So: take the SHIPPED source, remove ONE property at a time, and assert
#   1. verify-agent-prompt.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement matching nothing produces a
#      green run that looks exactly like a green run, which is the same trap
#      one level up).
#
# ===========================================================================
# HALF THESE MUTANTS MAKE THE GUARD STRICTER, AND THE SUITE MUST STILL GO RED
# ===========================================================================
# Seven of the mutants below (over-block-*) do not weaken the clause at all.
# They widen it — they delete a false-positive defense, so the guard refuses
# MORE. Every one of them must turn the suite red anyway, and that is the most
# important property this file proves.
#
# A guard that blocks too much is not a safe failure here. It is the failure
# that gets the guard waived, and a guard waived habitually is a guard somebody
# switches off. This project has three of those already — g11, g12 and g13, all
# recorded on one day, each a blocking prose gate whose false positives were
# waived on the day it fired. The must-ALLOW half of the suite is what stands
# between this clause and that list, and these mutants are what prove that half
# is load-bearing rather than decorative.
#
# ===========================================================================
# WHY EVERY PATCH ARRIVES ON STDIN AND NEVER AS A SHELL ARGUMENT
# ===========================================================================
# Inherited from interactive-prompt.mutation.sh, and the reason is worth
# repeating rather than citing: the first draft of that file passed mutations
# as quoted arguments with human-readable reasons beside them, two reasons
# named a command in backticks, and the shell EXECUTED THEM. Here the patch
# bodies are full of regular expressions, backslashes and quote characters —
# the worst possible thing to send through three layers of shell quoting. They
# come in through a single-quoted heredoc, which the shell does not interpret
# at all, and are matched byte-for-byte.
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/conceal.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t conceal-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

# Reads a patch on stdin as:  <<<OLD\n...\n>>>NEW\n...\n  and applies it once.
cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path = sys.argv[1]
spec = sys.stdin.read()
if "<<<OLD\n" not in spec or "\n>>>NEW\n" not in spec:
    sys.stderr.write("malformed patch spec\n"); sys.exit(4)
old = spec.split("<<<OLD\n", 1)[1].split("\n>>>NEW\n", 1)[0]
new = spec.split("\n>>>NEW\n", 1)[1]
if new.endswith("\n"):
    new = new[:-1]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n")
    sys.stderr.write("\n".join("    " + l for l in old.split("\n")) + "\n")
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# shellcheck source=../lib/stopwatch.sh
. "$ENGINE_ROOT/scripts/lib/stopwatch.sh"
# shellcheck source=../lib/mutation-pool.sh
. "$ENGINE_ROOT/scripts/lib/mutation-pool.sh"
mut_pool_init
MUT_WALL_T0="$(sw_now_ms)"

_mutant_body() {
    local name="$1" want="$2" rel="$3" why="$4"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/verify-agent-prompt.sh" \
       "$ENGINE_ROOT/scripts/hooks/verify-agent-prompt.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$dir/scripts/lib/"
    # The unevaluated-payload notice is sourced only if present; copied so the
    # mutant exercises the same code path the shipped hook does.
    [ -f "$ENGINE_ROOT/scripts/lib/unevaluated-notice.sh" ] \
      && cp "$ENGINE_ROOT/scripts/lib/unevaluated-notice.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/orchestration.config" "$dir/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi

    # RICHOS_MUTATION_INNER stops the copied suite reaching for this harness.
    ( cd "$dir" && RICHOS_MUTATION_INNER=1 bash "$dir/scripts/hooks/verify-agent-prompt.test.sh" ) \
        >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        return 1
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at "%s" (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | head -5 | sed 's/^/          /'
        return 1
    fi
    printf '  PASS  %s — removing it turns "%s" red\n' "$name" "$want"
    return 0
}

# mutant <name> ... [patch on stdin] — a SUBMISSION, not an execution. The
# heredoc is consumed HERE, in the parent, because a pool worker runs in a
# backgrounded subshell that does not carry it (interactive-prompt.mutation.sh
# records the run where converting this wrapper naively drained zero
# submissions and printed "all 0 properties proven load-bearing").
mutant() {
    local _name="$1"
    local _patch="$SANDBOX/patch.$_name"
    mkdir -p "$SANDBOX"
    cat >"$_patch"
    mut_pool_submit "$_name" _mutant_body_with_patch "$_patch" "$@"
}

_mutant_body_with_patch() {
    local _patch="$1"
    shift
    _mutant_body "$@" <"$_patch"
}

echo "=== the concealment clause: every property, proven by removing it ==="

H="scripts/hooks/verify-agent-prompt.sh"

# --- 1. IT REFUSES AT ALL ---------------------------------------------------
mutant refuses-to-refuse "REFUSE the exact 2026-09-10 brief line" "$H" \
  'the clause would match the concealment order, compose the whole refusal, and let the spawn through anyway — a warning wearing a guard costume, and the brief dispatched unchanged.' <<'PATCH'
<<<OLD
    else
      FAIL=1
      FAIL_REASONS+=("concealment-clause: this brief instructs someone
>>>NEW
    else
      FAIL=0
      FAIL_REASONS+=("concealment-clause: this brief instructs someone
PATCH

# --- 2. THE LINE THE WHOLE ROW EXISTS FOR ----------------------------------
mutant no-make-invisible-rule "REFUSE the exact 2026-09-10 brief line" "$H" \
  'the 2026-09-10 brief line itself would pass. This is the one construction the CEO asked the question about.' <<'PATCH'
<<<OLD
 ("make-it-invisible-to-him",
  r"\bmak\w*\b[^.\n]{0,60}?\b(?:invisible|less visible|not visible|unreadable|imperceptible)\b"
>>>NEW
 ("make-it-invisible-to-him",
  r"(?!x)x\bmak\w*\b[^.\n]{0,60}?\b(?:invisible|less visible|not visible|unreadable|imperceptible)\b"
PATCH

# --- 3. THE OTHER SEVEN CONSTRUCTIONS ARE NOT DECORATION -------------------
mutant no-verb-from-him-rule "REFUSE hiding a failure from him" "$H" \
  'the plainest concealment sentence in English — hide the failure from him — would pass, and only the exact 2026-09-10 wording would be caught. A guard that catches one sentence is a memorial, not a defense.' <<'PATCH'
<<<OLD
 ("verb-from-him",
  r"\b%s\b[^.\n]{0,60}?\b(?:from|off|out of|away from)\s+%s" % (V, T)),
>>>NEW
 ("verb-from-him",
  r"(?!x)x\b%s\b[^.\n]{0,60}?\b(?:from|off|out of|away from)\s+%s" % (V, T)),
PATCH

mutant no-keep-off-screen-rule "REFUSE keeping a warning off his terminal" "$H" \
  'keeping a true warning off his screen is the incident restated with different verbs, and it would pass.' <<'PATCH'
<<<OLD
 ("keep-it-off-his-screen",
  r"\b(?:keep|keeps|keeping|kept|stay|stays|staying|remain|remains|remaining|sit|sits|leave|leaves)\b"
>>>NEW
 ("keep-it-off-his-screen",
  r"(?!x)x\b(?:keep|keeps|keeping|kept|stay|stays|staying|remain|remains|remaining|sit|sits|leave|leaves)\b"
PATCH

mutant no-user-visible-rule "REFUSE stripping prose from user-visible fields" "$H" \
  'the SECOND clause of the same 2026-09-10 brief — strip the instructional prose from every user-visible field — would pass. Both clauses were the same instruction; catching one of them is catching half an incident.' <<'PATCH'
<<<OLD
 ("strip-from-user-visible",
  r"\b(?:strip|remov|drop|shorten|downgrad|suppress|hid|conceal|mut|silenc)\w*\b"
>>>NEW
 ("strip-from-user-visible",
  r"(?!x)x\b(?:strip|remov|drop|shorten|downgrad|suppress|hid|conceal|mut|silenc)\w*\b"
PATCH

# --- 4. OVER-BLOCKING IS A FAILURE, NOT A SAFE DIRECTION -------------------
# The grammatical-target requirement. Draft 1 of this clause paired a
# suppression verb with the CEO anywhere in one sentence and measured 16 hits
# in 1,871 real briefs, 15 of them false. This mutant restores draft 1.
mutant over-block-loose-target "ALLOW a suppression verb and the CEO in one sentence, ungoverned" "$H" \
  'the CEO would only have to be MENTIONED near a suppression verb, not be its object. Measured on the real corpus that is 15 false refusals to 1 true one, and every one of them is a brief somebody has to waive on the day.' <<'PATCH'
<<<OLD
 ("verb-from-him",
  r"\b%s\b[^.\n]{0,60}?\b(?:from|off|out of|away from)\s+%s" % (V, T)),
>>>NEW
 ("verb-from-him",
  r"\b%s\b[^.\n]{0,120}?%s" % (V, T)),
PATCH

mutant over-block-no-prohibition-scrub "ALLOW a brief that FORBIDS concealment" "$H" \
  'a brief that FORBIDS concealment would be refused for containing the words it forbids. That is not a hypothetical: the sibling brief gate shipped with exactly this defect and its first real refusal, minutes later, was a prohibition (femcboost 34d23cf6d).' <<'PATCH'
<<<OLD
kept = [s for s in re.split(r'(?<=[.\n])', text) if not PROHIB.search(s)]
>>>NEW
kept = [s for s in re.split(r'(?<=[.\n])', text)]
PATCH

mutant over-block-no-quote-strip "ALLOW the incident quoted with no prohibition anywhere" "$H" \
  'every brief that DESCRIBES the incident — including the brief that commissioned this guard, and every future one about it — would be refused for quoting the sentence it is about. A guard that cannot be worked on is a guard that gets switched off.' <<'PATCH'
<<<OLD
text = re.sub(r'"[^"\n]{1,200}"', ' ', text)
>>>NEW
text = re.sub(r'(?!x)x"[^"\n]{1,200}"', ' ', text)
PATCH

mutant over-block-no-inline-code-strip "ALLOW a fixture named in a code span, no prohibition anywhere" "$H" \
  'a brief citing the offending line as a code span — which is how a specification names a string — would be refused. This engine exempts inline code by construction everywhere else; an exception here would be a surprise, and surprises get waived.' <<'PATCH'
<<<OLD
text = re.sub(r'`[^`\n]+`', ' ', text)
>>>NEW
text = re.sub(r'(?!x)x`[^`\n]+`', ' ', text)
PATCH

mutant over-block-raw-prompt "ALLOW the historical line inside a code fence" "$H" \
  'the clause would read the RAW prompt instead of the sanitized one, so a fenced block, a blockquote or an HTML comment would accuse the brief that merely contains it — the forged-marker defect this file already fixed twice for the other two opt-outs.' <<'PATCH'
<<<OLD
  CONCEAL_HITS="$(printf '%s' "$(sanitized_prompt)" | python3 "$CONCEAL_PY" 2>/dev/null)"
>>>NEW
  CONCEAL_HITS="$(printf '%s' "$PROMPT" | python3 "$CONCEAL_PY" 2>/dev/null)"
PATCH

mutant over-block-target-not-anchored "ALLOW removing rows from the CEO-TODOs file" "$H" \
  'the CEO would no longer have to END the noun phrase, so "from the CEO-TODOs file", "from the CEO handoff" and "from the CEO briefing document" would all read as the CEO being the object. Three ordinary record chores, refused.' <<'PATCH'
<<<OLD
     r"|the\s+CEO(?![\w'’-])%s)") % (_END, _END)
>>>NEW
     r"|the\s+CEO)") % (_END,)
PATCH

# --- 5. THE ESCAPE HATCH MUST BE REAL, AND MUST NOT BE A RUBBER STAMP ------
mutant filler-ack-exempts "two-word conceal-ack reason exempts nothing" "$H" \
  'a reason made of filler - "yes", "it is", "n/a" - would clear the guard, which turns an auditable exception into a keyword anyone types to make the refusal go away.' <<'PATCH'
<<<OLD
      if [ "$CONCEAL_ACK_WORDS" -ge 3 ] && [ "$CONCEAL_ACK_CHARS" -ge 12 ]; then
>>>NEW
      if [ "$CONCEAL_ACK_WORDS" -ge 0 ] && [ "$CONCEAL_ACK_CHARS" -ge 0 ]; then
PATCH

# The BARE marker is refused one step earlier, by the `.+` in the grep that
# looks for the line at all - a separate property from the word count, and the
# harness is the reason both are named rather than one standing for both.
# THE BARE-MARKER CASE HAS NO MUTANT, AND THAT IS A FINDING RATHER THAN AN
# OMISSION. A mutant was written for it and then deleted, because there is no
# single mutation that turns "bare conceal-ack marker exempts nothing" red: an
# empty reason is refused THREE times over — the `.+` in the grep that looks
# for the line, the `-n` guard on the extracted reason, and the word count —
# and any one of them surviving keeps the case green. The mutation that forced
# all three at once was not a mutant, it was a rewrite, and it broke the
# substantive-ack case as collateral, which is how a harness lies to you.
#
# The property the bare marker shares with a filler reason — a marker with no
# argument behind it exempts nothing — is proven by filler-ack-exempts above.
# The redundancy is left in the hook deliberately; it is the one place in this
# clause where being wrong means an exception granted silently.

mutant forged-ack-in-fence-exempts "conceal-ack forged inside a code fence still blocks" "$H" \
  'an opt-out the prompt merely QUOTES — from a file, an example, another agent report — would activate the opt-out. Two other checks in this same file were fixed for exactly this, which is why the stripper is hoisted and shared.' <<'PATCH'
<<<OLD
    if printf '%s' "$(sanitized_prompt)" | grep -E >/dev/null '^[[:space:]]*conceal-ack:[[:space:]]*.+'; then
      CONCEAL_ACK_LINE="$(printf '%s' "$(sanitized_prompt)" | grep -oE '^[[:space:]]*conceal-ack:[[:space:]]*.+' | sed -n '1p' | sed -E 's/^[[:space:]]*//')"
>>>NEW
    if printf '%s' "$PROMPT" | grep -E >/dev/null '^[[:space:]]*conceal-ack:[[:space:]]*.+'; then
      CONCEAL_ACK_LINE="$(printf '%s' "$PROMPT" | grep -oE '^[[:space:]]*conceal-ack:[[:space:]]*.+' | sed -n '1p' | sed -E 's/^[[:space:]]*//')"
PATCH

mutant ack-leaves-no-record "the accepted conceal-ack is written to .claude/state/conceal-acks.log" "$H" \
  'the exception would be granted and leave no trace, so nobody could ever review how often concealment was waved through or on what grounds. An unauditable opt-out is the guard being off, one spawn at a time.' <<'PATCH'
<<<OLD
      } >>"$CONCEAL_LOG_DIR/conceal-acks.log" 2>/dev/null || true
>>>NEW
      } >>/dev/null 2>&1 || true
PATCH

# --- 6. THE REFUSAL MUST NAME THE PHRASE AND THE FIX -----------------------
mutant refusal-without-phrase "the refusal quotes the phrase it matched" "$H" \
  'the author would be told a brief was refused without being told WHICH SENTENCE did it — in a brief that can run to several thousand words. A refusal nobody can act on is a refusal that gets argued with.' <<'PATCH'
<<<OLD
Matched (${CONCEAL_NAME}): \"${CONCEAL_PHRASE}\".
>>>NEW
Matched something.
PATCH

mutant refusal-without-fix "the refusal names the correct fix (remove the condition, leave the warning)" "$H" \
  'the refusal would say only NO. The entire content of this guard is the alternative — remove the CONDITION, leave the warning visible — and a refusal that withholds it teaches nothing and gets routed around.' <<'PATCH'
<<<OLD
THE CORRECT FIX IS THE OPPOSITE ONE — remove the CONDITION that makes the warning fire, and leave the warning visible.
>>>NEW
Try something else.
PATCH

# --- 7. FAIL-CLOSED WHEN THE JUDGMENT IS GONE ------------------------------
# The direction that matters: a matcher that cannot run must REFUSE, not wave
# the brief through. With the analyzer pointed at nothing, every spawn is
# refused — so the CLEAN-prompt case is the one that must go red. If it stays
# green, the clause is failing OPEN and a broken guard is an absent guard.
mutant dead-matcher-fails-open "clean prompt" "$H" \
  'a lost or broken matcher would let every brief through unjudged while the hook still reported success — the exact defect that left probe Layer K green for weeks over a secrets scanner that never ran.' <<'PATCH'
<<<OLD
  CONCEAL_HITS="$(printf '%s' "$(sanitized_prompt)" | python3 "$CONCEAL_PY" 2>/dev/null)"
  CONCEAL_RC=$?
>>>NEW
  CONCEAL_HITS="$(printf '%s' "$(sanitized_prompt)" | python3 "$CONCEAL_PY.gone" 2>/dev/null)"
  CONCEAL_RC=$?
PATCH

# --- the verdict ------------------------------------------------------------
mut_pool_drain
mut_pool_require_submissions "$(basename "$0")"
PASS=$(( PASS + MUT_POOL_PASS ))
FAIL=$(( FAIL + MUT_POOL_FAIL ))
mut_pool_report_line "$(( $(sw_now_ms) - MUT_WALL_T0 ))"
mut_pool_cleanup

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== conceal mutations: $FAIL FAILED, $PASS proven load-bearing ==="
    exit 1
else
    echo "=== conceal mutations: all $PASS properties proven load-bearing ==="
    exit 0
fi
