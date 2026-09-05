#!/usr/bin/env bash
#
# guard-unresolved-claims.mutation.sh — PROVES THE CLAIM-CHECK SUITE CAN FAIL.
#
# This gate reads English in order to decide which question to ask git, and a
# reading rule has two failure directions that look identical from outside:
# it can stop understanding a sentence (and refuse a true statement), or it can
# understand every sentence as an excuse (and refuse nothing). Fifty-five green
# ticks distinguished neither, which is how it came to block a reply that said
# plainly "committed on the branch, not landed" -- the sentence agreed with the
# repository exactly, and the gate stopped the turn anyway.
#
# So the polarity rule is mutated in BOTH directions, and the suite has to go
# red at a NAMED case each time.
#
# The harness is scripts/lib/mutation-harness.sh — one loop, shared. Run
# directly, or let guard-unresolved-claims.test.sh run it, which it does.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the claim check" "scripts/hooks/guard-unresolved-claims.test.sh"

A="scripts/hooks/guard-unresolved-claims.py"

# --- 1. POLARITY IS READ AT ALL -------------------------------------------
# The 2026-09-03 and 2026-09-05 defect in one edit: every state claim is treated
# as an assertion that the state HOLDS, so a sentence saying the opposite is
# refused for agreeing with the repository.
mutant polarity-ignored "zp1." "$A" \
    '            if pol == "positive":' \
    '            if True:' \
    "a reply that correctly says a commit has NOT landed would be blocked for saying so -- the gate refusing accuracy, which is the one thing it must never do."

# --- 2. ...AND IT IS NOT AN OFF SWITCH ------------------------------------
# The other direction, and the one a negation rule invites. If every claim reads
# as a denial, nothing is ever refused and the gate is a decoration.
mutant everything-reads-as-a-denial "zq4." "$A" \
    '    if NEG_CUE.search(NEG_EMPHATIC.sub(" ", clause[:rel])):{NL}        return "negated"' \
    '    if True:{NL}        return "negated"' \
    "every landing claim would read as a denial, so the 2026-09-01 failure -- a commit reported as landed while it sat on a branch -- would pass unexamined."

# --- 3. THE CLAUSE IS THE SCOPE, NOT THE SENTENCE -------------------------
# Measured: a rule that looked for a negation anywhere in the sentence demoted
# 113 perfectly positive claims -- every "landed, no worktrees, no live agents"
# status line -- to report-only. The clause boundary is what keeps the rule from
# being a quiet off switch.
mutant scope-widened-to-the-sentence "zq1." "$A" \
    '    if NEG_CUE.search(NEG_EMPHATIC.sub(" ", clause[:rel])):{NL}        return "negated"' \
    '    if NEG_CUE.search(NEG_EMPHATIC.sub(" ", sentence)):{NL}        return "negated"' \
    "a negation anywhere in the sentence would silence a landing claim it does not govern, which is 113 real status lines in the corpus going unchecked."

# --- 4. THE TERMINATOR BOUNDARY, WHICH MARKDOWN MAKES NECESSARY -----------
# SENTENCE_SPLIT needs whitespace after a full stop and markdown does not supply
# it, so "...never the model.** Landed `228ccf5`" arrives as ONE sentence.
# Without a clause boundary at the terminator, that `never` governs a landing
# three words later. Four of fifteen readings turned from wrong to right on this
# one character class when it was measured.
mutant terminator-is-not-a-boundary "zq2." "$A" \
    'r"[.!?:,]|\s+--\s+|\s+\u2014\s+|\bbut\b|\band\b|\bwhile\b|\bthough\b"' \
    'r"[,]|\s+--\s+|\s+\u2014\s+|\bbut\b|\band\b|\bwhile\b|\bthough\b"' \
    "a negation in a previous markdown-bolded sentence would govern the landing claim after it, and the commonest shape of report in this project is exactly that."

mutation_end
