#!/usr/bin/env bash
#
# contract-integrity-probe.sh — verify the hook enforcement machinery is
# actually wired AND functional on this machine.
#
# Rationale: the enforcement hooks are registered in EXACTLY ONE committed
# file, `.claude/settings.local.json`. A fresh clone that lost that file, an
# accidental delete, or an edit-out during troubleshooting all leave the gates
# silently disabled with no warning. This probe catches that.
#
# CANONICAL SOURCE (single-registration root-fix): hooks live ONLY in the
# committed `.claude/settings.local.json`. This probe reads the wiring from THAT
# file, and Layer M asserts the wiring is not ALSO duplicated into the generated
# `.claude/settings.json` — which Claude Code reads too and MERGES additively,
# firing every duplicated hook TWICE per matching tool event (the invisible
# defect this layer makes visible). See scripts/hooks/install.sh for the
# migration that removes any stale hook-duplicating settings.json.
#
# Run it standalone whenever you need to confirm enforcement is live:
#
#   scripts/hooks/contract-integrity-probe.sh
#
# Exit codes:
#   0  every layer passes
#   1  unexpected error
#   2  one or more layers failed; diagnostic on stderr
#
# Layers checked (in order):
#   A. .claude/settings.local.json (the canonical committed source) exists.
#   B. settings.local.json wires PreToolUse[Write|Edit|MultiEdit|NotebookEdit]
#      -> guard-main-checkout-writes.sh (path-confined, manifest-matched).
#   C. settings.local.json wires PreToolUse[Agent] -> the four-hook chain, IN
#      ORDER: guard-worktree-isolation.sh, guard-definition-drift.sh,
#      reader-teammate-hint.sh, verify-agent-prompt.sh (each path-confined,
#      manifest-matched).
#   D. The wired write-guard hook rejects a known-bad main-checkout source
#      write (functional canary, targeting the first PROTECTED_PATHS tree).
#   E. Every wired Agent hook chain script exists, is executable.
#   F. TeammateIdle log hook (warn-only).
#   G. TaskCompleted log hook (warn-only).
#   H. PostToolUse[Agent] detect-nonnative-worktree.sh detector (warn-only).
#   I. .claude/settings.local.json carries env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
#      == "1" (HARD gate — see the "ghost team" incident below).
#   J. .claude/settings.local.json carries worktree.baseRef == "head" (HARD gate).
#   L. PreToolUse[SendMessage] guard-resume-isolation.sh resume-guard (warn-only)
#      — wired + path-confined + manifest-matched + a functional canary.
#   K. settings.local.json wires PreToolUse[Write|Edit|MultiEdit|NotebookEdit] ->
#      scan-secrets.sh (path-confined, manifest-matched) AND the wired scanner
#      actually rejects a known-bad high-entropy secret (functional canary).
#   M. REGISTRATION UNIQUENESS: each canonical hook is registered EXACTLY ONCE
#      across settings.local.json + settings.json (no additive double-fire),
#      plus a live single-fire canary on the resume-guard append path.
#   N. GIT-TRACKED canonical source: .claude/settings.local.json is actually
#      tracked in this repo (git ls-files) — HARD-fails when the file is present
#      on disk but untracked AND matched by a gitignore rule (the silent
#      global-gitignore stranding trap below); warns when simply not-yet-
#      committed; skips cleanly outside a git work tree.
#   O. BASH-WRITE GUARD: settings.local.json wires PreToolUse[Bash] ->
#      guard-bash-main-writes.sh (path-confined, manifest-matched), and it denies
#      a raw main-checkout source write (functional canary against the first
#      PROTECTED_PATHS tree) — closing the cwd-default drift vector the Write/Edit
#      guard never sees. Warn-only (not fail) when PROTECTED_PATHS is empty.
#   P. DEFINITION-DRIFT GUARD PAIR: SessionStart wires
#      snapshot-agent-definitions.sh and PreToolUse[Agent] wires
#      guard-definition-drift.sh, EACH EXACTLY ONCE, both present + executable
#      with current .sha256 sidecars, and the guard both BLOCKS a definition
#      modified since the session-start snapshot and ALLOWS an unchanged one
#      (paired functional canaries — a negative test alone can pass for the
#      wrong reason).
#   Q. WORKTREE-REAPER CHAIN: SessionStart wires session-start-reap-worktrees.sh
#      EXACTLY ONCE, and both it and the scripts/reap-stale-worktrees.sh it runs
#      with --execute are present, executable and manifest-matched. A throwaway
#      sandbox sweep then proves the reaper still REMOVES a merged/clean/unlocked
#      agent worktree and still REFUSES one carrying uncommitted work (paired
#      canaries; real worktrees are never touched).
#
# Layer N exists because of a real onboarding trap: .claude/settings.local.json
# is committed BY DESIGN (it is the SOLE hook-registration source plus the two
# load-bearing config keys), but a common global-gitignore convention
# (~/.config/git/ignore carrying `**/.claude/settings.local.json`, the way
# vanilla Claude Code treats it as machine-local) makes `git add -A` SILENTLY
# skip it. The file still exists on disk, so Layers A/I/J and the whole probe
# pass locally — yet the NEXT clone/session never receives it and the
# orchestrator wakes with ZERO teammates and no error (the Layer I incident,
# arriving by a different door). `git ls-files` is the ground truth: tracked ==
# it reaches the next cloner. Fix is `git add -f .claude/settings.local.json`.
#
# Layers I/J exist because of a real incident: `env.CLAUDE_CODE_EXPERIMENTAL_
# AGENT_TEAMS` was once accidentally deleted from settings.local.json during an
# edit, and at the NEXT session start the orchestrator could not see or spawn
# ANY teammates — total silent failure, no error shown anywhere. `worktree.
# baseRef: "head"` is the twin load-bearing key the worktree-isolation doctrine
# (CLAUDE.md.template, skills/using-git-worktrees, skills/rich-lander) assumes
# is set — without it, native worktrees stop branching from local HEAD and the
# land sequence's merge-base assumptions break. Both are HARD failures (not
# warn-only like F/G/H) precisely because their absence is otherwise invisible
# until the next session/land, at which point the failure mode is silent.
#
# Layer K is a HARD gate (not warn-only) for the same reason as B/C: a missing
# or gutted secrets scanner is a genuine security regression, not a cosmetic
# drift — an adopter relying on "the engine blocks leaked credentials" deserves a
# probe that actually verifies it's still true. It is checked independently of
# Layer B: the Write|Edit matcher now wires TWO hooks (guard-main-checkout-
# writes.sh first, scan-secrets.sh second), and Layer K scans the FULL list of
# wired commands under that matcher (not just the first) so its position
# doesn't matter, unlike Layer B's single-capture logic which specifically
# targets the first entry.
#
# Idempotent. Safe to run from any cwd.

set -eo pipefail

# Fail-closed, not fail-open: this probe leans on python3 for JSON extraction
# (Layers B/C/F/G/H) AND for realpath resolution (realpath_of(), which is the
# anti-shim symlink-confinement check). Some of those calls are `|| true`-
# guarded and degrade to an empty/unresolved value rather than aborting —
# empty extraction happens to still fail the "not wired" checks downstream,
# but realpath_of()'s silent fallback to the raw (non-symlink-resolved) path
# would quietly WEAKEN the adversarial path-confinement guarantee this probe
# exists to provide. A probe that is supposed to verify enforcement integrity
# must not itself degrade silently, so refuse outright if python3 is absent.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: contract-integrity-probe.sh: python3 is required for settings.json parsing + path-confinement checks — refusing (fail-closed)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. Contract: scripts/lib/resolve-roots.sh.
#
# This probe reads two different kinds of asset and used to have one variable
# for both. Seated in the engine's own repository they coincide, which is why
# the conflation survived; loaded by reference they are different directories
# and the probe reported the ENTITY's canonical settings file as "missing"
# while looking in a repository that never had one.
#
#   ENGINE_ROOT   VERSION, scripts/hooks/*.sh, scripts/lib/*,
#                 scripts/reap-stale-worktrees.sh   — what the engine SHIPS
#   ENTITY_ROOT   .claude/settings*.json, orchestration.config, the
#                 PROTECTED_PATHS canary            — what the engine GOVERNS
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    echo "FATAL: missing helper $_RR_LIB — cannot resolve the engine and entity roots" >&2
    exit 1
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

if resolve_entity_root ""; then
    REPO_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
else
    # A probe whose whole job is to verify enforcement integrity must never
    # report on a repository it could not identify. Both remaining statuses are
    # fatal HERE — unlike a live guard, which stands down in an unadopted repo,
    # because being ASKED to verify a repository that has not adopted the engine
    # is itself the finding.
    root_failure_banner "scripts/hooks/contract-integrity-probe.sh" >&2
    echo "  A probe cannot verify enforcement in a repository it cannot name." >&2
    echo "  Declare the subject explicitly:  RICHOS_ENTITY_ROOT=<repo> $0" >&2
    exit 2
fi

# --- WHICH MODE IS THIS? ---------------------------------------------------
# Two ways the engine can be installed, and the difference decides whether most
# of the layers below mean anything at all:
#
#   SEATED         ENGINE_ROOT == REPO_ROOT. The engine IS the repository. The
#                  guards are registered in the entity's own
#                  .claude/settings.local.json, so Layers A-Q audit that file
#                  and every "canonical path" is entity-relative — because that
#                  is what the wiring `$CLAUDE_PROJECT_DIR/scripts/hooks/x.sh`
#                  resolves to.
#
#   BY REFERENCE   ENGINE_ROOT != REPO_ROOT. The engine is a plugin; its guards
#                  are registered in the PLUGIN's hooks/hooks.json, and the
#                  entity's settings file legitimately does not mention them.
#                  Running the settings-wiring layers here would emit a wall of
#                  "NOT wired" failures that are all false — the exact false
#                  alarm this probe exists to prevent, pointed at itself.
#
# The by-reference wiring needs its own layer set, and that is not yet written.
# Rather than pretend, the probe SAYS SO and refuses to issue a verdict it
# cannot support. A tool that reports on a configuration it does not understand
# is worse than one that admits the gap.
# The test is "same REPOSITORY?", not "same path". A path comparison alone
# calls the engine "by reference" when the probe is merely invoked from a
# LINKED WORKTREE of the engine's own repo — ENGINE_ROOT is then the worktree
# while REPO_ROOT normalises to the shared main checkout. Same repository, both
# of them; still seated. So normalise the engine root to ITS main checkout
# before comparing.
PROBE_MODE="seated"
_ENGINE_MAIN="$(resolve_main_checkout "$ENGINE_ROOT" "$ENGINE_ROOT" 2>/dev/null || printf '%s' "$ENGINE_ROOT")"
if [ "$ENGINE_ROOT" != "$REPO_ROOT" ] && [ "$_ENGINE_MAIN" != "$REPO_ROOT" ]; then
    PROBE_MODE="by-reference"
fi

# Load project config (protected trees drive the Layer-D functional canary).
CONFIG="$REPO_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${PROTECTED_PATHS:=}"

C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'

