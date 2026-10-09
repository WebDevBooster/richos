#!/usr/bin/env bash
#
# second-review-land.test.sh: no work lands without a passing second review of
# exactly its tip, and a mid-job verdict reaches the running teammate once
# (CEO §113; slice 3 of richos-hq docs/plans/2026-10-09-automatic-second-
# review-and-t3-ideas.md, §2.5 and §4 row 3, with Sage's check §2 catches 1
# and 8).
#
# The cases live in mega-lander/tests/workspaces.test.py, beside the land
# command they drive, in two classes: SecondReview_NoWorkLandsUnreviewed
# (`workspaces.sh merge` in mega-lander/workspaces.py, and the Git fence in
# scripts/lib/operator_fences.py, installed by scripts/lib/operator_fences_admin.py
# from scripts/lib/operator-fence-launcher.sh: refused with no verdict, refused
# with a verdict on an older commit, refused on changes requested, allowed with
# a passing verdict on the tip, a plain merge, a fast-forward, a direct commit
# and a codex/ branch refused the same way, an unlisted repository untouched,
# a repository taken as unreviewed only on positive evidence from every
# governing declaration, so a missing, gone, dangling or unreadable one, or an
# unreadable registry, repository or launcher, refuses instead, status naming a
# launcher that disagrees) and
# SecondReview_AMidJobVerdictReachesTheRunningTeammate
# (scripts/hooks/deliver-review-verdict.sh and scripts/lib/review_delivery.py).
# This suite runs only those two classes, so a change to any of those files
# selects them. Their mutants are in mega-lander/tests/workspaces.mutation.sh
# (sr-*), run before each nightly.
#
# Every case runs in temporary repositories with HOME and CLAUDE_CONFIG_DIR
# redirected; the operator's real ledgers, registry and repositories are never
# read or written.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B -W ignore "$HERE/../mega-lander/tests/workspaces.test.py" \
    SecondReview_NoWorkLandsUnreviewed SecondReview_AMidJobVerdictReachesTheRunningTeammate
