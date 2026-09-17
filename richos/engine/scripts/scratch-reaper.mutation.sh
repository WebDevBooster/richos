#!/usr/bin/env bash
#
# scratch-reaper.mutation.sh — EVERY SAFETY THIS REAPER CLAIMS, REMOVED ONE AT
#                              A TIME, WITH THE SUITE WATCHED GOING RED.
#
# ===========================================================================
# WHY THIS FILE IS NOT OPTIONAL FOR THIS PARTICULAR PROGRAM
# ===========================================================================
# scratch-reaper.test.sh is, in the main, a suite of things that must NOT
# happen: a live session's scratch survives, a registered workspace survives, a
# checkout survives, an undecidable verdict survives. EVERY ONE OF THOSE CASES
# PASSES PERFECTLY AGAINST A REAPER THAT DELETES NOTHING AT ALL, and a reaper
# that deletes nothing is the state this whole mechanism was ordered to end.
#
# So a green suite over a deleter proves nothing until somebody has watched
# each guarantee go red for the right reason. Each mutant below removes exactly
# one property from a THROWAWAY COPY of the engine — the shipped file is never
# opened for writing — and asserts that the suite fails AT THE NAMED CASE.
#
#   M1  the liveness check, gutted           -> S1  (a live session is deleted)
#   M2  INDETERMINATE collapsed into dead    -> S3
#   M3  wall 3, the registered workspaces    -> S2
#   M4  wall 2, the .git in the tree         -> S4
#   M5  the log write                        -> S5
#   M6  --dry-run deletes                    -> S6
#   M7  an undeclared threshold gets a default instead of a refusal -> S9
#   M8  a held temp workspace treated as abandoned -> S10b
#   M9  the orphan rule's "a running process could own this" -> S7b
#   M10 the nightly retention                -> S8
#
# M1 IS THE ONE THE BRIEF ASKED FOR AND IT IS THE RIGHT ONE TO ASK FOR: it guts
# the two places that read "is this session running" and demands that the suite
# then reports a LIVE SESSION'S SCRATCH DELETED. A liveness check that has
# quietly stopped working is invisible from every other angle — the program
# still runs, still logs, still ends with a verdict line, and deletes somebody's
# work while they are using it.
#
# Run from scratch-reaper.test.sh's own section of contract-integrity.test.sh,
# for the reason scripts/lib/mutation-harness.sh gives: a *.mutation.sh is not
# discovered by the *.test.sh runner, and eight harnesses in this engine were
# once run by nothing at all.

set -uo pipefail
ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

mutation_begin "scratch-reaper safety properties" "scripts/scratch-reaper.test.sh"

LIB="scripts/lib/scratch-reaper.py"

mutant M1.liveness-gutted "S1 " "$LIB" \
    "if session_id in self.running:{AND}if name in self.live.running:" \
    "if False:{AND}if False:" \
    "With both readings of the running set removed, a session whose process is
     alive and whose session file names it must be reported as deleted."

mutant M2.indeterminate-collapsed "S3 " "$LIB" \
    "if cutoff is not None and newest_mtime >= cutoff:" \
    "if False:" \
    "An unattributed running process no longer makes anything undecidable, so
     INDETERMINATE has been folded into dead — the 2026-08-31 defect exactly."

mutant M3.registered-wall-removed "S2 " "$LIB" \
    "if inside(reg, real) or inside(real, reg):" \
    "if False:" \
    "Wall 3 no longer recognizes a registered workspace, so an agent's
     workspace inside a dead session's scratch is deleted with it."

mutant M4.git-wall-removed "S4 " "$LIB" \
    "if has_git:" \
    "if False:" \
    "Wall 2 no longer notices a checkout in the tree, so a repository living
     in dead scratch is removed."

mutant M5.log-write-removed "S5 " "$LIB" \
    "write_log(log_path, lines)" \
    "pass" \
    "Deletions happen and nothing records them. 'Every deletion is on the
     record' is the half of the order that makes the other half auditable."

mutant M6.dry-run-deletes "S6 " "$LIB" \
    "    if args.apply:{NL}        deleted, freed, failures = reaper.apply(args.log or default_log())" \
    "    if True:{NL}        deleted, freed, failures = reaper.apply(args.log or default_log())" \
    "The plan deletes. A dry run that acts is worse than no dry run, because
     the next person reads it expecting to be shown rather than obeyed."

mutant M7.undeclared-gets-a-default "S9 " "$LIB" \
    "        v = (os.environ.get(name) or \"\").strip(){NL}        if not v:" \
    "        v = (os.environ.get(name) or \"\").strip() or \"60\"{NL}        if False:" \
    "An undeclared threshold silently becomes a number nobody chose — the
     third-party-default failure, arriving through the back door."

mutant M8.held-workspace-deleted "S10b" "$LIB" \
    "if holder:" \
    "if False:" \
    "A temp workspace a process is sitting in is treated as abandoned."

mutant M9.orphan-rule-inverted "S7b" "$LIB" \
    "if newest >= oldest_start:" \
    "if False:" \
    "A file written after a running session started is no longer that
     session's, so live working files in a scratch root are deleted."

mutant M10.nightly-retention-removed "S8 " "$LIB" \
    "if i < keep:" \
    "if False:" \
    "The declared retention keeps nothing, so every release and log is deleted
     including the newest."

mutation_end