FAIL=0
# Canonical hook-registration source (committed). Every Layer B-L extraction
# reads this file; Layer M additionally inspects SETTINGS_JSON for duplicates.
SETTINGS="$REPO_ROOT/.claude/settings.local.json"
SETTINGS_LOCAL="$REPO_ROOT/.claude/settings.local.json"
# The gitignored, generated settings file. Post-root-fix it must carry NO hook
# stanzas (install.sh removes/strips them). It may be entirely absent — that is
# the clean single-source state.
SETTINGS_JSON="$REPO_ROOT/.claude/settings.json"

# In by-reference mode, stop before Layer A rather than emit a wall of false
# "NOT wired" failures. Layer R (the root-resolution contract) is the one check
# that IS mode-independent, so it still runs.
if [ "$PROBE_MODE" = "by-reference" ]; then
    {
        echo ""
        echo "=== ENGINE LOADED BY REFERENCE — settings-wiring layers DO NOT APPLY ==="
        echo "  engine : $ENGINE_ROOT"
        echo "  entity : $REPO_ROOT"
        echo ""
        echo "  The engine's guards are registered in the PLUGIN's hooks/hooks.json,"
        echo "  not in this repository's .claude/settings.local.json. Layers A-Q audit"
        echo "  the settings file, so running them here would report every engine guard"
        echo "  as 'NOT wired' — all of it false."
        echo ""
        echo "  A by-reference layer set is NOT YET WRITTEN. This probe will not issue a"
        echo "  verdict it cannot support, so it is reporting the gap instead of a green"
        echo "  tick. What you CAN check today:"
        echo "    * the first SessionStart message from engine-status.sh — it states"
        echo "      whether enforcement is ACTIVE, STOOD DOWN or BROKEN for this repo"
        echo "    * scripts/hooks/root-contract.test.sh, run from the engine"
        echo "    * scripts/lib/resolve-roots.test.sh, run from the engine"
        echo "  To audit the ENGINE's own seated wiring, run this probe from the engine:"
        echo "    RICHOS_ENTITY_ROOT=$ENGINE_ROOT $ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh"
        echo "======================================================================="
    } >&2
    exit 2
fi

