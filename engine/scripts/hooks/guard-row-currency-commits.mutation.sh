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

# ===========================================================================
# CHECK 3 — THE HEADLINE WARRANT
# ===========================================================================
# Added 2026-09-06, and the mutants below are aimed at one measured failure:
# eleven of the sixteen rows re-derived and found overtaken that day had a
# MATCHING blob pin. Everything in CHECK 1 was green while eleven headlines
# were false. So the properties that matter are (a) the digest is actually
# compared, (b) it covers the row and not the warrant that carries it,
# (c) the normalization boundary holds in BOTH directions, (d) the two settings
# really are the only two, (e) the not-required default really is a default and
# really can be escalated, and (f) the verifier's two refusals refuse.
P="scripts/lib/row-currency.py"
V="scripts/row-headline-verify.sh"

# --- 5. THE HEADLINE MUTANT: the digest is compared at all ------------------
mutant headline-never-compared "a correction under an unchanged headline was allowed" "$P" \
    '        if dm.group("digest") != want:' \
    '        if False:' \
    "a correction could be appended under a headline nobody re-read and the landing would go through — which is the 2026-09-06 defect exactly, with a green warrant on the same line."

# --- 6. THE DIGEST EXCLUDES THE WARRANT THAT CARRIES IT ---------------------
# Without this, adopting a warrant CHANGES the row, so the act of stamping a
# row makes it stale and no row can ever be current. A contract nobody can
# satisfy is a contract that gets deleted.
mutant headline-digests-itself "a current headline warrant was refused" "$P" \
    '    return line[:m.start()] + (tail[nxt.start():] if nxt else "")' \
    '    return line' \
    "the digest would cover the warrant carrying it, so writing the warrant would invalidate it and no row could ever be stamped current."

# --- 7/8. THE NORMALIZATION BOUNDARY, BOTH DIRECTIONS ----------------------
# These two are a pair and neither is meaningful alone: a normalizer that
# strips everything passes the formatting case, and one that strips nothing
# passes the reworded case.
mutant headline-normalizes-everything "changing one word of the headline DOES cost a re-read" "$P" \
    '_HEADLINE_NORM_DROP = re.compile(r"[*_`|]")' \
    '_HEADLINE_NORM_DROP = re.compile(r"[^ ]")' \
    "every row would digest to the same value, so rewriting the entire headline would cost nothing and the check would be a decoration."

mutant headline-normalizes-nothing "re-emphasizing a phrase costs no re-read" "$P" \
    '_HEADLINE_NORM_DROP = re.compile(r"[*_`|]")' \
    '_HEADLINE_NORM_DROP = re.compile(r"(?!x)x")' \
    "re-bolding a phrase or reflowing a cell would demand a fresh re-read, which is ceremony over formatting and the fastest way to get a check waived."

# --- 9/10. THERE ARE EXACTLY TWO SETTINGS ---------------------------------
mutant headline-evidence-optional "a headline warrant with neither a command nor an unverified declaration is refused" "$P" \
    '            if not em or not em.group("cmd").strip():' \
    '            if False:' \
    "a headline could carry a digest and a sentence of prose — a claim written in a voice that sounds checked, which is the shape the CEO's own rule about briefs exists to forbid."

mutant headline-bare-unverified "an unverified declaration with no real reason is refused" "$P" \
    'MIN_UNVERIFIED_WORDS = 4' \
    'MIN_UNVERIFIED_WORDS = 0' \
    "a bare marker would exempt a row, which is a way to switch the check off while looking like a considered decision."

# --- 11. A FINISHED ROW IS EXEMPT, AND COUNTED -----------------------------
mutant headline-terminal-not-exempt "a terminal row was not counted by the HC census" "$P" \
    '            if sm and sm.group("tok") in terminal:' \
    '            if sm and sm.group("tok") in ():' \
    "a CLOSED row would be asked to keep a headline current about work that has finished, and the census would stop distinguishing an exempt row from a checked one."

