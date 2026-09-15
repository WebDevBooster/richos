#!/usr/bin/env bash
#
# scripts/lib/hook-dependencies.sh — WHAT DOES A REGISTERED HOOK NEED IN ORDER
#                                     TO DO ITS JOB?
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# On 2026-09-14 guard-hook-registration-commits.sh landed. It was registered
# correctly, and every inventory in the engine copied it faithfully, because
# every one of those inventories is derived from hooks/hooks.json and the guard
# is in hooks/hooks.json. scripts/demo.sh then died with exit 2 — because the
# guard sources scripts/hook-registration-completeness.sh, one directory up,
# and the sample repo the demo builds had never heard of it.
#
#   A HOOK'S DEPENDENCY IS NOT A HOOK, SO AN INVENTORY OF HOOKS CANNOT
#   ENUMERATE IT.
#
# That is not incidental. scripts/hook-registration-completeness.sh derives its
# inventories by UNANIMITY OVER REGISTERED HOOKS — a file naming every
# registered hook is an inventory of registered hooks — so a file that is not a
# registered hook is invisible to it by construction. The guard that landed to
# end the class of omission WAS the omission, and could not have caught itself.
#
# ===========================================================================
# THE OBJECTION THIS FILE HAS TO ANSWER, BECAUSE IT WAS ALREADY MADE
# ===========================================================================
# scripts/lib/sandbox-completeness.sh considered deriving the copy list and
# REJECTED it, in writing, and the reason is sound:
#
#   "a scan that stops matching produces a SHORTER list, silently, and a
#    shorter list makes every sandbox smaller and every case greener. The
#    failure mode of a broken deriver is indistinguishable from success."
#
# That is exactly right about a deriver that REPLACES the hand-maintained
# lists. This file is not that, in two specific ways:
#
#   1. IT IS A UNION, NOT A REPLACEMENT. Callers keep their hand-maintained
#      list and add this to it. A deriver that goes blind costs nothing it was
#      not already costing: the sandbox is exactly as complete as it is today.
#      The hand list remains the place a human states WHY each file is carried,
#      entry by entry, which is the half no derivation can produce.
#
#   2. IT HAS AN ANCHOR, so going blind is LOUD. Before printing anything this
#      asks a question it already knows the answer to, measured a DIFFERENT
#      way: every hook that CALLS resolve_engine_root() must come out of the
#      derivation depending on scripts/lib/resolve-roots.sh, because that is
#      where the function is defined and it cannot be called without sourcing
#      the file. Keyed on a USE rather than a mention, deliberately — an anchor
#      that fired on a hook merely naming the library in prose would have a
#      false-positive class, and a check with one is a check that gets waived.
#      The two measurements share no machinery: one reads quoted path tokens,
#      the other greps for a function name, so the extraction rules cannot
#      break both in the same direction. Derivation short of the anchor is a
#      BROKEN DERIVER, and it returns rc 4 with NOTHING on stdout rather than a
#      shorter list. This is the shape hook-registration-completeness.sh
#      already uses for its typed structural readers: a typed list re-proved
#      against a derivation on every run is not the typed list that goes
#      stale.
#
# ===========================================================================
# WHY STATIC, WHEN sandbox-completeness.sh ALREADY RUNS THE HOOKS
# ===========================================================================
# Because running them only reaches what the payload reaches, and that is not a
# quibble — it is measured. contract-integrity.test.sh's SC1 starts every
# registered hook in a sandbox and passed while that sandbox did not contain
# scripts/hook-registration-completeness.sh — the file whose absence killed the
# demo — because the sandbox was not a git repository, so the guard exited 0 at
# its jurisdiction test and never reached the helper it would refuse without.
# The demo caught the same omission only because the demo performs a REAL
# `git commit` in a REAL repository.
#
# TWO CORRECTIONS, 2026-09-14, both to this paragraph as it was first written.
#
# The sandbox IS a repository now (contract-integrity.test.sh →
# init_sandbox_repo), so that specific dependency is reached and SC1 names it
# when it is removed — measured both ways before and after.
#
# And the parenthesis this paragraph used to carry — "`git init` appears nowhere
# in the suite" — was a GREP RESULT dressed as a fact about the harness. The
# suite had built real repositories since long before it was written; the call
# is spelled `git -C "$root" init -q -b main` in that file's make_git_main, and
# a search for the two words "git init" cannot see it. The conclusion happened
# to be right for the SANDBOX and the reason given for it was not checked.
#
#   "CAN IT START?" IS NOT "CAN IT RUN?". A dependency loaded past a
#   precondition the harness does not satisfy is never reached, and a harness
#   that cannot reach it reports green.
#
# A static derivation sees that dependency whether or not any payload reaches
# it. The two checks are complements, not competitors: running catches what is
# expressed in a form no scan can read; scanning catches what no payload can
# reach. Neither alone is the answer and this file does not claim to be.
#
# ===========================================================================
# WHAT COUNTS AS A REFERENCE — AND WHY NOT "THE PATH APPEARS IN THE FILE"
# ===========================================================================
# The naive predicate has a large false-positive class, measured rather than
# feared: this engine's hooks NAME OTHER SCRIPTS IN THEIR REFUSAL TEXT, on
# purpose, because a refusal that does not say what to run next is half a
# refusal. notice-ceo-unasked.sh prints "run scripts/ceo-asks-status.sh by
# hand"; verify-agent-prompt.sh names scripts/inflight-ack.sh inside the
# sentence explaining the ack contract. Neither is a dependency; both would be
# copied by a naive scan, and — worse — both would be DEMANDED by a check
# built on one.
#
# So the rule is syntactic and narrow:
#
#   A REFERENCE IS A QUOTED TOKEN WHOSE ENTIRE CONTENT IS A PATH.
#
# "$SCRIPT_DIR/../lib/resolve-roots.sh" is a reference. "…run
# scripts/ceo-asks-status.sh by hand." is a sentence that contains a path, and
# a sentence is never a reference. The rule needs no knowledge of which command
# consumes the token, which is what lets it see a dependency assigned to a
# variable here and sourced two hundred lines below — the shape every rooted
# hook in this engine actually uses.
#
# Leading shell expansions are stripped before resolution ($VAR, ${VAR}, and
# $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd), which is how the two handoff
# hooks reach scripts/lib/worktree-ledger.py). What remains resolves:
#
#   ../x, ./x            relative to the referring file's own directory
#   scripts/…, hooks/…   relative to the engine root
#   bare basename        the referring file's own directory, else a UNIQUE
#                        basename match in the engine — which is how a .sh half
#                        reaches its sibling .py half ("$LIB_DIR/ceo-todos.py")
#
# A token that resolves to no file on disk is dropped. A hook cannot depend on
# a file that is not there, and a check built on guesses about absent files
# would be inventing its own facts.
#
# ===========================================================================
# SCOPE, AND WHAT IS DELIBERATELY NOT IN IT
# ===========================================================================
# The closure covers CODE AND DATA UNDER scripts/. Configuration and record
# files are excluded even when a hook genuinely reads them — orchestration.config
# is the worked example: both consumers of this library write their own, with
# values chosen for what they are demonstrating, and copying the engine's over
# the top would break them. Configuration is the consumer's to synthesize; code
# is the engine's to provide.
#
# TEST AND MUTATION SCAFFOLDING (*.test.sh, *.test.py, *.mutation.sh) is
# excluded, both from the result and from the walk. Several hooks name their own
# suite in a comment or a self-check; following that edge would drag in the
# whole test tree, which no consumer of this library is assembling.
#
# NOT COVERED, said here rather than in a postmortem: a dependency whose path is
# assembled at runtime out of pieces no scan can join, in a hook that fails SOFT
# when it is missing, behind a precondition no payload satisfies. Nothing in
# this engine currently sees that file. sandbox-completeness.sh covers the hard
# half of it and says so; this covers the scannable half and says so; the
# intersection of both gaps is genuinely open, and it is smaller than either was
# alone.
#
# Safe to source repeatedly. Never changes the caller's cwd.
#
# Exit codes — a caller MUST distinguish these from an empty closure:
#   0  complete closure printed (possibly empty only if no hook is registered)
#   1  no such engine directory, or no hooks/hooks.json in it
#   2  python3 unavailable, or hooks/hooks.json unparseable
#   4  ANCHOR FAILED — the derivation cannot see a dependency a second,
#      independent measurement says is there. Nothing is printed: a short list
#      from a broken deriver is the failure this library exists to avoid.

if [ -n "${_HOOK_DEPENDENCIES_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_HOOK_DEPENDENCIES_SH_SOURCED=1

# richos_hook_dependency_closure <engine-dir>
#
# Prints one engine-relative path per line, sorted: every file under scripts/
# that a registered hook needs, transitively, and that is not itself a
# registered hook.
richos_hook_dependency_closure() {
    local eng="${1:-}"
    local predicate out rc

    [ -n "$eng" ] && [ -d "$eng" ] || return 1
    [ -f "$eng/hooks/hooks.json" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 2

    # The sibling half. Resolved from THIS FILE's location, never from the
    # engine under audit: this library is sourced by a suite that builds
    # throwaway copies of the engine, and asking a copy for the predicate would
    # mean auditing a tree with its own idea of what the rules are.
    predicate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-dependencies.py"
    [ -f "$predicate" ] || return 2

    out="$(python3 "$predicate" "$eng")"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$out"
}