emit_pass() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1" >&2; }
emit_fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; FAIL=$((FAIL+1)); }
emit_warn() { printf '  %s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }

# --- Engine version banner (informational — NEVER gates) ---
#
# The engine's semantic version lives in the top-level `VERSION` file
# (engine-owned; see VERSIONING.md). Print it so every integrity check is
# self-identifying: an adopter reading a probe run — or a support/onboarding
# operator — can see at a glance which engine version they are verifying. This
# is a pure banner: a missing/unreadable VERSION never increments FAIL and never
# blocks a layer (an adopter who deleted VERSION has a cosmetic gap, not a
# broken guard).
ENGINE_VERSION="$(awk 'NR==1 {gsub(/[[:space:]]/,""); print; exit}' "$ENGINE_ROOT/VERSION" 2>/dev/null || true)"
if [ -n "$ENGINE_VERSION" ]; then
    printf 'richos-engine v%s — contract integrity probe\n' "$ENGINE_VERSION" >&2
else
    printf 'richos-engine (VERSION file absent) — contract integrity probe\n' >&2
fi

# --- Layer A — canonical settings.local.json exists ---
if [ ! -f "$SETTINGS" ]; then
    emit_fail "A. .claude/settings.local.json missing (canonical hook source)"
    cat >&2 <<EOF

The enforcement hooks are wired through .claude/settings.local.json — the
COMMITTED source-of-truth (force-added; see .gitignore). It should always be
present in a valid checkout. If it is missing, your working tree is corrupt:
restore it with

    git checkout -- .claude/settings.local.json

Then re-run this probe.
EOF
    exit 2
fi
emit_pass "A. .claude/settings.local.json present (canonical hook source)"

# --- Layer B+C — extract wired hook commands via Python (json.parse) ---
EXTRACT_PY="$(mktemp -t contract-integrity-extract.XXXXXX.py)"
trap 'rm -f "$EXTRACT_PY"' EXIT
cat >"$EXTRACT_PY" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
hooks = data.get("hooks", {})
pre = hooks.get("PreToolUse", [])
for entry in pre:
    matcher = entry.get("matcher", "")
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        # Print TAB-separated rows: matcher\tcommand
        print(f"{matcher}\t{cmd}")
PY

WIRED="$(python3 "$EXTRACT_PY" "$SETTINGS" 2>/dev/null || true)"
GUARD_CMD="$(printf '%s\n' "$WIRED" | awk -F'\t' '$1 ~ /Write/ && $1 ~ /Edit/ {print $2; exit}')"

# ALL commands under the Write|Edit matcher (Layer B only cares about the
# FIRST entry above; Layer K below needs the full list since scan-secrets.sh
# is wired as a second hook in the same matcher entry).
WRITE_CMDS=()
while IFS= read -r line; do
    [ -n "$line" ] && WRITE_CMDS+=("$line")
done < <(printf '%s\n' "$WIRED" | awk -F'\t' '$1 ~ /Write/ && $1 ~ /Edit/ {print $2}')

# The PreToolUse[Agent] matcher wires a CHAIN of hooks, in order:
#   1. guard-worktree-isolation.sh  (spawn-contract PREVENTER: isolation + name)
#   2. guard-definition-drift.sh    (booted-definition freshness PREVENTER)
#   3. reader-teammate-hint.sh      (routes reading/ingest work to the reader)
#   4. verify-agent-prompt.sh       (spawn-content gate)
AGENT_CMDS=()
while IFS= read -r line; do
    [ -n "$line" ] && AGENT_CMDS+=("$line")
done < <(printf '%s\n' "$WIRED" | awk -F'\t' '$1=="Agent" {print $2}')

# The PreToolUse[Bash] matcher wires the Bash-write guard (guard-bash-main-
# writes.sh), which auto-DENIES a raw Bash command that writes into a protected
# tree in the main checkout — the cwd-default drift vector the Write/Edit guard
# never sees. Capture every Bash-matcher command for the wiring layer below.
BASH_CMDS=()
while IFS= read -r line; do
    [ -n "$line" ] && BASH_CMDS+=("$line")
done < <(printf '%s\n' "$WIRED" | awk -F'\t' '$1=="Bash" {print $2}')

# Layer B must NOT rely on filename-substring matching. An adversarial shim
# with the right filename at any path on disk, hand-wired into settings.json,
# would pass a filename check while gutting the guard. So Layer B REQUIRES that
# the resolved wired path equals the canonical repo-root path AND that the
# file's content hash matches the committed manifest sidecar. Layer C applies
# the same requirement to EACH entry in the Agent chain.

CANONICAL_GUARD_HOOK="$REPO_ROOT/scripts/hooks/guard-main-checkout-writes.sh"
CANONICAL_SECRETS_HOOK="$REPO_ROOT/scripts/hooks/scan-secrets.sh"
CANONICAL_BASHGUARD_HOOK="$REPO_ROOT/scripts/hooks/guard-bash-main-writes.sh"
CANONICAL_DRIFTGUARD_HOOK="$REPO_ROOT/scripts/hooks/guard-definition-drift.sh"
CANONICAL_DEFSNAPSHOT_HOOK="$REPO_ROOT/scripts/hooks/snapshot-agent-definitions.sh"
CANONICAL_REAPHOOK="$REPO_ROOT/scripts/hooks/session-start-reap-worktrees.sh"
# NOT under scripts/hooks/ — this is the half of the reaper chain that actually
# removes worktrees and deletes branches (Layer Q hashes both).
CANONICAL_REAPER="$REPO_ROOT/scripts/reap-stale-worktrees.sh"
CANONICAL_AGENT_CHAIN=(
    "$REPO_ROOT/scripts/hooks/guard-worktree-isolation.sh"
    "$REPO_ROOT/scripts/hooks/guard-definition-drift.sh"
    "$REPO_ROOT/scripts/hooks/reader-teammate-hint.sh"
    "$REPO_ROOT/scripts/hooks/verify-agent-prompt.sh"
)

# Resolve settings.json $CLAUDE_PROJECT_DIR placeholder → absolute path.
RESOLVED_GUARD_CMD="${GUARD_CMD//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
RESOLVED_GUARD_CMD="${RESOLVED_GUARD_CMD//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"

realpath_of() {
    local p="$1"
    if [ -z "$p" ]; then
        echo ""
        return
    fi
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null || echo "$p"
}

sha256_of() {
    local p="$1"
    if [ ! -f "$p" ]; then
        echo ""
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$p" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$p" | awk '{print $1}'
    else
        python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$p" 2>/dev/null
    fi
}

# Read the expected hash from the committed manifest sidecar
# ("<hook>.sh.sha256") rather than from the live file itself. The sidecars are
# written by scripts/hooks/install.sh from canonical source. A manifest file
# missing or unreadable is itself a hard failure (the probe refuses to pass
# without a trusted hash source).
manifest_hash_of() {
    local f="$1"
    local mf="$f.sha256"
    if [ ! -f "$mf" ]; then
        echo ""
        return
    fi
    awk 'NR==1 {print $1; exit}' "$mf" 2>/dev/null
}

# read_settings_local_value <dotted.path> — reads a nested string value out of
# .claude/settings.local.json (e.g. "env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
# or "worktree.baseRef"). Prints the value if present and a string, else
# prints nothing. Never fails the caller — any parse error is swallowed and
# treated as "absent" (the caller's own check then fails the layer).
read_settings_local_value() {
    local dotted_path="$1"
    [ -f "$SETTINGS_LOCAL" ] || { echo ""; return; }
    python3 -c "
import json, sys
path, = sys.argv[1:2]
try:
    with open(sys.argv[2], 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
cur = data
for k in path.split('.'):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(0)
if isinstance(cur, str):
    print(cur)
" "$dotted_path" "$SETTINGS_LOCAL" 2>/dev/null || echo ""
}

# --- Layer B: write-guard hook path-confined + manifest-hash-matched ---
if [ -z "$GUARD_CMD" ]; then
    emit_fail "B. PreToolUse[Write|Edit|MultiEdit|NotebookEdit] write-guard NOT wired in settings.json"
else
    WIRED_PATH="${RESOLVED_GUARD_CMD%% *}"
    WIRED_REAL="$(realpath_of "$WIRED_PATH")"
    CANON_REAL="$(realpath_of "$CANONICAL_GUARD_HOOK")"
    if [ -z "$WIRED_REAL" ] || [ -z "$CANON_REAL" ]; then
        emit_fail "B. write-guard wired path could not be resolved (got: $GUARD_CMD)"
    elif [ "$WIRED_REAL" != "$CANON_REAL" ]; then
        emit_fail "B. write-guard wired path not confined to canonical location (wired: $WIRED_REAL, canonical: $CANON_REAL)"
    else
        WIRED_HASH="$(sha256_of "$WIRED_REAL")"
        MANIFEST_HASH="$(manifest_hash_of "$CANONICAL_GUARD_HOOK")"
        if [ -z "$WIRED_HASH" ]; then
            emit_fail "B. write-guard content hash could not be computed"
        elif [ -z "$MANIFEST_HASH" ]; then
            emit_fail "B. write-guard manifest missing or unreadable: $CANONICAL_GUARD_HOOK.sha256 — run scripts/hooks/install.sh to regenerate, then commit."
        elif [ "$WIRED_HASH" != "$MANIFEST_HASH" ]; then
            emit_fail "B. write-guard content hash mismatch — live hook differs from manifest (tamper or stale manifest). Expected $MANIFEST_HASH, got $WIRED_HASH. Run scripts/hooks/install.sh and review the diff."
        else
            emit_pass "B. write-guard -> $WIRED_PATH (path-confined, manifest-matched)"
        fi
    fi
fi

# --- Layer C: Agent hook CHAIN path-confined + manifest-hash-matched, IN ORDER ---
#
# Order is load-bearing. guard-worktree-isolation.sh runs FIRST as the hard
# spawn-contract preventer (isolation + truthful name) — a spawn that fails it
# should never reach anything downstream. guard-definition-drift.sh runs SECOND:
# it is the other structural spawn-correctness gate (is this agent's BOOTED
# definition actually the one on disk?), so it rejects before the softer
# routing/content checks. reader-teammate-hint.sh then runs before
# verify-agent-prompt.sh so a misrouted reading task gets the reader nudge
# before the stricter spawn-content gate.
if [ "${#AGENT_CMDS[@]}" -eq 0 ]; then
    emit_fail "C. PreToolUse[Agent] hook chain NOT wired in settings.json"
elif [ "${#AGENT_CMDS[@]}" -ne "${#CANONICAL_AGENT_CHAIN[@]}" ]; then
    emit_fail "C. PreToolUse[Agent] hook chain has ${#AGENT_CMDS[@]} entries wired, expected ${#CANONICAL_AGENT_CHAIN[@]} (guard-worktree-isolation.sh, then guard-definition-drift.sh, then reader-teammate-hint.sh, then verify-agent-prompt.sh) — run scripts/hooks/install.sh"
else
    CHAIN_OK=1
    for i in "${!CANONICAL_AGENT_CHAIN[@]}"; do
        CANON_HOOK="${CANONICAL_AGENT_CHAIN[$i]}"
        HOOK_BASENAME="$(basename "$CANON_HOOK")"
        WIRED_RAW_CMD="${AGENT_CMDS[$i]}"
        RESOLVED_CMD_I="${WIRED_RAW_CMD//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
        RESOLVED_CMD_I="${RESOLVED_CMD_I//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
        WIRED_PATH_I="${RESOLVED_CMD_I%% *}"
        WIRED_REAL_I="$(realpath_of "$WIRED_PATH_I")"
        CANON_REAL_I="$(realpath_of "$CANON_HOOK")"
        if [ -z "$WIRED_REAL_I" ] || [ -z "$CANON_REAL_I" ]; then
            emit_fail "C. PreToolUse[Agent] position $((i+1)) (expected $HOOK_BASENAME) wired path could not be resolved (got: $WIRED_RAW_CMD)"
            CHAIN_OK=0
        elif [ "$WIRED_REAL_I" != "$CANON_REAL_I" ]; then
            emit_fail "C. PreToolUse[Agent] position $((i+1)) not confined to canonical $HOOK_BASENAME (wired: $WIRED_REAL_I, canonical: $CANON_REAL_I)"
            CHAIN_OK=0
        else
            WIRED_HASH_I="$(sha256_of "$WIRED_REAL_I")"
            MANIFEST_HASH_I="$(manifest_hash_of "$CANON_HOOK")"
            if [ -z "$WIRED_HASH_I" ]; then
                emit_fail "C. PreToolUse[Agent] $HOOK_BASENAME content hash could not be computed"
                CHAIN_OK=0
            elif [ -z "$MANIFEST_HASH_I" ]; then
                emit_fail "C. PreToolUse[Agent] $HOOK_BASENAME manifest missing or unreadable: $CANON_HOOK.sha256 — run scripts/hooks/install.sh to regenerate, then commit."
                CHAIN_OK=0
            elif [ "$WIRED_HASH_I" != "$MANIFEST_HASH_I" ]; then
                emit_fail "C. PreToolUse[Agent] $HOOK_BASENAME content hash mismatch — live hook differs from manifest."
                CHAIN_OK=0
            fi
        fi
    done
    if [ "$CHAIN_OK" -eq 1 ]; then
        emit_pass "C. PreToolUse[Agent] chain -> guard-worktree-isolation.sh, guard-definition-drift.sh, reader-teammate-hint.sh, verify-agent-prompt.sh (path-confined, manifest-matched, in order)"
    fi
fi

# --- Layer D — wired write-guard actually rejects a known-bad input ---
#
# Canary: a Write targeting the first configured protected tree in the main
# checkout. The guard must return exit 2 whenever it is functional.
if [ -n "$GUARD_CMD" ]; then
    GUARD_HOOK_EXE="${RESOLVED_GUARD_CMD%% *}"
    FIRST_PROTECTED=""
    for p in $PROTECTED_PATHS; do FIRST_PROTECTED="$p"; break; done
    if [ -z "$FIRST_PROTECTED" ]; then
        emit_fail "D. cannot run write-guard canary — PROTECTED_PATHS is empty in orchestration.config. Fill it so the guard has trees to protect."
    elif [ ! -x "$GUARD_HOOK_EXE" ]; then
        emit_fail "D. wired write-guard script not found / not executable: $GUARD_HOOK_EXE"
    else
        CANARY_PATH="$REPO_ROOT/$FIRST_PROTECTED/__integrity_canary__.tmp"
        set +e
        printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$CANARY_PATH" \
            | "$GUARD_HOOK_EXE" >/dev/null 2>&1
        rc=$?
        set -e
        if [ "$rc" -ne 2 ]; then
            emit_fail "D. wired write-guard did NOT block a main-checkout source write (exit=$rc, expected 2)"
        else
            emit_pass "D. wired write-guard rejects main-checkout source writes (exit=2 canary)"
        fi
    fi
fi

# --- Layer E — wired Agent hook chain scripts exist + are executable ---
if [ "${#AGENT_CMDS[@]}" -gt 0 ]; then
    E_OK=1
    for raw_cmd in "${AGENT_CMDS[@]}"; do
        RESOLVED_E="${raw_cmd//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
        RESOLVED_E="${RESOLVED_E//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
        AGENT_HOOK_EXE="${RESOLVED_E%% *}"
        if [ ! -x "$AGENT_HOOK_EXE" ]; then
            emit_fail "E. wired Agent hook script not found / not executable: $AGENT_HOOK_EXE"
            E_OK=0
        fi
    done
    if [ "$E_OK" -eq 1 ]; then
        emit_pass "E. wired Agent hook chain scripts present + executable (${#AGENT_CMDS[@]} entries)"
    fi
fi

# --- Layer F — TeammateIdle handoff hook (WARN-ONLY) ---
#
# The TeammateIdle hook writes the durable idle-events.jsonl signal (log-only).
# It is intentionally NOT a hard gate: a broken idle-log hook must never block
# other work. So this layer SURFACES drift as a warning but never increments
# FAIL.
TIDLE_CMD="$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for entry in data.get("hooks", {}).get("TeammateIdle", []):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if cmd:
            print(cmd)
            sys.exit(0)
PY
)"
CANONICAL_TIDLE_HOOK="$REPO_ROOT/scripts/hooks/teammate-idle-handoff.sh"
if [ -z "$TIDLE_CMD" ]; then
    emit_warn "F. TeammateIdle hook NOT wired in settings.json (run scripts/hooks/install.sh; handoff logging disabled)"
else
    RESOLVED_TIDLE_CMD="${TIDLE_CMD//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_TIDLE_CMD="${RESOLVED_TIDLE_CMD//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    TIDLE_PATH="${RESOLVED_TIDLE_CMD%% *}"
    TIDLE_REAL="$(realpath_of "$TIDLE_PATH")"
    CANON_TIDLE_REAL="$(realpath_of "$CANONICAL_TIDLE_HOOK")"
    if [ ! -x "$TIDLE_PATH" ]; then
        emit_warn "F. TeammateIdle hook not found / not executable: $TIDLE_PATH"
    elif [ "$TIDLE_REAL" != "$CANON_TIDLE_REAL" ]; then
        emit_warn "F. TeammateIdle hook not confined to canonical location (wired: $TIDLE_REAL)"
    else
        TIDLE_HASH="$(sha256_of "$TIDLE_REAL")"
        TIDLE_MANIFEST="$(manifest_hash_of "$CANONICAL_TIDLE_HOOK")"
        if [ -n "$TIDLE_MANIFEST" ] && [ "$TIDLE_HASH" != "$TIDLE_MANIFEST" ]; then
            emit_warn "F. TeammateIdle hook content hash differs from manifest (run scripts/hooks/install.sh and review the diff)"
        else
            emit_pass "F. TeammateIdle hook wired + present (idle-event logging active)"
        fi
    fi
fi

# --- Layer G — TaskCompleted handoff-log hook (WARN-ONLY) ---
TCOMP_CMD="$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for entry in data.get("hooks", {}).get("TaskCompleted", []):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if cmd:
            print(cmd)
            sys.exit(0)
PY
)"
CANONICAL_TCOMP_HOOK="$REPO_ROOT/scripts/hooks/task-completed-handoff.sh"
if [ -z "$TCOMP_CMD" ]; then
    emit_warn "G. TaskCompleted hook NOT wired in settings.json (run scripts/hooks/install.sh; completion logging disabled)"
else
    RESOLVED_TCOMP_CMD="${TCOMP_CMD//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_TCOMP_CMD="${RESOLVED_TCOMP_CMD//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    TCOMP_PATH="${RESOLVED_TCOMP_CMD%% *}"
    TCOMP_REAL="$(realpath_of "$TCOMP_PATH")"
    CANON_TCOMP_REAL="$(realpath_of "$CANONICAL_TCOMP_HOOK")"
    if [ ! -x "$TCOMP_PATH" ]; then
        emit_warn "G. TaskCompleted hook not found / not executable: $TCOMP_PATH"
    elif [ "$TCOMP_REAL" != "$CANON_TCOMP_REAL" ]; then
        emit_warn "G. TaskCompleted hook not confined to canonical location (wired: $TCOMP_REAL)"
    else
        TCOMP_HASH="$(sha256_of "$TCOMP_REAL")"
        TCOMP_MANIFEST="$(manifest_hash_of "$CANONICAL_TCOMP_HOOK")"
        if [ -n "$TCOMP_MANIFEST" ] && [ "$TCOMP_HASH" != "$TCOMP_MANIFEST" ]; then
            emit_warn "G. TaskCompleted hook content hash differs from manifest (run scripts/hooks/install.sh and review the diff)"
        else
            emit_pass "G. TaskCompleted hook wired + present (completion logging active)"
        fi
    fi
fi

# --- Layer H — PostToolUse[Agent] detect-nonnative-worktree.sh (WARN-ONLY) ---
TNONNATIVE_CMD="$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for entry in data.get("hooks", {}).get("PostToolUse", []):
    if entry.get("matcher") != "Agent":
        continue
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if cmd:
            print(cmd)
            sys.exit(0)
PY
)"
CANONICAL_TNONNATIVE_HOOK="$REPO_ROOT/scripts/hooks/detect-nonnative-worktree.sh"
if [ -z "$TNONNATIVE_CMD" ]; then
    emit_warn "H. PostToolUse[Agent] detect-nonnative-worktree.sh NOT wired in settings.json (run scripts/hooks/install.sh; detector backstop disabled)"
else
    RESOLVED_TNONNATIVE_CMD="${TNONNATIVE_CMD//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_TNONNATIVE_CMD="${RESOLVED_TNONNATIVE_CMD//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    TNONNATIVE_PATH="${RESOLVED_TNONNATIVE_CMD%% *}"
    TNONNATIVE_REAL="$(realpath_of "$TNONNATIVE_PATH")"
    CANON_TNONNATIVE_REAL="$(realpath_of "$CANONICAL_TNONNATIVE_HOOK")"
    if [ ! -x "$TNONNATIVE_PATH" ]; then
        emit_warn "H. detect-nonnative-worktree.sh not found / not executable: $TNONNATIVE_PATH"
    elif [ "$TNONNATIVE_REAL" != "$CANON_TNONNATIVE_REAL" ]; then
        emit_warn "H. detect-nonnative-worktree.sh not confined to canonical location (wired: $TNONNATIVE_REAL)"
    else
        TNONNATIVE_HASH="$(sha256_of "$TNONNATIVE_REAL")"
        TNONNATIVE_MANIFEST="$(manifest_hash_of "$CANONICAL_TNONNATIVE_HOOK")"
        if [ -n "$TNONNATIVE_MANIFEST" ] && [ "$TNONNATIVE_HASH" != "$TNONNATIVE_MANIFEST" ]; then
            emit_warn "H. detect-nonnative-worktree.sh content hash differs from manifest (run scripts/hooks/install.sh and review the diff)"
        else
            emit_pass "H. PostToolUse[Agent] detect-nonnative-worktree.sh wired + present (worktree-guard detector active)"
        fi
    fi
fi

# --- Layer I — critical config: env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (HARD) ---
#
# HARD gate, not warn-only: see the header comment for the incident this
# guards against — its absence is otherwise SILENT until the next session.
if [ ! -f "$SETTINGS_LOCAL" ]; then
    emit_fail "I. .claude/settings.local.json missing — cannot verify env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS. Without this key the orchestrator sees/spawns ZERO teammates at the next session start, with NO error shown."
else
    TEAMS_FLAG="$(read_settings_local_value 'env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')"
    if [ "$TEAMS_FLAG" != "1" ]; then
        emit_fail "I. env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS missing or not \"1\" in .claude/settings.local.json (got: '${TEAMS_FLAG:-<unset>}'). SYMPTOM: the orchestrator will see/spawn ZERO teammates at the NEXT session start, with NO error shown — this has happened before. Restore: \"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" } in .claude/settings.local.json, then re-run scripts/hooks/install.sh."
    else
        emit_pass "I. env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=\"1\" present in .claude/settings.local.json"
    fi
fi

# --- Layer J — critical config: worktree.baseRef (HARD) ---
#
# HARD gate: without this, native isolation worktrees stop branching from
# local HEAD and the land sequence's merge-base assumptions silently break.
if [ ! -f "$SETTINGS_LOCAL" ]; then
    emit_fail "J. .claude/settings.local.json missing — cannot verify worktree.baseRef."
else
    BASE_REF="$(read_settings_local_value 'worktree.baseRef')"
    if [ "$BASE_REF" != "head" ]; then
        emit_fail "J. worktree.baseRef missing or not \"head\" in .claude/settings.local.json (got: '${BASE_REF:-<unset>}'). Without this, native isolation worktrees stop branching from local HEAD and the land sequence's merge-base assumptions break. Restore: \"worktree\": { \"baseRef\": \"head\" } in .claude/settings.local.json, then re-run scripts/hooks/install.sh."
    else
        emit_pass "J. worktree.baseRef=\"head\" present in .claude/settings.local.json"
    fi
fi

# --- Layer K: secrets scanner wired + path-confined + manifest-matched +
# functionally rejects a known-bad secret (HARD gate) ---
SECRETS_WIRED_CMD=""
for c in "${WRITE_CMDS[@]}"; do
    RESOLVED_C="${c//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_C="${RESOLVED_C//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    WIRED_PATH_C="${RESOLVED_C%% *}"
    if [ "$(realpath_of "$WIRED_PATH_C")" = "$(realpath_of "$CANONICAL_SECRETS_HOOK")" ]; then
        SECRETS_WIRED_CMD="$RESOLVED_C"
        break
    fi
done

if [ -z "$SECRETS_WIRED_CMD" ]; then
    emit_fail "K. PreToolUse[Write|Edit|MultiEdit|NotebookEdit] secrets scanner (scan-secrets.sh) NOT wired in settings.json — run scripts/hooks/install.sh"
else
    SECRETS_HOOK_EXE="${SECRETS_WIRED_CMD%% *}"
    SECRETS_REAL="$(realpath_of "$SECRETS_HOOK_EXE")"
    SECRETS_HASH="$(sha256_of "$SECRETS_REAL")"
    SECRETS_MANIFEST="$(manifest_hash_of "$CANONICAL_SECRETS_HOOK")"
    if [ ! -x "$SECRETS_HOOK_EXE" ]; then
        emit_fail "K. wired secrets-scanner script not found / not executable: $SECRETS_HOOK_EXE"
    elif [ -z "$SECRETS_HASH" ]; then
        emit_fail "K. secrets-scanner content hash could not be computed"
    elif [ -z "$SECRETS_MANIFEST" ]; then
        emit_fail "K. secrets-scanner manifest missing or unreadable: $CANONICAL_SECRETS_HOOK.sha256 — run scripts/hooks/install.sh to regenerate, then commit."
    elif [ "$SECRETS_HASH" != "$SECRETS_MANIFEST" ]; then
        emit_fail "K. secrets-scanner content hash mismatch — live hook differs from manifest (tamper or stale manifest). Run scripts/hooks/install.sh and review the diff."
    else
        # Functional canary: a Write whose content is an obvious, high-entropy
        # AWS-shaped secret. The wired scanner must return exit 2.
        CANARY_SECRET_PATH="$REPO_ROOT/__secret_scan_canary__.tmp"
        CANARY_PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"AWS_KEY=AKIAABCDEFGHIJKLMNOP"}}))' "$CANARY_SECRET_PATH" 2>/dev/null || true)"
        set +e
        printf '%s' "$CANARY_PAYLOAD" | "$SECRETS_HOOK_EXE" >/dev/null 2>&1
        secrets_rc=$?
        set -e
        if [ "$secrets_rc" -ne 2 ]; then
            emit_fail "K. wired secrets scanner did NOT block a known-bad secret (exit=$secrets_rc, expected 2)"
        else
            emit_pass "K. secrets scanner wired + rejects a known-bad secret (path-confined, manifest-matched, exit=2 canary)"
        fi
    fi
