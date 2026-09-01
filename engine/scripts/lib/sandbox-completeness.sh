#!/usr/bin/env bash
#
# scripts/lib/sandbox-completeness.sh — CAN THIS SANDBOX ASSEMBLE THE ENGINE?
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
# Two places in this engine build a throwaway copy of itself and then make
# claims about what they observe there:
#
#   scripts/hooks/contract-integrity.test.sh   ~100 sandboxes, one per case
#   scripts/demo.sh                            one sample repo, shown to buyers
#
# Both assemble that copy from a HAND-MAINTAINED LIST of files. On 2026-08-31
# five guards landed in one night and neither list grew with them. The engine in
# those sandboxes could no longer be assembled — and the way that surfaced is
# the whole reason this file exists:
#
#   scan-secrets.sh REFUSES TO START without scripts/lib/seat-jurisdiction.sh,
#   by exiting 2. Probe Layer K's canary asserts the scanner exits 2 on a
#   planted secret. SAME NUMBER, OPPOSITE MEANINGS. The layer was green over a
#   scanner that never ran, for as long as those lists had existed.
#
# guard-main-checkout-writes.sh had the identical shape against Layer D. A list
# that falls behind does not announce itself; it converts a dead defense into a
# passing test. Growing the two lists fixes the instance. This fixes the CLASS.
#
# ===========================================================================
# WHY THIS IS A CHECK AND NOT A DERIVED COPY LIST
# ===========================================================================
# The obvious alternative is to derive the copy list itself — scan every hook
# for "$SCRIPT_DIR/../lib/x.sh" and copy whatever turns up. It was rejected, for
# a reason this engine has already written down once about deriving hook sets:
# a scan that stops matching produces a SHORTER list, silently, and a shorter
# list makes every sandbox smaller and every case greener. The failure mode of a
# broken deriver is indistinguishable from success — which is exactly the defect
# being fixed, reintroduced one level up.
#
# So the lists stay hand-maintained and reviewable, and this asks the only
# question that cannot be satisfied by a scan that found nothing: DOES EVERY
# REGISTERED HOOK ACTUALLY START IN THIS SANDBOX? It is answered by running
# them, not by reading them, so it holds for a dependency expressed in any form
# a shell can express one — a sourced library, a sibling .py, a data file, a
# path built at runtime out of three variables.
#
# ===========================================================================
# WHAT THIS DOES NOT COVER — say it here, not in a postmortem
# ===========================================================================
# This asks whether a hook can START. It does not ask whether a hook DECIDES the
# same way it would in a real engine, and it cannot.
#
# A dependency that fails HARD announces itself, which is what makes it
# checkable. A dependency that fails SOFT does not: scripts/lib/inflight.sh
# without scripts/lib/teammate-identity.py starts perfectly, resolves no teams
# directory, names no teammate, and reports that only into a structure nothing
# reads in a sandbox. Every hook starts; the sandbox models a different engine.
#
# So the hand-maintained lists are not made redundant by this file, and must not
# be treated as if they were. They remain the place a human states WHY each file
# is carried — and both lists now do, entry by entry, precisely so the soft half
# stays visible to a reader when this check has nothing to say about it.
#
# A hook that cannot start says so: every rooted hook in this engine prints the
# "RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE" banner and names
# the file it went looking for. That banner is a shipped contract, carried by
# ~35 hooks, and probe Layer R already treats the bootstrap block that prints it
# as byte-identical across hooks. Reading it here is reading the engine's own
# announcement, not guessing at one.
#
# Safe to source repeatedly. Never changes the caller's cwd.

