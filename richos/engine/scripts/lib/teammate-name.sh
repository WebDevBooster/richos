#!/usr/bin/env bash
#
# scripts/lib/teammate-name.sh — THE TEAMMATE NAME SHAPE, ASKED IN ONE PLACE,
#                                ANSWERED ONCE.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# Two independent readers each carried their OWN idea of "a well-formed
# <role>-<model>-<identifier> name":
#
#   guard-worktree-isolation.sh's NAME_SHAPE_RE — no length bound, any case,
#     any number of extra dash-joined segments.
#   mega-lander/create-teammate-worktree.sh's NAME_RE — lower-case only, role
#     2-16 chars, identifier 1-12 chars, EXACTLY three parts.
#
# `spawn.sh` exists to evaluate every refusal BEFORE anything is created (see
# scripts/lib/spawn.py's own header), and it does that by running EVERY
# PreToolUse[Agent] guard registered on either surface against the payload —
# and the engine's own shipped hooks.json (scripts/lib/spawn.py:
# settings_sources) is UNCONDITIONALLY one of those surfaces, so
# guard-worktree-isolation.sh always runs there, always before anything is
# created. The guard's looser rule passed `zach-sonnet-multirepodemo1` (a
# 14-character identifier), so spawn.sh's own guard table said "passed" and
# the refusal surfaced one round trip later, inside the create step, exactly
# the round trip spawn.sh was built to remove (found 2026-09-17, packaging the
# multi-repository fix landed beside it).
#
# So there is now exactly one shape rule, here, and it is the STRICTER of the
# two — the creator's. Both `guard-worktree-isolation.sh` and
# `mega-lander/create-teammate-worktree.sh` source this file directly and call
# `teammate_name_check`.
#
# scripts/lib/spawn.py NEEDS NO CODE OF ITS OWN FOR THIS RULE, and does not
# call this file: it already runs guard-worktree-isolation.sh, from the
# engine's own hooks.json, as the FIRST step of its own guard-evaluation phase
# — before repository resolution even finishes — so the guard's clause 2c
# (the caller below) already refuses the bad name there, in spawn.sh's own
# guard table, in this file's exact wording, before anything is registered.
# Verified 2026-09-17: `spawn.sh zach-sonnet-multirepodemo1 --repo ... --dry-run`
# prints "refused by 1 of 1 guard(s) - NOTHING WAS CREATED" naming this
# message, with zero changes to spawn.py. A second, redundant check inside
# spawn.py would be the exact defect this file exists to end — two readers
# answering one question — so it does not have one; scripts/spawn.test.sh
# carries the case that proves this end-to-end.
#
# ALLOWED_MODELS RESOLUTION IS DELIBERATELY NOT UNIFIED HERE. The two readers
# resolve it from different roots on purpose: the guard reads the GOVERNED
# REPOSITORY's own orchestration.config (a repository this engine governs may
# declare its own model roster), the creator always reads the ENGINE's own
# orchestration.config. Collapsing that into one resolution would be a real
# behavior change to one of the two, not a name-rule fix — a separate,
# unrelated cleanup. This file only holds the SHAPE the name must take once
# ALLOWED_MODELS is known; each caller keeps deciding what ALLOWED_MODELS is
# for itself.

# teammate_name_re <allowed-models> — prints the anchored ERE a name must
# match: lower-case only, role 2-16 chars, model the middle of EXACTLY three
# dash-joined parts (one of <allowed-models>), identifier 1-12 chars.
teammate_name_re() {
  local allowed="$1"
  printf '^[a-z][a-z0-9]{1,15}-(%s)-[a-z0-9]{1,12}$' "$(printf '%s' "$allowed" | tr ' ' '|')"
}

# teammate_name_check <name> <allowed-models> — exit 0 and nothing printed if
# NAME satisfies the shared rule; exit 1 and the refusal message on stdout
# otherwise. THE MESSAGE IS THE CREATOR'S EXACT WORDING
# (mega-lander/create-teammate-worktree.sh point 1) — every reader that
# refuses on this rule refuses in these words, so a name refused by one reader
# reads identically when another reader refuses it too.
teammate_name_check() {
  local name="$1" allowed="$2"
  if printf '%s' "$name" | grep -qE "$(teammate_name_re "$allowed")"; then
    return 0
  fi
  printf "'%s' is not a teammate name of the form <role>-<model>-<identifier> (model one of: %s)." \
    "$name" "$allowed"
  return 1
}

# teammate_name_engine_allowed_models <engine-root> — the CREATOR's own
# ALLOWED_MODELS resolution (default, then <engine-root>/orchestration.config
# override), extracted out of create-teammate-worktree.sh unchanged so that
# resolution has one source too.
teammate_name_engine_allowed_models() {
  local engine_root="$1" out="fable opus sonnet haiku"
  if [ -f "$engine_root/orchestration.config" ]; then
    local am
    am="$(sed -n 's/^ALLOWED_MODELS="\(.*\)"$/\1/p' "$engine_root/orchestration.config" | head -1)"
    [ -n "$am" ] && out="$am"
  fi
  printf '%s' "$out"
}