fi

# --- Layer L — PreToolUse[SendMessage] guard-resume-isolation.sh (WARN-ONLY) ---
#
# The resume-guard (scripts/hooks/guard-resume-isolation.sh) is the
# PreToolUse[SendMessage] gate that blocks resuming a completed teammate whose
# worktree was already landed + removed (the spawn-side guard-worktree-isolation
# .sh only fires on Agent SPAWNS, never on resumes). It is intentionally NOT a
# hard gate — a broken resume-guard is an unrelated failure domain from the
# write/spawn/config hard gates above — so drift here is surfaced as a WARNING
# and never increments FAIL. install.sh keeps its sidecar in sync.
SENDMSG_CMD="$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for entry in data.get("hooks", {}).get("PreToolUse", []):
    if entry.get("matcher") != "SendMessage":
        continue
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if cmd:
            print(cmd)
            sys.exit(0)
PY
)"
CANONICAL_SENDMSG_HOOK="$REPO_ROOT/scripts/hooks/guard-resume-isolation.sh"
if [ -z "$SENDMSG_CMD" ]; then
    emit_warn "L. PreToolUse[SendMessage] guard-resume-isolation.sh NOT wired in settings.json (run scripts/hooks/install.sh; resume-guard disabled)"
else
    RESOLVED_SENDMSG_CMD="${SENDMSG_CMD//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_SENDMSG_CMD="${RESOLVED_SENDMSG_CMD//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    SENDMSG_PATH="${RESOLVED_SENDMSG_CMD%% *}"
    SENDMSG_REAL="$(realpath_of "$SENDMSG_PATH")"
    CANON_SENDMSG_REAL="$(realpath_of "$CANONICAL_SENDMSG_HOOK")"
    if [ ! -x "$SENDMSG_PATH" ]; then
        emit_warn "L. guard-resume-isolation.sh not found / not executable: $SENDMSG_PATH"
    elif [ "$SENDMSG_REAL" != "$CANON_SENDMSG_REAL" ]; then
        emit_warn "L. guard-resume-isolation.sh not confined to canonical location (wired: $SENDMSG_REAL)"
    else
        SENDMSG_HASH="$(sha256_of "$SENDMSG_REAL")"
        SENDMSG_MANIFEST="$(manifest_hash_of "$CANONICAL_SENDMSG_HOOK")"
        if [ -n "$SENDMSG_MANIFEST" ] && [ "$SENDMSG_HASH" != "$SENDMSG_MANIFEST" ]; then
            emit_warn "L. guard-resume-isolation.sh content hash differs from manifest (run scripts/hooks/install.sh and review the diff)"
        else
            # Functional canary: a SendMessage to a specific recipient with a
            # session that cannot resolve any team config must fail closed
            # (exit 2). Force an empty teams dir so resolution can't succeed —
            # this proves the guard's block path has teeth, independent of the
            # live machine's actual team state.
            SENDMSG_CANARY_TEAMS="$(mktemp -d -t integrity-resume-canary.XXXXXX)"
            SENDMSG_CANARY_PAYLOAD='{"tool_name":"SendMessage","tool_input":{"to":"ghost-teammate","message":"are you there?"},"session_id":"00000000-no-such-session"}'
            set +e
            printf '%s' "$SENDMSG_CANARY_PAYLOAD" | RESUME_GUARD_TEAMS_DIR="$SENDMSG_CANARY_TEAMS" "$SENDMSG_PATH" >/dev/null 2>&1
            sendmsg_rc=$?
            set -e
            rm -rf "$SENDMSG_CANARY_TEAMS"
            if [ "$sendmsg_rc" -ne 2 ]; then
                emit_warn "L. wired resume-guard did NOT block an unresolvable resume (exit=$sendmsg_rc, expected 2) — resume-guard may be a no-op"
            else
                emit_pass "L. PreToolUse[SendMessage] guard-resume-isolation.sh wired + blocks an unresolvable resume (path-confined, manifest-matched, exit=2 canary)"
            fi
        fi
    fi
fi

# --- Layer M — REGISTRATION UNIQUENESS (single-fire) ---------------------
#
# THE INVISIBLE DEFECT THIS LAYER MAKES VISIBLE: Claude Code reads BOTH
# .claude/settings.json AND .claude/settings.local.json and MERGES their hook
# arrays ADDITIVELY. When the pre-fix install.sh wrote a resolved COPY of the
# hook stanzas into settings.json, every hook was registered TWICE and fired
# TWICE per matching tool event — silently, because the guards that only exit
# 0/2 are idempotent; only the append-loggers (resume-acks.log, and the sibling
# main-checkout/data-contract loggers) showed it, as byte-identical duplicate
# lines. This layer counts each canonical hook's registrations across BOTH
# files and FAILS if any is registered more than once, so the double-fire can
# never again hide. The migration is `scripts/hooks/install.sh` (removes/strips
# hooks from settings.json).
UNIQ_PY="$(python3 - "$SETTINGS" "$SETTINGS_JSON" "$REPO_ROOT" <<'PY'
import json, os, sys

local_path, json_path, repo_root = sys.argv[1:4]

# Canonical hook basenames — every enforcement/log hook install.sh manages.
CANON = [
    "guard-worktree-isolation.sh",
    "guard-definition-drift.sh",
    "snapshot-agent-definitions.sh",
    "reader-teammate-hint.sh",
    "verify-agent-prompt.sh",
    "guard-main-checkout-writes.sh",
    "guard-bash-main-writes.sh",
    "scan-secrets.sh",
    "guard-resume-isolation.sh",
    "detect-nonnative-worktree.sh",
    "teammate-idle-handoff.sh",
    "task-completed-handoff.sh",
    "session-start-reap-worktrees.sh",
]

def load(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def commands(data):
    """Yield every hook command string across every event in a settings dict."""
    if not isinstance(data, dict):
        return
    for event, entries in (data.get("hooks") or {}).items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            for h in (entry.get("hooks") or []):
                cmd = h.get("command", "")
                if cmd:
                    yield cmd

def basename_of(cmd):
    path = cmd.replace("$CLAUDE_PROJECT_DIR", repo_root) \
              .replace("${CLAUDE_PROJECT_DIR}", repo_root)
    path = path.split()[0] if path.split() else path
    return os.path.basename(path)

local = load(local_path)
sjson = load(json_path) if os.path.exists(json_path) else None

# Count registrations per canonical hook across BOTH files, and per file.
counts = {name: 0 for name in CANON}
local_counts = {name: 0 for name in CANON}
json_counts = {name: 0 for name in CANON}
for cmd in commands(local):
    b = basename_of(cmd)
    if b in counts:
        counts[b] += 1
        local_counts[b] += 1
for cmd in commands(sjson):
    b = basename_of(cmd)
    if b in counts:
        counts[b] += 1
        json_counts[b] += 1

# settings.json total hook-command count (any value > 0 is the double-fire root)
sjson_total = sum(1 for _ in commands(sjson)) if sjson is not None else 0

# Emit machine-readable verdict lines.
print(f"sjson_present\t{1 if sjson is not None else 0}")
print(f"sjson_hook_total\t{sjson_total}")
print(f"resume_count\t{counts['guard-resume-isolation.sh']}")
for name in CANON:
    print(f"count\t{name}\t{counts[name]}\t{local_counts[name]}\t{json_counts[name]}")
PY
)"

# Parse the verdict.
SJSON_HOOK_TOTAL="$(printf '%s\n' "$UNIQ_PY" | awk -F'\t' '$1=="sjson_hook_total"{print $2; exit}')"
RESUME_COUNT="$(printf '%s\n' "$UNIQ_PY" | awk -F'\t' '$1=="resume_count"{print $2; exit}')"

M_OK=1
# M1 — settings.json must carry NO hook stanzas (the additive double-fire root).
if [ "${SJSON_HOOK_TOTAL:-0}" != "0" ]; then
    emit_fail "M. .claude/settings.json registers $SJSON_HOOK_TOTAL hook(s) — Claude Code MERGES it with settings.local.json, so every duplicated hook fires TWICE. Run scripts/hooks/install.sh to de-duplicate (canonical source is settings.local.json)."
    M_OK=0
fi
# M2 — no canonical hook registered more than once across the merged set.
while IFS=$'\t' read -r _tag _name _total _lc _jc; do
    [ "$_tag" = "count" ] || continue
    if [ "${_total:-0}" -gt 1 ]; then
        emit_fail "M. hook '$_name' registered ${_total}x across settings.local.json(${_lc}) + settings.json(${_jc}) — expected exactly 1 (double-fire). Run scripts/hooks/install.sh."
        M_OK=0
    fi
done < <(printf '%s\n' "$UNIQ_PY")

# M3 — LIVE single-fire canary: drive the resume-guard's append path exactly as
# many times as it is registered in the MERGED settings (post-fix: once) and
# assert the log holds EXACTLY ONE line. A single registration must yield a
# single append; the guard's own consecutive-duplicate dedup (defense-in-depth)
# stays underneath so even a regressed double registration would collapse to one
# line — but M1/M2 would already have failed on that. Warn-only if the sandbox
# can't be built (never blocks device QA on canary plumbing).
CANARY_GUARD="$REPO_ROOT/scripts/hooks/guard-resume-isolation.sh"
if [ "$M_OK" -eq 1 ] && [ -x "$CANARY_GUARD" ] && command -v mktemp >/dev/null 2>&1; then
    FIRES="${RESUME_COUNT:-1}"; [ "$FIRES" -ge 1 ] 2>/dev/null || FIRES=1
    CANARY_DIR="$(mktemp -d -t contract-integrity-canary.XXXXXX 2>/dev/null || true)"
    if [ -n "$CANARY_DIR" ]; then
        mkdir -p "$CANARY_DIR/scripts/hooks" "$CANARY_DIR/scripts/lib" "$CANARY_DIR/.claude" 2>/dev/null || true
        cp "$CANARY_GUARD" "$CANARY_DIR/scripts/hooks/guard-resume-isolation.sh" 2>/dev/null || true
        # The copied guard resolves its library relative to its own location and
        # refuses to start without it, so the canary sandbox has to be a
        # complete-enough engine, and has to DECLARE itself as the governed root
        # (below) rather than letting the guard inherit the probe's own repo.
        cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$CANARY_DIR/scripts/lib/" 2>/dev/null || true
        printf 'SESSION_TEAMS_DIR=""\n' >"$CANARY_DIR/orchestration.config" 2>/dev/null || true
        chmod +x "$CANARY_DIR/scripts/hooks/guard-resume-isolation.sh" 2>/dev/null || true
        CANARY_PAYLOAD='{"tool_name":"SendMessage","tool_input":{"to":"canary-done","message":"resume-ack: single-fire probe canary — no writes"}}'
        i=0
        while [ "$i" -lt "$FIRES" ]; do
            printf '%s' "$CANARY_PAYLOAD" | RICHOS_ENTITY_ROOT="$CANARY_DIR" "$CANARY_DIR/scripts/hooks/guard-resume-isolation.sh" >/dev/null 2>&1 || true
            i=$((i+1))
        done
        CANARY_LINES="$(wc -l < "$CANARY_DIR/.claude/state/resume-acks.log" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "${CANARY_LINES:-0}" = "1" ]; then
            emit_pass "M. registration uniqueness — each canonical hook wired exactly once; single-fire canary logged 1 line for $FIRES registration(s)"
        else
            emit_fail "M. single-fire canary logged ${CANARY_LINES:-0} lines for $FIRES registration(s), expected 1 — the resume-guard append path is not single-fire."
            M_OK=0
        fi
        rm -rf "$CANARY_DIR" 2>/dev/null || true
    else
        [ "$M_OK" -eq 1 ] && emit_warn "M. registration uniqueness verified, but the SINGLE-FIRE CANARY DID NOT RUN — no sandbox directory could be created. Nothing here proves the resume-guard append path is single-fire; a double-appending guard would not be caught by this run."
    fi
elif [ "$M_OK" -eq 1 ]; then
    emit_warn "M. registration uniqueness verified, but the SINGLE-FIRE CANARY DID NOT RUN — the guard is missing/non-executable, mktemp is unavailable, or a prior M check already failed. Wiring is verified; BEHAVIOUR IS NOT."
fi

# --- Layer N — canonical settings.local.json is GIT-TRACKED --------------
#
# See the header comment for the silent global-gitignore stranding trap this
# guards against. Three outcomes inside a git work tree:
#   tracked                       -> PASS  (it reaches the next clone)
#   untracked AND ignore-matched  -> FAIL  (the trap: looks committed, isn't)
#   untracked AND not ignored     -> WARN  (likely just not committed yet)
# Outside a git work tree (or git unavailable) the check cannot apply, so it is
# skipped with a warning rather than failing — the probe's non-git sandboxes and
# any pre-init copy must not hard-fail here.
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" ls-files --error-unmatch -- .claude/settings.local.json >/dev/null 2>&1; then
        emit_pass "N. .claude/settings.local.json is git-tracked (will reach the next clone)"
    elif git -C "$REPO_ROOT" check-ignore -q -- .claude/settings.local.json 2>/dev/null; then
        emit_fail "N. .claude/settings.local.json exists on disk but is NOT git-tracked AND is matched by a gitignore rule (commonly a GLOBAL ~/.config/git/ignore '**/.claude/settings.local.json' entry — vanilla Claude Code treats that file as machine-local). 'git add -A' SILENTLY skipped it, so it looks committed but the NEXT clone/session will NOT receive it — the orchestrator will spawn ZERO teammates with no error. Fix: git add -f .claude/settings.local.json  (then commit)."
    else
        emit_warn "N. .claude/settings.local.json is present but not yet git-tracked (no ignore rule matches it — likely just not committed yet). It is committed BY DESIGN (the sole hook-registration source + the two critical keys); commit it before the next clone or the next session strands with no teammates: git add .claude/settings.local.json"
    fi
else
    emit_warn "N. git-tracked check skipped — $REPO_ROOT is not a git work tree (or git unavailable). In a real adopter repo .claude/settings.local.json MUST be committed; verify with: git ls-files .claude/settings.local.json"
fi

# --- Layer O: Bash-write guard wired + path-confined + manifest-matched +
# functionally denies a main-checkout source write (HARD gate) ---
#
# guard-bash-main-writes.sh (PreToolUse[Bash]) closes the cwd-default drift
# vector: a raw `cd <main> && mkdir <tree>/...` / absolute-path write that the
# Write/Edit guard (Layer B) never sees, and which otherwise surfaces as an
# interactive permission prompt to the human operator. HARD gate for the same
# reason as B/K: an unwired, shimmed, or gutted Bash-guard silently reopens the
# "agent scaffolds into the shared checkout" failure class. Layer O searches the
# full Bash-matcher list so wiring order is irrelevant.
BASHGUARD_WIRED_CMD=""
for c in "${BASH_CMDS[@]}"; do
    RESOLVED_C="${c//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_C="${RESOLVED_C//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    WIRED_PATH_C="${RESOLVED_C%% *}"
    if [ "$(realpath_of "$WIRED_PATH_C")" = "$(realpath_of "$CANONICAL_BASHGUARD_HOOK")" ]; then
        BASHGUARD_WIRED_CMD="$RESOLVED_C"
        break
    fi
done

if [ -z "$BASHGUARD_WIRED_CMD" ]; then
    emit_fail "O. PreToolUse[Bash] main-write guard (guard-bash-main-writes.sh) NOT wired in settings.json — run scripts/hooks/install.sh (and confirm the Bash matcher stanza is present)"
else
    BASHGUARD_HOOK_EXE="${BASHGUARD_WIRED_CMD%% *}"
    BASHGUARD_REAL="$(realpath_of "$BASHGUARD_HOOK_EXE")"
    BASHGUARD_HASH="$(sha256_of "$BASHGUARD_REAL")"
    BASHGUARD_MANIFEST="$(manifest_hash_of "$CANONICAL_BASHGUARD_HOOK")"
    # First protected tree, for the functional canary.
    BASHGUARD_FIRST=""
    for p in $PROTECTED_PATHS; do BASHGUARD_FIRST="$p"; break; done
    if [ ! -x "$BASHGUARD_HOOK_EXE" ]; then
        emit_fail "O. wired Bash-guard script not found / not executable: $BASHGUARD_HOOK_EXE"
    elif [ -z "$BASHGUARD_HASH" ]; then
        emit_fail "O. Bash-guard content hash could not be computed"
    elif [ -z "$BASHGUARD_MANIFEST" ]; then
        emit_fail "O. Bash-guard manifest missing or unreadable: $CANONICAL_BASHGUARD_HOOK.sha256 — run scripts/hooks/install.sh to regenerate, then commit."
    elif [ "$BASHGUARD_HASH" != "$BASHGUARD_MANIFEST" ]; then
        emit_fail "O. Bash-guard content hash mismatch — live hook differs from manifest (tamper or stale manifest). Run scripts/hooks/install.sh and review the diff."
    elif [ -z "$BASHGUARD_FIRST" ]; then
        # No protected trees configured — the guard is intentionally inactive
        # (matches the write-guard's sensible-failure contract). Cannot exercise
        # the deny canary, so surface it as a WARN rather than a false PASS/FAIL.
        emit_warn "O. Bash-guard wired + manifest-matched, but PROTECTED_PATHS is empty in orchestration.config — guard is INACTIVE (deny canary skipped). Fill PROTECTED_PATHS to activate it."
    else
        # Functional canary: a Bash command that writes into the first protected
        # tree via a RELATIVE path while the Bash cwd IS the checkout (the real
        # drift vector). Chosen over an absolute-path canary deliberately: the
        # guard's abs-path branch exempts anything under .claude/worktrees/, and
        # when the probe itself runs from inside an isolated worktree REPO_ROOT
        # already contains that segment — so an abs canary would be self-exempted
        # and give a false PASS. The cwd==ROOT relative branch has no such
        # ambiguity. The wired guard must return exit 2.
        BASHGUARD_CANARY_PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"mkdir -p "+sys.argv[1]+"/__bashguard_canary__"},"cwd":sys.argv[2]}))' "$BASHGUARD_FIRST" "$REPO_ROOT" 2>/dev/null || true)"
        set +e
        printf '%s' "$BASHGUARD_CANARY_PAYLOAD" | "$BASHGUARD_HOOK_EXE" >/dev/null 2>&1
        bashguard_rc=$?
        set -e
        if [ "$bashguard_rc" -ne 2 ]; then
            emit_fail "O. wired Bash-guard did NOT block a main-checkout '$BASHGUARD_FIRST' source write (exit=$bashguard_rc, expected 2)"
        else
            emit_pass "O. Bash-write guard wired + denies a main-checkout source write (path-confined, manifest-matched, exit=2 canary)"
        fi
    fi
