#!/usr/bin/env bash
#
# ci-affected-units.sh — the verification units a DIFF can affect.
#
# ===========================================================================
# WHY THIS EXISTS: THE PROBLEM IS INFLOW, NOT PORTABILITY
# ===========================================================================
# Measured on 2026-09-09: 101 of this engine's 120 suites were created in the
# previous twelve days, 35 of them on one day. About eight suites land per day
# that have never run on Linux. Fixing today's red list therefore buys one green
# run, and next week's arrivals break it again — the full pass is the wrong
# instrument for that, because it takes 123 minutes and so it runs once a week
# at best, long after the author has moved on.
#
# The instrument that matches inflow is this one: a check, on every push, that
# runs the suites THIS DIFF can affect, on Linux, in a couple of minutes. A new
# suite gets its first Linux execution the day it lands, by its author, while
# they still have the context to fix it. Nothing accumulates.
#
# ===========================================================================
# THE MAPPING, AND THE MEASUREMENT THAT SAYS IT IS ENOUGH
# ===========================================================================
# For each changed path, in order:
#
#   1. THE PATH IS ITSELF A SUITE  -> its own unit(s).
#   2. A SIBLING SUITE EXISTS      -> `<stem>.test.sh` beside it.
#   3. A SUITE NAMES ITS BASENAME  -> literal matching across every suite.
#      orchestration.config instead follows content-bound key/read contracts;
#      an unqualified relationship remains an explained conservative selection.
#      This is the load-bearing rule, and it was verified before being relied
#      on rather than assumed: all 96 files under `scripts/hooks/` are named by
#      at least one suite (`ci-affected-units.test.sh` case A5 re-derives that
#      and fails if it ever stops being true).
#   4. THE SECTIONED SUITE NAMES IT -> only the SECTIONS whose own bodies
#      mention it, not all 24. A one-line change to one guard costs that
#      guard's section, which is the whole reason `--only` exists.
#
# ===========================================================================
# AN UNMAPPED EXECUTABLE IS A FAILURE, AND THAT IS THE POINT
# ===========================================================================
# The dangerous case is not a changed file that maps to too much. It is a
# changed file that maps to NOTHING, because then this check exits 0 having run
# nothing and the push is certified by an empty set — the "18/18 suites" defect
# with a diff filter bolted on.
#
# So a changed file that is EXECUTABLE MACHINERY (`.sh`, `.py`, or anything with
# a shebang, under the engine) and that no suite names is reported by
# `--strict` as a failure, naming the file. The remedy is the engine's own
# doctrine and is never "add it to a list here": give it a suite, or make an
# existing suite name it. Prose, data and documentation map to nothing by
# design and are reported as such without failing.
#
# Usage:
#   ci-affected-units.sh --range <base>..<head>   compare two commits
#   ci-affected-units.sh --base <ref>             <ref>..HEAD
#   ci-affected-units.sh --paths-file <path>      one changed path per line
#   ci-affected-units.sh --paths <p>[,<p>…]       changed paths inline
#   options: --strict   unmapped executable machinery FAILS (exit 1)
#            --explain  print the mapping, path by path, to stderr
#
# Output: one unit id per line on stdout, LC_ALL=C sorted and unique. Empty
# output with exit 0 means "this diff can affect no suite", which is a real
# answer for a docs-only change and is announced on stderr.
#
# Exit codes:
#   0  the mapping succeeded (the unit list may legitimately be empty)
#   1  --strict, and a changed executable maps to no suite (each one named)
#   2  usage, or the diff could not be read
# ===========================================================================

# The read-only implementation is lib/affected_units.py. Config selections use
# lib/verification_inputs.py and the content-bound verification-dependencies.json.
# --staged reads HEAD..INDEX; --working [--base REF] reads REF..WORKTREE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$SCRIPT_DIR/lib/affected_units.py" "$@"