if [ -n "${_SANDBOX_COMPLETENESS_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_SANDBOX_COMPLETENESS_SH_SOURCED=1

# The refusal signatures. Both are structural, not incidental:
#   BROKEN INSTALL  — the shared bootstrap banner every rooted hook prints
#   missing at:     — the line inside it that names the absent file
# A hook that declines for a REASON OF ITS OWN (out of jurisdiction, nothing
# declared, no protected paths) prints neither, and is not reported here.
_SC_REFUSAL_RE='BROKEN INSTALL|missing at:|is required for|Refusing rather than'

# ---------------------------------------------------------------------------
# _sc_payloads <root> — the shapes a hook is fed, one per line.
# ---------------------------------------------------------------------------
# MORE THAN ONE, DELIBERATELY. Not every dependency is loaded in the bootstrap
# block at the top of a hook. guard-ceo-todos-commits.sh, for one, reads its
# payload and returns early unless it is looking at a `git commit`, and only
# THEN sources scripts/lib/ceo-todos.sh — so a single Read payload would leave
# that whole branch, and the file it needs, unasked. One payload per matcher the
# engine actually registers, so every hook is driven at least as far as the
# branch that does its work.
#
# These are inspection payloads, never execution: a guard handed a `git commit`
# string reads the string. Nothing here runs it.
_sc_payloads() {
    local root="$1"
    printf '{"tool_name":"Read","cwd":"%s","tool_input":{"file_path":"%s/README.md"}}\n' "$root" "$root"
    printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/docs/note.md","content":"A short line of ordinary prose."}}\n' "$root" "$root"
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m \\"a change\\""}}\n' "$root"
    printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"reed","name":"reed-sonnet-sc1","prompt":"read a file","isolation":"worktree"}}\n' "$root"
    printf '{"tool_name":"SendMessage","cwd":"%s","tool_input":{"to":"main","message":"status"}}\n' "$root"
    printf '{"cwd":"%s","hook_event_name":"SessionStart"}\n' "$root"
}

# ---------------------------------------------------------------------------
# richos_sandbox_start_failures <root> <hook-basename>...
# ---------------------------------------------------------------------------
# Runs every named hook INSIDE <root>, once per payload shape, and prints one
# line per hook that announced it could not start:
#
#   <hook>\t<the line that named the missing file>
#
# Prints nothing and returns 0 when every hook starts. Returns 1 when any hook
# refused, so callers can `if ! ...; then` on it.
#
# stdin is always supplied, so a hook whose first act is `cat` cannot hang the
# caller waiting on a terminal — a check that hangs is a check that gets
# commented out.
richos_sandbox_start_failures() {
    local root="${1:-}"; shift || true
    local h out payload line found=0
    [ -n "$root" ] && [ -d "$root" ] || return 0
    [ "$#" -gt 0 ] || return 0

    for h in "$@"; do
        [ -f "$root/scripts/hooks/$h" ] || continue
        line=""
        while IFS= read -r payload; do
            [ -n "$payload" ] || continue
            out="$(
                unset CLAUDE_PLUGIN_ROOT
                export CLAUDE_PROJECT_DIR="$root"
                export RICHOS_ENTITY_ROOT="$root"
                export TMPDIR="$root/.sandbox-completeness-tmp"
                mkdir -p "$TMPDIR" 2>/dev/null || true
                cd "$root" 2>/dev/null || cd /
                printf '%s' "$payload" | bash "$root/scripts/hooks/$h" 2>&1
            )" || true
            printf '%s' "$out" | grep -qE "$_SC_REFUSAL_RE" || continue
            # Report the line that NAMES THE FILE in preference to the banner
            # above it. "BROKEN INSTALL" tells a reader something is wrong;
            # "scripts/lib/inflight.sh is missing at: …" tells them what to add
            # to the list, which is the entire point of running this.
            line="$(printf '%s' "$out" | grep -E 'missing at:' | head -1 || true)"
            [ -n "$line" ] || line="$(printf '%s' "$out" | grep -E "$_SC_REFUSAL_RE" | head -1 || true)"
            break
        done <<PAYLOADS_EOF
$(_sc_payloads "$root")
PAYLOADS_EOF
        if [ -n "$line" ]; then
            found=1
            printf '%s\t%s\n' "$h" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
        fi
    done
    rm -rf "$root/.sandbox-completeness-tmp" 2>/dev/null || true
    [ "$found" = 0 ]
}