fi

# --- Layer P: DEFINITION-DRIFT GUARD PAIR wired exactly once + path-confined +
# manifest-matched + functionally blocks drift AND allows a clean spawn (HARD gate) ---
#
# THE FAILURE THIS PAIR CLOSES (upstream, 2026-08-06, 25 rejected deliverables):
# `.claude/agents/*.md` definitions load ONCE at SESSION START — like hooks — so a
# definition installed/updated mid-session never reaches a newly spawned agent's
# BOOTED prompt. A teammate's definition was upgraded (v2.0 -> v2.1) and the work
# dispatched in that same session; three of four batches drafted under the stale
# v2.0 contract, with nothing anywhere reporting the mismatch.
#
# The pair:
#   SessionStart      -> snapshot-agent-definitions.sh (records the baseline)
#   PreToolUse[Agent] -> guard-definition-drift.sh     (blocks a drifted spawn)
# Either half alone is useless: no snapshot means the guard has nothing to compare
# and fails OPEN by design, so an unwired snapshotter silently disables the guard
# without any block ever being seen. That silence is exactly why this is a HARD
# gate (like B/C/K/O) rather than a warn-only layer (F/G/H/L): a drift guard that
# fails open unnoticed is indistinguishable from no guard at all.
#
# Layer C already hard-checks guard-definition-drift.sh's chain POSITION and hash;
# this layer adds the exactly-once counts, the SessionStart half, and the paired
# functional canaries.
DRIFTGUARD_HITS=0
DRIFTGUARD_WIRED_CMD=""
for c in "${AGENT_CMDS[@]}"; do
    RESOLVED_C="${c//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_C="${RESOLVED_C//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    WIRED_PATH_C="${RESOLVED_C%% *}"
    if [ "$(realpath_of "$WIRED_PATH_C")" = "$(realpath_of "$CANONICAL_DRIFTGUARD_HOOK")" ]; then
        [ -z "$DRIFTGUARD_WIRED_CMD" ] && DRIFTGUARD_WIRED_CMD="$RESOLVED_C"
        DRIFTGUARD_HITS=$((DRIFTGUARD_HITS+1))
    fi
done

# Every SessionStart command (the snapshotter shares the event with the
# knowledge-verification echo and the worktree reaper, so we search the full
# list).
SESSIONSTART_CMDS=()
while IFS= read -r line; do
    [ -n "$line" ] && SESSIONSTART_CMDS+=("$line")
done < <(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
for entry in data.get("hooks", {}).get("SessionStart", []):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if cmd:
            print(cmd)
PY
)

DEFSNAPSHOT_HITS=0
DEFSNAPSHOT_WIRED_CMD=""
for c in "${SESSIONSTART_CMDS[@]}"; do
    RESOLVED_C="${c//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_C="${RESOLVED_C//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    WIRED_PATH_C="${RESOLVED_C%% *}"
    if [ "$(realpath_of "$WIRED_PATH_C")" = "$(realpath_of "$CANONICAL_DEFSNAPSHOT_HOOK")" ]; then
        [ -z "$DEFSNAPSHOT_WIRED_CMD" ] && DEFSNAPSHOT_WIRED_CMD="$RESOLVED_C"
        DEFSNAPSHOT_HITS=$((DEFSNAPSHOT_HITS+1))
    fi
done

P_OK=1
# P1 — PreToolUse[Agent] drift guard wired exactly once.
if [ "$DRIFTGUARD_HITS" -eq 0 ]; then
    emit_fail "P. PreToolUse[Agent] definition-drift guard (guard-definition-drift.sh) NOT wired in settings.local.json — a mid-session agent-definition change can again reach a spawn silently (the stale-snapshot failure). Restore: git checkout -- .claude/settings.local.json"
    P_OK=0
elif [ "$DRIFTGUARD_HITS" -gt 1 ]; then
    emit_fail "P. guard-definition-drift.sh wired ${DRIFTGUARD_HITS}x under the Agent matcher — expected exactly 1 (double-fire). Remove the duplicate stanza from .claude/settings.local.json."
    P_OK=0
fi
# P2 — SessionStart snapshotter wired exactly once.
if [ "$DEFSNAPSHOT_HITS" -eq 0 ]; then
    emit_fail "P. SessionStart definition snapshotter (snapshot-agent-definitions.sh) NOT wired in settings.local.json — with no session-start baseline the drift guard fails OPEN and blocks nothing, silently. Restore: git checkout -- .claude/settings.local.json"
    P_OK=0
elif [ "$DEFSNAPSHOT_HITS" -gt 1 ]; then
    emit_fail "P. snapshot-agent-definitions.sh wired ${DEFSNAPSHOT_HITS}x under SessionStart — expected exactly 1 (double-fire). Remove the duplicate stanza from .claude/settings.local.json."
    P_OK=0
fi

# P3 — both scripts present + executable, sidecars current.
for pair in "drift-guard|$CANONICAL_DRIFTGUARD_HOOK" "definition-snapshotter|$CANONICAL_DEFSNAPSHOT_HOOK"; do
    P_LABEL="${pair%%|*}"
    P_HOOK="${pair#*|}"
    if [ ! -x "$P_HOOK" ]; then
        emit_fail "P. $P_LABEL not found / not executable: $P_HOOK"
        P_OK=0
        continue
    fi
    P_HASH="$(sha256_of "$(realpath_of "$P_HOOK")")"
    P_MANIFEST="$(manifest_hash_of "$P_HOOK")"
    if [ -z "$P_HASH" ]; then
        emit_fail "P. $P_LABEL content hash could not be computed"
        P_OK=0
    elif [ -z "$P_MANIFEST" ]; then
        emit_fail "P. $P_LABEL manifest missing or unreadable: $P_HOOK.sha256 — run scripts/hooks/install.sh to regenerate."
        P_OK=0
    elif [ "$P_HASH" != "$P_MANIFEST" ]; then
        emit_fail "P. $P_LABEL content hash mismatch — live hook differs from manifest (tamper or stale manifest). Expected $P_MANIFEST, got $P_HASH. Run scripts/hooks/install.sh and review the diff."
        P_OK=0
    fi
done

# P4 — PAIRED functional canaries in a throwaway sandbox: the guard must BLOCK a
# definition modified since the snapshot (exit 2) AND ALLOW an untouched one
# (exit 0). Both halves are required — a negative test alone passes for the wrong
# reason if the hook is broken into blocking everything, and a positive test alone
# passes if it is gutted into allowing everything. DEFINITION_DRIFT_ROOT pins both
# hooks to the sandbox so this NEVER reads or writes the real .claude/state.
if [ "$P_OK" -eq 1 ] && [ -x "$CANONICAL_DRIFTGUARD_HOOK" ] && [ -x "$CANONICAL_DEFSNAPSHOT_HOOK" ] && command -v mktemp >/dev/null 2>&1; then
    P_DIR="$(mktemp -d -t contract-integrity-driftcanary.XXXXXX 2>/dev/null || true)"
    if [ -n "$P_DIR" ]; then
        mkdir -p "$P_DIR/.claude/agents" "$P_DIR/.claude/state" 2>/dev/null || true
        # DEFINITION_DRIFT_ROOT now feeds the contract's DECLARED-root candidate,
        # and a declared root must be an adopted one — the resolver refuses to
        # substitute a different repository for a root somebody named. So the
        # canary sandbox carries the marker, exactly like a real governed repo.
        printf 'PROTECTED_PATHS="src"\n' >"$P_DIR/orchestration.config" 2>/dev/null || true
        printf 'canary definition v1\n' >"$P_DIR/.claude/agents/canaryagent.md" 2>/dev/null || true
        printf 'stable definition\n'    >"$P_DIR/.claude/agents/stableagent.md" 2>/dev/null || true
        P_SESSION="cafebabe-0000-4000-8000-000000000000"
        DEFINITION_DRIFT_ROOT="$P_DIR" "$CANONICAL_DEFSNAPSHOT_HOOK" --session "$P_SESSION" >/dev/null 2>&1 || true
        # Drift ONE definition only; the other must stay allowable.
        printf 'canary definition v2 — installed mid-session\n' >"$P_DIR/.claude/agents/canaryagent.md" 2>/dev/null || true
        P_PAYLOAD_DRIFT="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Agent","tool_input":{"subagent_type":"canaryagent","name":"canary-sonnet-p1","prompt":"integrity probe canary","isolation":"worktree"},"session_id":sys.argv[1]}))' "$P_SESSION" 2>/dev/null || true)"
        P_PAYLOAD_CLEAN="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Agent","tool_input":{"subagent_type":"stableagent","name":"stable-sonnet-p1","prompt":"integrity probe canary","isolation":"worktree"},"session_id":sys.argv[1]}))' "$P_SESSION" 2>/dev/null || true)"
        set +e
        printf '%s' "$P_PAYLOAD_DRIFT" | DEFINITION_DRIFT_ROOT="$P_DIR" "$CANONICAL_DRIFTGUARD_HOOK" >/dev/null 2>&1
        p_drift_rc=$?
        printf '%s' "$P_PAYLOAD_CLEAN" | DEFINITION_DRIFT_ROOT="$P_DIR" "$CANONICAL_DRIFTGUARD_HOOK" >/dev/null 2>&1
        p_clean_rc=$?
        set -e
        if [ "$p_drift_rc" -ne 2 ]; then
            emit_fail "P. wired definition-drift guard did NOT block a definition modified since the session-start snapshot (exit=$p_drift_rc, expected 2) — the guard has been gutted."
            P_OK=0
        elif [ "$p_clean_rc" -ne 0 ]; then
            emit_fail "P. definition-drift guard blocked an UNCHANGED definition (exit=$p_clean_rc, expected 0) — it is over-blocking; every spawn would be denied."
            P_OK=0
        else
            emit_pass "P. definition-drift pair wired exactly once (SessionStart snapshotter + PreToolUse[Agent] guard) + blocks drift (exit=2) + allows unchanged (exit=0) — path-confined, manifest-matched"
        fi
        rm -rf "$P_DIR" 2>/dev/null || true
    else
        emit_warn "P. definition-drift pair is wired and hashed, but the BLOCK/ALLOW CANARIES DID NOT RUN — no sandbox directory could be created. Nothing here proves the guard actually blocks a drifted definition or allows a clean one; a gutted guard would not be caught by this run."
    fi