# --- 12/13. THE DEFAULT IS A DECISION, IN BOTH DIRECTIONS ------------------
# The default matters as much as the teeth do, and for the reason this project
# has three same-day instances of: a blocking check with a large false-positive
# class gets waived, and a waived check is a dead one. The mechanical sweep
# appends rows to this record on its own and cannot state a warrant.
#
# READ THE NEXT MUTANT'S REASON CAREFULLY, BECAUSE ITS EARLIER WORDING WAS READ
# BACKWARDS AND COST A DAY. It said "declaring ROW_HEADLINE_SECTIONS would
# refuse the next landing and every landing after it", which sounds like an
# argument AGAINST declaring the jurisdiction key. It is the opposite: it is
# what would happen IF THIS MUTATION WERE THE SHIPPED CODE — if the default
# blocked — and this mutant exists to guarantee that it does not. Declaring
# ROW_HEADLINE_SECTIONS is safe precisely BECAUSE this property holds.
#
# MEASURED ON THE REAL RECORD, 2026-09-06, against a throwaway clone of
# richos-hq at `4f2c0a804f30` with its sibling roots symlinked, running the
# shipped guard over a simulated `git commit`:
#
#   undeclared                                  exit 0, HEADLINE-NOT-ADOPTED
#   ROW_HEADLINE_SECTIONS="3" declared          exit 0, sections=3 rows=27
#                                               missing=27, a NOTE and nothing
#                                               refused
#   ...plus a fresh mechanical-sweep row append exit 0, rows=28 missing=28
#   a row that DOES carry a stale headline       exit 2, HEADLINE-STALE at 3.98
#   ROW_HEADLINE_REQUIRED="1"                   exit 2, 27 HEADLINE-UNDERIVABLE
#   both keys removed again (negative control)  exit 0, sections=-
#
# So the two keys are NOT interchangeable and must never be described as two
# equivalent one-line switch-ons: the jurisdiction key costs nothing on the day
# it lands, and the REQUIRED key is the one that would refuse every landing
# until 27 rows were rewritten.
mutant headline-default-blocks "the default made a warrantless row a refusal" "$P" \
    '            if headline_required:' \
    '            if True:' \
    "the DEFAULT would block: with ROW_HEADLINE_REQUIRED unset, declaring ROW_HEADLINE_SECTIONS would then refuse the next landing and every landing after it, including the ones the mechanical sweep writes, and the declaration would be deleted within the day. Measured on the real record at richos-hq `4f2c0a804f30`, the shipped default does the opposite: exit 0, 27 rows named, nothing refused, and a fresh sweep append still exit 0. This mutant is what makes declaring the jurisdiction key safe — it is not a reason to avoid declaring it."

mutant headline-required-toothless "ROW_HEADLINE_REQUIRED=1 did not refuse a warrantless row" "$P" \
    '            if headline_required:' \
    '            if False:' \
    "the escalation would be a setting that reads as switched on and refuses nothing, which is the green-tick-over-a-scanner-that-never-ran failure this engine keeps finding in itself."

# --- 14/15. THE VERIFIER REFUSES BEFORE IT RUNS ---------------------------
# The only two mutants here whose failure mode is worse than a missed defect:
# this tool executes strings taken out of a document, and one of the two
# refusals exists because a standing order says this machine must not make a
# sound.
mutant verifier-runs-sound "a sound-capable command was run or not refused" "$V" \
    '    if SOUND.search(cmd):' \
    '    if False and SOUND.search(cmd):' \
    "a row whose evidence command drives a speech synthesizer would be executed, and the standing silence order on this machine would be broken by a verification tool."

mutant verifier-runs-mutations "a mutating command was run or not refused" "$V" \
    '    if MUTATES.search(cmd):' \
    '    if False and MUTATES.search(cmd):' \
    "a row whose evidence command pushes, deletes or installs would be executed by the tool that is supposed to be reading the tree, so verifying the record could change it."

mutation_end
