#!/usr/bin/env bash
#
# guard-row-currency-commits.mutation.sh — PROVES THE ROW-CURRENCY SUITE CAN FAIL.
#
# WHY THIS FILE EXISTS, AND IT IS NOT A COMPLETENESS EXERCISE.
# On 2026-09-04 this guard was found to be blind to a multi-line commit message
# — the house style — because its command splitter cut inside quotes. Seventy-six
# green cases said nothing about it, because every one of them handed the guard a
# ONE-LINE message. The suite could not have gone red for that reason, and nobody
# had ever asked it to.
#
# The defect was found by the author of a SIBLING guard, while writing that
# guard's own harness. That is the argument for this file: a property nobody has
# watched fail is a property nobody has tested, and a command classifier that
# stops recognizing `git commit` leaves the hook wired, registered, executable
# and PASSING over zero enforcement.
#
# Measured before the repair (docs/verification/row-currency-splitter-gap-2026-09-05/):
# 189 of 592 commit/merge calls at a governed main checkout — 31.9% — were never
# recognized at all, and 29 commits reached richos-hq's main carrying a section-3
# row whose own pin no longer matched the tree.
#
# The harness is scripts/lib/mutation-harness.sh — one loop, shared. Run
# directly, or let row-currency.test.sh run it, which it does: a harness nobody
# runs proves nothing about anything.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "the row-currency landing guard" "scripts/hooks/row-currency.test.sh"

G="scripts/hooks/guard-row-currency-commits.sh"

# --- 1. THE COMMAND CLASSIFIER SEES THE COMMANDS THAT ACTUALLY HAPPEN -------
# THE HEADLINE MUTANT, and its `new` text is the line this guard shipped with
# from 2026-08-30 to 2026-09-05. Restoring it is not a hypothetical regression:
# it is the measured one.
mutant naive-segment-split "multi-line message not refused" "$G" \
    'segments = top_level_segments(executable_text(cmd))' \
    'segments = re.split(r"(?:\\|\\||&&|[;\\n|])", cmd)' \
    "a multi-line commit message — the house style — would be cut mid-quote, both halves would fail to shlex, no git commit would be recognized in the call at all, and the guard would exit 0 having looked at nothing."

# --- 2. IT REFUSES AT ALL --------------------------------------------------
# Without this the mutant above could pass for the wrong reason: a guard that
# never refuses anything makes every negative case red, including the one the
# splitter mutant is aimed at.
mutant refuses-to-refuse "created-work case not refused" "$G" \
    '        "$BODY" "$RC_RECORD_REPO/$RC_RECORD_REL" >&2{NL}    exit 2 ;;' \
    '        "$BODY" "$RC_RECORD_REPO/$RC_RECORD_REL" >&2{NL}    exit 0 ;;' \
    "the guard would find every stale row, print the whole refusal, and let the landing through anyway — a warning wearing a guard's clothes."

# --- 3. A HEREDOC PAYLOAD IS A DOCUMENT ------------------------------------
# The other half of the same subject: the splitter fix is about the commits this
# guard could not SEE, and this is about the commits it saw that were never
# there. `cat > runbook.md <<EOF` with a `git commit` line inside it is a
# document being written, and refusing the WRITE is a false refusal of a file.
mutant heredoc-payload-is-a-command "a documented command was treated as a commit" "$G" \
    'segments = top_level_segments(executable_text(cmd))' \
    'segments = top_level_segments(cmd)' \
    "a runbook, a test fixture or a wiki page that quotes 'git commit' would be classified as a commit, and this guard would then run the row predicate and could refuse the write."

# --- 4. ...AND THE EXCEPTION THAT KEEPS THE RECALL -------------------------
# `bash <<EOF` really does execute its body. Without the shell exception the
# mutant above becomes a way to launder a landing straight past the guard, which
# is the direction a blanking fix always invites.
mutant shell-heredoc-blanked-too "shell-fed heredoc not refused" "$G" \
    'if b > a and not _SHELL_CONSUMER.search(_lines[i][:m.start()]):' \
    'if b > a:' \
    "a heredoc piped into a shell would be blanked along with the documents, so a shell-fed body carrying a landing would go unexamined. (Backticks are deliberately absent from this sentence: the harness passes it through a double-quoted shell word, and a backticked example would EXECUTE.)"

mutation_end
