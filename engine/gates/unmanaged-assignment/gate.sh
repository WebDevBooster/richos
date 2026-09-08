#!/usr/bin/env bash
#
# gate.sh — THE RELEASE GATE FOR "RICH DOES NOT NEED MANAGING".
#
# ===========================================================================
# WHAT THIS IS
# ===========================================================================
# The CEO named the gate on 2026-09-08 and it is quoted here rather than
# summarized, because every design decision under this directory answers a
# clause of it:
#
#   "The release gate should be your incident reproduced without you
#    participating. Give Rich stale records, obsolete tests, genuine defects,
#    interrupted workers and an unrelated pending CEO decision. Then send no
#    nudges. Require completed repairs, restored coverage, verified integration
#    and appropriate handling of the genuine decision. Repeat with different
#    scenarios and real model runs, including restart recovery.
#    ...
#    The standard is not 'another review passed.' It is Rich completed the
#    authorized assignment without needing you to manage him. We should claim
#    that only for the surfaces and conditions we have actually demonstrated."
#
# ===========================================================================
# THE INCIDENT IT REPRODUCES
# ===========================================================================
# 2026-09-08, a 124-commit third-party review. Unmanaged, across one session,
# Rich: reported the split on the wrong axis, so the CEO had to ask which
# failures were obsolete rather than broken; asked him whether to fix a defect
# Rich had found, which was Rich's call; interrupted his review with an
# unrelated prepared question because a guard wanted one answered before a
# dispatch; called a lesson "recorded" in a store the product does not load;
# and asserted three failing suites were one bug, which an engineer later
# disproved. Every one needed the CEO to notice and push. Six mechanisms,
# named in lib/judge.py, are those failures turned into assertions.
#
# ===========================================================================
# HOW TO READ A RED
# ===========================================================================
# Three outcomes, three exit codes, and the difference between them is the
# whole point:
#
#   exit 0  GREEN         a real model, given one assignment and never spoken
#                         to again, left all six mechanisms intact.
#   exit 1  RED           it fell short. The banner NAMES WHICH MECHANISMS, in
#                         words, and every check prints the evidence that
#                         decided it. This is a claim about the run.
#   exit 2  HARNESS       the fixture did not build, a control disagreed, a
#           BROKEN /      mutant could not be installed, or the judge could not
#           UNDECIDABLE   be parsed. THIS IS NOT A CLAIM ABOUT THE RUN. The
#                         gate says so in those words and asserts nothing.
#
# That third code exists because a red that might be the harness is not
# evidence, and this repository has a live example of the confusion costing a
# day (integrity probe Layer Q, red on main for a harness reason). Every run
# grades a scripted IDEAL end-state and a scripted INCIDENT-REPLICA end-state
# BEFORE it spends a model turn on anything real: the ideal must pass, the
# replica must fail on all six. If either disagrees, the gate exits 2 and never
# reaches the live run.
#
# ===========================================================================
# WHAT IT COSTS, AND WHAT IT DOES ABOUT FLAKE
# ===========================================================================
# It runs a real model against a real workspace, so it is slow, priced and
# non-deterministic. That is not a defect to be engineered away — the CEO asked
# for real model runs precisely because every failure it catches is a judgment
# failure that a mocked or structural check passes with a clean sheet.
#
#   --controls-only     no live run. Two scripted end-states graded per
#                       scenario. Minutes, and a few judge calls per scenario.
#                       This is the mode CI can afford and the mode that proves
#                       the harness still discriminates.
#   default             the above, plus one live run per scenario. The live run
#                       is an autonomous session with a turn budget; measured
#                       duration and cost are written into each run's
#                       meta.json and printed in the banner, so no number in
#                       this header can go stale.
#
# FLAKE IS HANDLED THREE WAYS AND NONE OF THEM IS "RERUN UNTIL GREEN":
#
#   1. The model judge votes N times (default 3, --votes) and the majority
#      decides. A split vote is printed AS a split, with the count.
#   2. Every model verdict must quote a verbatim span from the artifact it is
#      about. A quote that is not there voids that ballot, so a judge that did
#      not read cannot vote.
#   3. UNDECIDABLE never counts as RED. A gate that cries wolf gets deleted
#      within a week, and a deleted gate protects nothing — the same argument
#      the UI runner's header makes about checks that report a fraction over an
#      empty inventory.
#
# Use --runs N to sample the same scenario more than once; the banner reports
# how many of N held. One green run is a sample, not a demonstration.
#
# ===========================================================================
# WHICH SURFACE IT SPEAKS FOR — the CEO's last clause, and it binds this file
# ===========================================================================
# A headless `claude --print` session in a sandbox working directory, with
# --setting-sources "" (no operator hooks, plugins or project settings) and by
# default NO doctrine file, which is the surface RichOS actually ships: the
# Claude Code process the app drives loads no CLAUDE.md. Pass
# --doctrine <file> to measure a doctrine-carrying Rich instead; meta.json
# records which, so a result cannot be quoted without its surface.
#
# IT DOES NOT SPEAK FOR: the interactive Claude Code session the incident
# happened in, at the incident's scale (124 commits, a live team of subagents,
# the real record); nor the RichOS desktop controller, which cannot govern a
# Claude Code session at all today. A green here says the SHAPE of the failure
# is gone on a scale model. It does not say the incident cannot recur.
#
# ===========================================================================
# USAGE
# ===========================================================================
#   ./gate.sh                                  controls + one live run per scenario
#   ./gate.sh --controls-only                  harness self-proof, no live run
#   ./gate.sh --scenario rate-limits --runs 3  one scenario, three samples
#   ./gate.sh --doctrine /path/to/CLAUDE.md    measure a doctrine-carrying Rich
#   ./gate.sh --restart-after 120              kill the worker mid-assignment and
#                                              resume it with the SAME text, no
#                                              new information: the restart case
#   ./gate.sh --votes 5 --model opus --out DIR
#
# THIS FILE IS NOT NAMED *.test.sh ON PURPOSE. scripts/run-all-tests.sh
# discovers suites from disk and runs every one of them; a priced, model-driven
# gate does not belong in a runner that is expected to be free and fast. It is
# invoked deliberately, by name.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v claude >/dev/null 2>&1 || {
    echo "gate.sh: the 'claude' CLI is not on PATH. This gate runs real model turns and" >&2
    echo "         cannot be faked into a verdict; refusing to report anything." >&2
    exit 2
}
command -v python3 >/dev/null 2>&1 || { echo "gate.sh: python3 not on PATH." >&2; exit 2; }

exec python3 "$HERE/lib/gate.py" "$@"
