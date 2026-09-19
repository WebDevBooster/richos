#!/usr/bin/env bash
#
# worktree-resource.sh — one derivation for every resource two checkouts could collide over.
#
# =========================================================================================
# WHY THIS IS A FUNCTION AND NOT A CONVENTION
# =========================================================================================
#
# This Mac runs many checkouts of this repository at once: the main checkout, one worktree
# per engineer, and `~/.richos-nightly/source` for the build. Anything this repository names
# with a FIXED string — a TCP port, a cache directory, a lock file — is therefore shared by
# all of them, and two runs that start a minute apart fight over it. The symptom is never
# "two runs collided". The symptom is one run going red for a reason that has nothing to do
# with what it was testing, on a tree where nothing is wrong.
#
# `run-tests.sh` documented exactly that about its own port (`run-tests.sh`, the
# INDEPENDENCE section): *"Two SIMULTANEOUS run-tests.sh runs on one host still would"*.
# Documented, and then left as a fixed 8975.
#
# ADOPTED AS-IS from T3 Code (MIT, `pingdotgg/t3code` pinned at `d6f29130`), read in full on
# 2026-09-19; the ADOPTION LEDGER's verdict for the developer loop is ADOPT AS-IS, and this
# is the file that adopts it. Their derivation, verbatim on the reason
# (`t3code:scripts/dev-runner.ts:255-259`):
#
#     "Worktrees get ports derived from their path so each one is stable across restarts
#      and distinct from its siblings. Without this every worktree starts at offset 0 and
#      scan-collides onto whatever happens to be free that minute, so ports move under you
#      between runs — which breaks any URL you already shared."
#
# and their state directory (`t3code:packages/shared/src/devHome.ts:5-8`): *"A linked git
# worktree gets its own (gitignored) `.t3`"*.
#
# THE MOST USEFUL THING IN THAT READ IS THAT T3 HAS THIS BUG TOO, in the one place they did
# not apply their own rule — a fixed Metro port 8199 shared across every checkout, with a
# readiness check that *"does not verify process ownership"*. A rule that lives in people's
# heads gets applied in most places, and the one place it is missed is the one that breaks.
# So the derivation lives HERE, in one function per resource, and a caller that wants a
# shared resource calls it rather than typing a constant.
#
# STABLE, NOT RANDOM. Two runs from the SAME worktree must land on the same port and the
# same state directory — a random port per run would trade a collision between worktrees
# for a cache that never hits. The input is the worktree's path and nothing else.
#
# An explicit override always wins: every caller reads its own environment variable first,
# because a human who names a port has a reason and this file is not it.

# The worktree that contains a path — its root, or the path itself when it is not in a
# repository at all (a fixture under mktemp, which is the common case in the self-tests and
# which must still get a private answer rather than an error).
worktree_root() {  # worktree_root <path>
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$1"
}

# Twelve hex characters of sha256 over the worktree's absolute path. Twelve because these
# names are read by people in logs and in `ls`; the collision probability over the dozens of
# checkouts one Mac ever holds is not the constraint.
worktree_id() {  # worktree_id <worktree-root>
  printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -c1-12
}

# A port inside [base, base + span). T3 carries an explicit blocked-port list because their
# base is 5733 and their range crosses ports the Fetch specification refuses (6665-6669,
# 6697). Ours does not: the only caller uses base 8975 with span 1000, so the whole range
# 8975-9974 sits above every blocked port below it and below 10080, the next one up. A
# caller that picks a different base is responsible for the same check, which is why the
# range is stated here rather than assumed.
worktree_port() {  # worktree_port <worktree-root> <base> <span>
  local sum
  sum="$(printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -c1-8)"
  printf '%s\n' $(( $2 + (0x$sum % $3) ))
}

# A per-worktree directory under a shared base. The base stays shared on purpose: one place
# to look, one place to delete, and `ls` shows which checkouts have state.
worktree_dir() {  # worktree_dir <worktree-root> <base-dir>
  printf '%s/%s\n' "$2" "$(worktree_id "$1")"
}