elif [ "$P_OK" -eq 1 ]; then
    emit_warn "P. definition-drift pair is wired and hashed, but the BLOCK/ALLOW CANARIES DID NOT RUN — a half is missing/non-executable, mktemp is unavailable, or a prior P check already failed. Wiring is verified; BEHAVIOUR IS NOT."
fi

# --- Layer Q: WORKTREE-REAPER CHAIN wired exactly once + path-confined +
# manifest-matched + functionally sweeps a SANDBOX without touching unlanded
# work (HARD gate) ---
#
# THE CHAIN: SessionStart -> session-start-reap-worktrees.sh (thin wrapper)
#                         -> scripts/reap-stale-worktrees.sh --execute --unlock-stale
# It exists because landed-but-never-removed teammate worktrees quietly pile up
# across restarts (43 of them upstream before anyone noticed); the reaper's own
# header carries the full four-gate contract.
#
# WHY A HARD GATE, AND WHY BOTH HALVES: this is the ONLY hook-reachable code in
# the engine that DELETES things — `git worktree remove` + `git branch -d`, run
# with --execute on every single session start. Its failure modes are asymmetric
# and both invisible: gutted, worktrees silently accumulate again (the exact
# regression the hook exists to prevent, and nothing ever reports it); over-
# reaching, it removes a tree carrying unlanded work — a teammate's whole
# handoff — and again nothing reports it. Hashing the wrapper alone would be
# integrity theatre, since the wrapper deletes nothing; so Layer Q covers BOTH
# halves and pairs its canaries (sweeps what it should, refuses what it must
# not), mirroring Layer P's block/allow pairing.
#
# SIDE-EFFECT SAFETY: the canary NEVER runs against this repo. REAP_WORKTREES_ROOT
# (test-only override, see the wrapper's header) retargets the sweep at a
# throwaway git repo built under mktemp, while the wrapper still resolves and
# runs the canonical, manifest-verified reaper. Real worktrees are untouched.
REAPHOOK_HITS=0
REAPHOOK_WIRED_CMD=""
for c in "${SESSIONSTART_CMDS[@]}"; do
    RESOLVED_C="${c//\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    RESOLVED_C="${RESOLVED_C//\$\{CLAUDE_PROJECT_DIR\}/$REPO_ROOT}"
    WIRED_PATH_C="${RESOLVED_C%% *}"
    if [ "$(realpath_of "$WIRED_PATH_C")" = "$(realpath_of "$CANONICAL_REAPHOOK")" ]; then
        [ -z "$REAPHOOK_WIRED_CMD" ] && REAPHOOK_WIRED_CMD="$RESOLVED_C"
        REAPHOOK_HITS=$((REAPHOOK_HITS+1))
    fi
done

Q_OK=1
# Q1 — SessionStart wrapper wired exactly once.
if [ "$REAPHOOK_HITS" -eq 0 ]; then
    emit_fail "Q. SessionStart worktree reaper (session-start-reap-worktrees.sh) NOT wired in settings.local.json — landed teammate worktrees will accumulate silently again. Restore: git checkout -- .claude/settings.local.json"
    Q_OK=0
elif [ "$REAPHOOK_HITS" -gt 1 ]; then
    emit_fail "Q. session-start-reap-worktrees.sh wired ${REAPHOOK_HITS}x under SessionStart — expected exactly 1 (double-fire: two concurrent --execute sweeps of the same worktree set). Remove the duplicate stanza from .claude/settings.local.json."
    Q_OK=0
fi

# Q2 — both halves present + executable, sidecars current.
for pair in "reaper-hook|$CANONICAL_REAPHOOK" "reaper|$CANONICAL_REAPER"; do
    Q_LABEL="${pair%%|*}"
    Q_HOOK="${pair#*|}"
    if [ ! -x "$Q_HOOK" ]; then
        emit_fail "Q. $Q_LABEL not found / not executable: $Q_HOOK"
        Q_OK=0
        continue
    fi
    Q_HASH="$(sha256_of "$(realpath_of "$Q_HOOK")")"
    Q_MANIFEST="$(manifest_hash_of "$Q_HOOK")"
    if [ -z "$Q_HASH" ]; then
        emit_fail "Q. $Q_LABEL content hash could not be computed"
        Q_OK=0
    elif [ -z "$Q_MANIFEST" ]; then
        emit_fail "Q. $Q_LABEL manifest missing or unreadable: $Q_HOOK.sha256 — run scripts/hooks/install.sh to regenerate."
        Q_OK=0
    elif [ "$Q_HASH" != "$Q_MANIFEST" ]; then
        emit_fail "Q. $Q_LABEL content hash mismatch — live script differs from manifest (tamper or stale manifest). Expected $Q_MANIFEST, got $Q_HASH. Run scripts/hooks/install.sh and review the diff — this script deletes worktrees and branches."
        Q_OK=0
    fi
done

# Q3 — PAIRED functional canaries in a throwaway git sandbox: two agent-shaped
# worktrees, one merged+clean (must be REAPED) and one carrying uncommitted work
# (must SURVIVE). A sweep-only test would pass against a reaper that deletes
# everything; a refusal-only test would pass against one that deletes nothing.
if [ "$Q_OK" -eq 1 ] && [ -x "$CANONICAL_REAPHOOK" ] && [ -x "$CANONICAL_REAPER" ] \
   && command -v git >/dev/null 2>&1 && command -v mktemp >/dev/null 2>&1; then
    # `pwd -P` matters: on macOS mktemp hands back a /var/... symlink while
    # `git worktree list` reports the resolved /private/var/... path, and the
    # reaper's `.claude/worktrees/agent-*` path match would silently never fire.
    Q_DIR="$(cd "$(mktemp -d -t contract-integrity-reap.XXXXXX 2>/dev/null)" 2>/dev/null && pwd -P || true)"
    if [ -n "$Q_DIR" ]; then
        Q_REPO="$Q_DIR/repo"
        Q_REAPABLE="$Q_REPO/.claude/worktrees/agent-q0000001"
        Q_PROTECTED="$Q_REPO/.claude/worktrees/agent-q0000002"
        Q_SANDBOX_OK=1
        mkdir -p "$Q_REPO/.claude/worktrees" 2>/dev/null || Q_SANDBOX_OK=0
        git -C "$Q_REPO" init -q -b main >/dev/null 2>&1 || Q_SANDBOX_OK=0
        # NO local identity override. This throwaway repo inherits the
        # operator's real global identity, which is what a machine-wide
        # pre-commit identity guard requires. With a fake one the seed commit
        # is REFUSED, Q_SANDBOX_OK flips to 0, and the canary below silently
        # does not run — which is how a GUTTED reaper passed this layer.
        printf 'seed\n' >"$Q_REPO/seed.txt" 2>/dev/null || Q_SANDBOX_OK=0
        git -C "$Q_REPO" add seed.txt >/dev/null 2>&1 || Q_SANDBOX_OK=0
        git -C "$Q_REPO" commit -q -m "probe sandbox seed" >/dev/null 2>&1 || Q_SANDBOX_OK=0
        git -C "$Q_REPO" worktree add -q -b worktree-agent-q0000001 "$Q_REAPABLE" >/dev/null 2>&1 || Q_SANDBOX_OK=0
        git -C "$Q_REPO" worktree add -q -b worktree-agent-q0000002 "$Q_PROTECTED" >/dev/null 2>&1 || Q_SANDBOX_OK=0
        printf 'unlanded teammate work\n' >"$Q_PROTECTED/unlanded.txt" 2>/dev/null || Q_SANDBOX_OK=0

        if [ "$Q_SANDBOX_OK" -eq 1 ] && [ -d "$Q_REAPABLE" ] && [ -d "$Q_PROTECTED" ]; then
            set +e
            Q_OUT="$(REAP_WORKTREES_ROOT="$Q_REPO" "$CANONICAL_REAPHOOK" </dev/null 2>/dev/null)"
            q_rc=$?
            set -e
            if [ "$q_rc" -ne 0 ]; then
                emit_fail "Q. session-start reaper hook exited $q_rc on a sandbox sweep (expected 0) — this hook is log-only and must NEVER block a session start."
                Q_OK=0
            elif [ ! -d "$Q_PROTECTED" ]; then
                emit_fail "Q. reaper REMOVED a sandbox worktree carrying uncommitted work — the four safety gates are broken and a live sweep can destroy an unlanded handoff. Restore immediately: git checkout -- scripts/reap-stale-worktrees.sh"
                Q_OK=0
            elif [ -d "$Q_REAPABLE" ]; then
                emit_fail "Q. reaper did NOT remove a merged, clean, unlocked sandbox worktree — the sweep is gutted, so stale worktrees will pile up again unnoticed."
                Q_OK=0
            elif ! printf '%s' "$Q_OUT" | grep -q '"hookEventName": *"SessionStart"'; then
                emit_fail "Q. reaper hook emitted no SessionStart summary JSON (got: $Q_OUT) — a session-start reap can no longer be audited from the transcript."
                Q_OK=0
            elif ! printf '%s' "$Q_OUT" | grep -q 'reaped=1 skipped=1'; then
                emit_fail "Q. reaper hook summary did not report reaped=1 skipped=1 for the sandbox sweep (got: $Q_OUT) — the summary line no longer reflects what was swept."
                Q_OK=0
            else
                emit_pass "Q. worktree-reaper chain wired exactly once (SessionStart wrapper + reap-stale-worktrees.sh) + reaps a merged/clean tree (reaped=1) + REFUSES a dirty one (skipped=1) — path-confined, manifest-matched"
            fi
        else
            emit_warn "Q. FUNCTIONAL CANARY DID NOT RUN — the throwaway git sandbox could not be built, so nothing here proves the reaper actually reaps a clean tree or refuses a dirty one. Wiring and hashes are verified; BEHAVIOUR IS NOT. A gutted reaper would not be caught by this run."
        fi
        rm -rf "$Q_DIR" 2>/dev/null || true
    else
        emit_warn "Q. FUNCTIONAL CANARY DID NOT RUN — no sandbox directory could be created (mktemp). Wiring and hashes are verified; BEHAVIOUR IS NOT."
    fi
elif [ "$Q_OK" -eq 1 ]; then
    emit_warn "Q. FUNCTIONAL CANARY DID NOT RUN — git or mktemp unavailable, or a prior Q check already failed. Wiring and hashes are verified; BEHAVIOUR IS NOT."
fi

# --- Layer R: THE ROOT-RESOLUTION CONTRACT is wired, uniform and announced ---
#
# The guards no longer derive "the repository I protect" from where their own
# file happens to sit; they resolve it from the SESSION, through
# scripts/lib/resolve-roots.sh. That makes the resolver the single most
# consequential file in the mechanical layer — and gives it a failure mode with
# no external symptom: a hook that quietly reverted to the old
# `SCRIPT_DIR/../..` resolution looks exactly like a hook that did not, right
# up until it protects the wrong repository or protects nothing.
#
# R1 library present and hashed. R2 every root-resolving hook sources it.
# R3 the bootstrap block is byte-identical across them — a divergent copy is the
# original defect in miniature, one hook disagreeing with its siblings about
# what the root is. R4 engine-status.sh is registered, because it is the only
# thing in the system that answers "is this defence actually on?".
R_LIB="$ENGINE_ROOT/scripts/lib/resolve-roots.sh"
R_OK=1

if [ ! -f "$R_LIB" ]; then
    emit_fail "R. root-resolution contract MISSING: $R_LIB. Every guard's bootstrap refuses to start without it, so enforcement is off everywhere."
    R_OK=0
elif [ ! -f "$R_LIB.sha256" ]; then
    emit_fail "R. root-resolution contract unhashed: $R_LIB.sha256 missing — run scripts/hooks/install.sh to regenerate."
    R_OK=0
else
    R_LIVE="$(sha256_of "$R_LIB" 2>/dev/null || true)"
    R_WANT="$(tr -d '[:space:]' < "$R_LIB.sha256" 2>/dev/null || true)"
    if [ -n "$R_LIVE" ] && [ -n "$R_WANT" ] && [ "$R_LIVE" != "$R_WANT" ]; then
        emit_fail "R. root-resolution contract MODIFIED since install: $R_LIB (sha256 $R_LIVE != manifest $R_WANT). Every guard's root decision comes from this file — review the change, then re-run scripts/hooks/install.sh."
        R_OK=0
    fi
fi

# R2/R3 — the hooks that resolve a root.
R_ROOTED_HOOKS="engine-status guard-worktree-isolation guard-definition-drift \
reader-teammate-hint verify-agent-prompt guard-main-checkout-writes scan-secrets \
guard-resume-isolation guard-bash-main-writes detect-nonnative-worktree \
session-start-reap-worktrees snapshot-agent-definitions"

R_MISSING_SOURCE=""
R_BOOTSTRAP_REF=""
R_DIVERGENT=""
for h in $R_ROOTED_HOOKS; do
    f="$ENGINE_ROOT/scripts/hooks/$h.sh"
    [ -f "$f" ] || { R_MISSING_SOURCE="$R_MISSING_SOURCE $h(absent)"; continue; }
    if ! grep -q '\. "\$_RR_LIB"' "$f" 2>/dev/null; then
        R_MISSING_SOURCE="$R_MISSING_SOURCE $h"
        continue
    fi
    # The bootstrap runs from the '# --- ROOT RESOLUTION' banner to the
    # resolve_engine_root assignment. Everything in between is fixed text apart
    # from the hook's own name in the diagnostic and the exit code, so both are
    # normalised out before comparison — the point is that the MECHANISM is
    # identical, not that the messages are.
    blk="$(sed -n '/^# --- ROOT RESOLUTION ---/,/^ENGINE_ROOT="\$(resolve_engine_root/p' "$f" 2>/dev/null \
           | sed -e 's|scripts/hooks/[a-z-]*\.sh|<HOOK>|' -e 's|^    exit [0-9]*$|    exit <RC>|')"
    if [ -z "$blk" ]; then
        R_DIVERGENT="$R_DIVERGENT $h(no-bootstrap)"
        continue
    fi
    if [ -z "$R_BOOTSTRAP_REF" ]; then
        R_BOOTSTRAP_REF="$blk"
    elif [ "$blk" != "$R_BOOTSTRAP_REF" ]; then
        R_DIVERGENT="$R_DIVERGENT $h"
    fi
done

if [ -n "$R_MISSING_SOURCE" ]; then
    emit_fail "R. hook(s) do NOT source the root-resolution contract:$R_MISSING_SOURCE. A hook that resolves its root any other way has silently gone back to trusting its own on-disk location."
    R_OK=0
fi
if [ -n "$R_DIVERGENT" ]; then
    emit_fail "R. root-resolution bootstrap DIVERGED in:$R_DIVERGENT. Every rooted hook must carry the identical bootstrap; a divergent copy is one hook disagreeing with its siblings about which repository is being protected."
    R_OK=0
fi

# R4 — the status announcement must be registered, in the seated table AND (when
# the engine ships as a plugin) in hooks/hooks.json. An unregistered status hook
# means nobody is ever told whether enforcement is on, which is the failure this
# layer exists to make impossible.
if [ -f "$SETTINGS" ]; then
    if ! grep -q 'engine-status\.sh' "$SETTINGS" 2>/dev/null; then
        emit_fail "R. engine-status.sh is NOT registered in $SETTINGS. It is the only hook that reports whether enforcement is active, stood down, or broken — without it every other status in this probe is a claim nobody re-checks at session start."
        R_OK=0
    fi
fi
R_PLUGIN_HOOKS="$ENGINE_ROOT/hooks/hooks.json"
if [ -f "$R_PLUGIN_HOOKS" ] && ! grep -q 'engine-status\.sh' "$R_PLUGIN_HOOKS" 2>/dev/null; then
    emit_fail "R. engine-status.sh is registered for a seated session but NOT in $R_PLUGIN_HOOKS — so a plugin-loaded engine would announce nothing. The two registration surfaces must agree; one of them silently missing a hook is exactly the drift this probe exists to catch."
    R_OK=0
fi

if [ "$R_OK" -eq 1 ]; then
    emit_pass "R. root-resolution contract present + hashed + sourced by all 12 rooted hooks with a byte-identical bootstrap; engine-status.sh registered on both surfaces"
fi

if [ "$FAIL" -gt 0 ]; then
    cat >&2 <<EOF

Integrity probe FAILED — $FAIL layer(s) broken. Most fixes:

  - "settings.local.json missing" / "hook NOT wired"
       -> restore it: git checkout -- .claude/settings.local.json
  - "settings.json registers N hook(s)" / "registered Nx" / "double-fire"
       -> a stale hook-duplicating .claude/settings.json is being merged.
          Run: scripts/hooks/install.sh   (removes/strips it)
  - "wired write-guard did NOT block"
       -> the hook file has been modified into a no-op.
          \`git diff scripts/hooks/guard-main-checkout-writes.sh\` to see
          what changed, revert if accidental.
  - "wired hook script not found"
       -> the path in settings.local.json doesn't resolve. Re-check the
          committed wiring; run: scripts/hooks/install.sh
  - "env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS missing" / "worktree.baseRef missing"
       -> restore the missing key(s) in .claude/settings.local.json (see
          README.md's "Critical configuration — never remove" section), then
          re-run: scripts/hooks/install.sh
  - "secrets scanner NOT wired" / "did NOT block a known-bad secret"
       -> run scripts/hooks/install.sh; if the scanner still doesn't block,
          \`git diff scripts/hooks/scan-secrets.sh\` to see what changed.
  - "settings.local.json ... NOT git-tracked" (Layer N)
       -> a gitignore rule (usually a GLOBAL ~/.config/git/ignore
          '**/.claude/settings.local.json' entry) silently kept the
          committed-by-design file untracked. Force-add it:
          git add -f .claude/settings.local.json   (then commit)
  - "Bash main-write guard NOT wired" / "did NOT block a main-checkout ... write" (Layer O)
       -> run scripts/hooks/install.sh; confirm the PreToolUse[Bash] matcher
          stanza is present in .claude/settings.local.json; if it still doesn't
          block, \`git diff scripts/hooks/guard-bash-main-writes.sh\`.
  - "definition-drift guard NOT wired" / "definition snapshotter NOT wired" /
    "did NOT block a definition modified since the session-start snapshot" (Layer P)
       -> restore both halves in .claude/settings.local.json (SessionStart ->
          snapshot-agent-definitions.sh, PreToolUse[Agent] position 2 ->
          guard-definition-drift.sh), then run scripts/hooks/install.sh. Either
          half missing silently disables the pair: with no session-start
          snapshot the guard fails OPEN and blocks nothing.
  - "worktree reaper NOT wired" / "did NOT remove" / "REMOVED a ...
    worktree carrying uncommitted work" (Layer Q)
       -> the SessionStart worktree-reaper chain has been unwired, gutted,
          or has become dangerous. Restore both halves:
            git checkout -- .claude/settings.local.json \\
            scripts/hooks/session-start-reap-worktrees.sh \\
            scripts/reap-stale-worktrees.sh
          then: scripts/hooks/install.sh

See README.md (First-time setup) and orchestration.config.
EOF
    exit 2
fi

exit 0
