#!/usr/bin/env bash
#
# resolve-roots.test.sh — behavioral tests for the root-resolution contract
# (scripts/lib/resolve-roots.sh).
#
# THE PROPERTY UNDER TEST, in one sentence: when the engine's code lives in
# repository X and the session is running in repository Y, every guard must
# resolve Y — and when it cannot resolve anything, it must say so in a way
# nobody can mistake for success.
#
# Each case below is a PAIR: a positive arm proving the resolver produces the
# right answer, and a negative arm proving the same assertion FAILS when the
# property is absent. A negative test that passes for the wrong reason is this
# project's most-repeated defect, so several arms below deliberately construct
# the pre-contract situation (engine nested in a foreign repo) and assert that
# the OLD answer is NOT what comes back.
#
# The companion `root-contract.mutation.sh` closes the loop from the other end:
# it strips the fix out of each guard and asserts these tests then FAIL.
#
# Run directly: scripts/lib/resolve-roots.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/resolve-roots.sh"

PASS=0
FAIL=0
# `pwd -P` — on macOS mktemp hands back a /var/... symlink while git reports the
# resolved /private/var/... path. An unresolved sandbox root would make every
# path comparison below pass or fail for the wrong reason.
SANDBOX="$(cd "$(mktemp -d -t resolve-roots-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$LIB" ] || { echo "FATAL: library missing: $LIB" >&2; exit 1; }

# --- helpers ---------------------------------------------------------------

# make_repo <name> [--adopted] -> prints the repo path.
make_repo() {
    local repo="$SANDBOX/$1"; shift || true
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    # NO local user.email/user.name override. These throwaway fixtures inherit
    # the operator's real global identity, which is what the machine-wide
    # pre-commit identity guard requires. Setting a fake local identity would
    # make every fixture commit fail — and a fixture that never commits has no
    # main branch, so the worktree cases below would pass or fail for reasons
    # that have nothing to do with the property under test.
    printf 'seed\n' >"$repo/seed.txt"
    if [ "${1:-}" = "--adopted" ]; then
        printf 'PROTECTED_PATHS="src"\n' >"$repo/orchestration.config"
    fi
    git -C "$repo" add -A
    git -C "$repo" commit -q -m seed
    printf '%s\n' "$repo"
}

# make_engine_in <repo> <subdir> -> a full engine layout nested inside <repo>.
# Mirrors the real shape: scripts/hooks/, scripts/lib/ (with the two real
# library files copied in), orchestration.config, .claude/agents/.
make_engine_in() {
    local repo="$1" sub="$2" eng="$1/$2"
    mkdir -p "$eng/scripts/hooks" "$eng/scripts/lib" "$eng/.claude/agents" "$eng/.claude-plugin"
    cp "$LIB" "$eng/scripts/lib/resolve-roots.sh"
    cp "$SCRIPT_DIR/resolve-main-checkout.sh" "$eng/scripts/lib/resolve-main-checkout.sh"
    printf 'PROTECTED_PATHS="app"\n' >"$eng/orchestration.config"
    printf '{"name":"richos-engine","version":"1.0.0"}\n' >"$eng/.claude-plugin/plugin.json"
    printf -- '---\nname: clark\nmodel: sonnet\n---\nbody\n' >"$eng/.claude/agents/clark.md"
    printf '%s\n' "$eng"
}

# probe <engine-lib> <payload> — runs the resolver in a clean subshell with
# whatever env the caller exported, and prints four tab-separated fields:
#   rc <TAB> root <TAB> status <TAB> source
probe() {
    local lib="$1" payload="${2:-}"
    # cd to the (marker-free, non-git) sandbox first. $PWD is the last-resort
    # candidate, and this suite is usually run FROM the engine directory — which
    # is itself an adopted root. Left alone, every "not adopted anywhere" case
    # would quietly resolve the engine via $PWD and pass for the wrong reason.
    bash -c '
        set +u
        cd "$3" || exit 98
        . "$1" || exit 99
        resolve_entity_root "$2"; rc=$?
        printf "%s\t%s\t%s\t%s\n" "$rc" "$RICHOS_ENTITY_ROOT_RESOLVED" "$RICHOS_ROOT_STATUS" "$RICHOS_ROOT_SOURCE"
    ' _ "$lib" "$payload" "$SANDBOX"
}

f_rc()     { printf '%s' "$1" | cut -f1; }
f_root()   { printf '%s' "$1" | cut -f2; }
f_status() { printf '%s' "$1" | cut -f3; }
f_source() { printf '%s' "$1" | cut -f4; }

echo "=== resolve-roots: the root-resolution contract ==="
echo ""

# ===========================================================================
# THE HEADLINE CASE — engine in repo X, session in repo Y.
# This is the step-1 defect reproduced as a test: guard-definition-drift.sh
# wrote its state log into the repository that merely happened to CONTAIN the
# engine. The old resolution (SCRIPT_DIR/../.. and
# resolve_main_checkout SCRIPT_DIR) can only ever answer "the engine" or
# "the engine's enclosing repo". Both are wrong; only the session's repo is
# right, and the assertions below name all three so a regression cannot be
# read as a pass.
# ===========================================================================
HOSTREPO="$(make_repo hostrepo)"                       # NOT adopted; merely contains the engine
ENGINE="$(make_engine_in "$HOSTREPO" engine)"
git -C "$HOSTREPO" add -A >/dev/null 2>&1; git -C "$HOSTREPO" commit -q -m engine
SESSREPO="$(make_repo sessionrepo --adopted)"          # the repo the session is actually in
ELIB="$ENGINE/scripts/lib/resolve-roots.sh"

R="$(CLAUDE_PROJECT_DIR="$SESSREPO" CLAUDE_PLUGIN_ROOT="$ENGINE" probe "$ELIB" '{"cwd":"'"$SESSREPO"'"}')"
if [ "$(f_rc "$R")" = "0" ] && [ "$(f_root "$R")" = "$SESSREPO" ] && [ "$(f_status "$R")" = "governed" ]; then
    ok "1a POSITIVE  engine in X, session in Y -> resolves Y"
else
    bad "1a engine-in-X/session-in-Y (got $R, wanted rc=0 root=$SESSREPO governed)"
fi

# 1b NEGATIVE — the two pre-contract answers must NOT come back. Asserted
# explicitly rather than implied by 1a, because "not equal to Y" and "equal to
# the old wrong value" are different failures and only one of them is a
# regression to the exact defect this contract was written for.
if [ "$(f_root "$R")" != "$ENGINE" ] && [ "$(f_root "$R")" != "$HOSTREPO" ]; then
    ok "1b NEGATIVE  the resolved root is neither the engine dir nor its enclosing repo"
else
    bad "1b resolved the PRE-CONTRACT root (got $(f_root "$R"); engine=$ENGINE host=$HOSTREPO)"
fi

# 1c POSITIVE CONTROL for 1b — prove the assertion in 1b can fail. Simulate the
# old behavior by DECLARING the engine's enclosing repo as the root, and
# confirm the contract reports it BROKEN rather than either accepting it or
# quietly substituting the (perfectly valid) session repo that is also on the
# candidate list. An explicit declaration is exclusive: honour it or fail. If
# it fell through, this test would read as a pass while the resolver had
# silently governed a repository nobody named.
R2="$(RICHOS_ENTITY_ROOT="$HOSTREPO" CLAUDE_PROJECT_DIR="$SESSREPO" probe "$ELIB" '')"
if [ "$(f_rc "$R2")" = "2" ] && [ "$(f_status "$R2")" = "broken" ]; then
    ok "1c CONTROL   declaring the enclosing repo as the root is BROKEN, not accepted"
else
    bad "1c control (got $R2, wanted rc=2 broken)"
fi

# ===========================================================================
# 2. Candidate precedence.
# ===========================================================================
ALT="$(make_repo altrepo --adopted)"

R="$(RICHOS_ENTITY_ROOT="$ALT" CLAUDE_PROJECT_DIR="$SESSREPO" probe "$ELIB" '{"cwd":"'"$SESSREPO"'"}')"
if [ "$(f_root "$R")" = "$ALT" ] && [ "$(f_source "$R")" = "env-override" ]; then
    ok "2a POSITIVE  RICHOS_ENTITY_ROOT outranks CLAUDE_PROJECT_DIR"
else
    bad "2a env-override precedence (got $R)"
fi

R="$(CLAUDE_PROJECT_DIR="$SESSREPO" probe "$ELIB" '{"cwd":"'"$ALT"'"}')"
if [ "$(f_root "$R")" = "$SESSREPO" ] && [ "$(f_source "$R")" = "project-dir" ]; then
    ok "2b POSITIVE  CLAUDE_PROJECT_DIR outranks the payload cwd"
else
    bad "2b project-dir precedence (got $R)"
fi

# 2c — payload cwd is used when the host does not export the project dir. The
# subagent case depends on this, so it is not hypothetical.
R="$(env -u CLAUDE_PROJECT_DIR bash -c '
    set +u; cd "$3"; . "$1"
    resolve_entity_root "$2"; rc=$?
    printf "%s\t%s\t%s\t%s\n" "$rc" "$RICHOS_ENTITY_ROOT_RESOLVED" "$RICHOS_ROOT_STATUS" "$RICHOS_ROOT_SOURCE"
' _ "$ELIB" '{"cwd":"'"$ALT"'"}' "$SANDBOX")"
if [ "$(f_root "$R")" = "$ALT" ] && [ "$(f_source "$R")" = "payload-cwd" ]; then
    ok "2c POSITIVE  payload cwd is used when CLAUDE_PROJECT_DIR is absent"
else
    bad "2c payload-cwd fallback (got $R)"
fi

# 2d NEGATIVE — an adopted candidate that does not exist on disk is skipped,
# and the next one wins. Proves the marker check is a real stat, not a string
# comparison that would accept any plausible-looking path.
R="$(CLAUDE_PROJECT_DIR="$SANDBOX/does-not-exist" probe "$ELIB" '{"cwd":"'"$ALT"'"}')"
if [ "$(f_root "$R")" = "$ALT" ]; then
    ok "2d NEGATIVE  a nonexistent candidate is skipped, not accepted"
else
    bad "2d nonexistent candidate (got $R)"
fi

# ===========================================================================
# 3. Linked worktrees normalize to the MAIN checkout.
# A guard invoked from inside an agent worktree must still write state to, and
# read config from, the ONE shared checkout.
# ===========================================================================
WT="$SESSREPO/.claude/worktrees/agent-deadbeef"
git -C "$SESSREPO" worktree add -q -b wt-test "$WT" main >/dev/null 2>&1
R="$(CLAUDE_PROJECT_DIR="$WT" probe "$ELIB" '')"
if [ "$(f_root "$R")" = "$SESSREPO" ]; then
    ok "3a POSITIVE  a linked worktree normalizes to its main checkout"
else
    bad "3a worktree normalization (got $(f_root "$R"), wanted $SESSREPO)"
fi
# 3b NEGATIVE — and specifically NOT the worktree path itself, which is what a
# naive $PWD-based resolver would return.
if [ "$(f_root "$R")" != "$WT" ]; then
    ok "3b NEGATIVE  the worktree path itself is not returned"
else
    bad "3b returned the worktree path ($WT)"
fi

# ===========================================================================
# 3bis. NESTING. A candidate that is a SUBDIRECTORY of a repository stands for
# ITSELF; a candidate that is the TOP LEVEL of a working tree normalizes.
#
# Getting this backwards is not a theoretical risk — the first version of this
# resolver normalized unconditionally, which turned `<repo>/engine` into
# `<repo>`, threw the nesting away, and made every hook refuse to start with
# "no orchestration.config at its main checkout". The two shapes look identical
# ("a path inside a git repo") and behave oppositely, so both are pinned here.
# ===========================================================================
R="$(CLAUDE_PROJECT_DIR="$ENGINE" probe "$ELIB" '')"
if [ "$(f_root "$R")" = "$ENGINE" ]; then
    ok "3c POSITIVE  a nested adopted directory resolves to ITSELF, not its enclosing repo"
else
    bad "3c nested dir collapsed (got $(f_root "$R"), wanted $ENGINE)"
fi
# 3d NEGATIVE — specifically not the enclosing repo. Named, because that is the
# exact wrong answer, and "not equal to the engine" would also be satisfied by
# garbage.
if [ "$(f_root "$R")" != "$HOSTREPO" ]; then
    ok "3d NEGATIVE  the nested case does not collapse to the enclosing repo"
else
    bad "3d collapsed to the enclosing repo ($HOSTREPO)"
fi
# 3e — the other half: a SUBDIRECTORY of an adopted repo that carries no marker
# of its own resolves UP to the repo root. Without this, a session opened in a
# subdirectory would report not-adopted and stand down in a governed repo.
mkdir -p "$SESSREPO/src/deep/nested"
R="$(CLAUDE_PROJECT_DIR="$SESSREPO/src/deep/nested" probe "$ELIB" '')"
if [ "$(f_root "$R")" = "$SESSREPO" ]; then
    ok "3e POSITIVE  an unmarked subdirectory resolves UP to its adopted repo root"
else
    bad "3e subdir did not resolve up (got $(f_root "$R"))"
fi

# ===========================================================================
# 4. NOT-ADOPTED — the engine is loaded in a repository that never adopted it.
# Must stand down (rc 1), and must NOT be reported as governed. This is the
# case that keeps the machine usable: the plugin is enabled at USER scope, so
# it loads in every project on disk.
# ===========================================================================
PLAIN="$(make_repo plainrepo)"
R="$(CLAUDE_PROJECT_DIR="$PLAIN" CLAUDE_PLUGIN_ROOT="$ENGINE" probe "$ELIB" '{"cwd":"'"$PLAIN"'"}')"
if [ "$(f_rc "$R")" = "1" ] && [ "$(f_status "$R")" = "not-adopted" ] && [ -z "$(f_root "$R")" ]; then
    ok "4a POSITIVE  an unadopted repository yields not-adopted, with NO root"
else
    bad "4a not-adopted (got $R, wanted rc=1 not-adopted empty-root)"
fi
# 4b NEGATIVE — it must not silently fall back to the engine's own root, which
# is precisely how the old code ended up governing the wrong repository.
if [ "$(f_root "$R")" != "$ENGINE" ] && [ "$(f_status "$R")" != "governed" ]; then
    ok "4b NEGATIVE  not-adopted does not silently fall back to the engine root"
else
    bad "4b silent fallback to engine root (got $R)"
fi

# ===========================================================================
# 5. BROKEN — a declared root that is not an engine root.
# ===========================================================================
R="$(RICHOS_ENTITY_ROOT="$PLAIN" probe "$ELIB" '')"
if [ "$(f_rc "$R")" = "2" ] && [ "$(f_status "$R")" = "broken" ]; then
    ok "5a POSITIVE  a declared non-engine root is BROKEN"
else
    bad "5a broken declared root (got $R)"
fi
# 5b — and the banner is loud and greppable.
BANNER="$(RICHOS_ENTITY_ROOT="$PLAIN" bash -c '
    set +u; cd "$2"; . "$1"; resolve_entity_root ""; root_failure_banner "unit-test"
' _ "$ELIB" "$SANDBOX")"
if printf '%s' "$BANNER" | grep -q 'ROOT RESOLUTION FAILURE — ENFORCEMENT IS NOT ACTIVE' \
   && printf '%s' "$BANNER" | grep -q 'status : broken' \
   && printf '%s' "$BANNER" | grep -q 'candidates examined'; then
    ok "5b POSITIVE  the failure banner names the status and every candidate"
else
    bad "5b banner content: $BANNER"
fi
# 5c NEGATIVE — a governed resolution emits no banner text at all, so the
# banner cannot be mistaken for routine noise.
QUIET="$(CLAUDE_PROJECT_DIR="$SESSREPO" bash -c '
    set +u; cd "$2"; . "$1"; resolve_entity_root "" 2>/dev/null; printf "%s" "${RICHOS_ROOT_REASON:-}"
' _ "$ELIB" "$SANDBOX")"
if [ -z "$QUIET" ]; then
    ok "5c NEGATIVE  a governed resolution sets no failure reason"
else
    bad "5c governed run produced a reason: $QUIET"
fi

# ===========================================================================
# 6. ENGINE-SELF — a session opened at the repository that contains the engine.
# Legitimate (this is how the engine is developed) and reported under its own
# status, never laundered into `governed`.
# ===========================================================================
R="$(CLAUDE_PROJECT_DIR="$HOSTREPO" CLAUDE_PLUGIN_ROOT="$ENGINE" probe "$ELIB" '{"cwd":"'"$HOSTREPO"'"}')"
if [ "$(f_rc "$R")" = "0" ] && [ "$(f_status "$R")" = "engine-self" ] && [ "$(f_root "$R")" = "$ENGINE" ]; then
    ok "6a POSITIVE  session at the engine's enclosing repo -> engine-self"
else
    bad "6a engine-self (got $R, wanted rc=0 engine-self $ENGINE)"
fi
# 6b NEGATIVE — engine-self must NOT be reported as `governed`; the distinction
# is the whole point, because engine-self is the one status where the guards
# act on a root that is not the session's project dir.
if [ "$(f_status "$R")" != "governed" ]; then
    ok "6b NEGATIVE  engine-self is not laundered into 'governed'"
else
    bad "6b engine-self reported as governed"
fi
# 6c NEGATIVE — engine-self must NOT reach across to an unrelated repository.
# With the session in an unrelated unadopted repo, the engine sits OUTSIDE it,
# so the branch must not fire.
OUTSIDE="$(make_repo outsiderepo)"
R="$(CLAUDE_PROJECT_DIR="$OUTSIDE" CLAUDE_PLUGIN_ROOT="$ENGINE" probe "$ELIB" '{"cwd":"'"$OUTSIDE"'"}')"
if [ "$(f_status "$R")" = "not-adopted" ]; then
    ok "6c NEGATIVE  engine-self does not fire for an unrelated repository"
else
    bad "6c engine-self leaked to an unrelated repo (got $R)"
fi

# ===========================================================================
# 7. resolve_engine_root
# ===========================================================================
E="$(CLAUDE_PLUGIN_ROOT="$ENGINE" bash -c 'set +u; . "$1"; resolve_engine_root "$2"' _ "$ELIB" "$ENGINE/scripts/lib")"
if [ "$E" = "$ENGINE" ]; then
    ok "7a POSITIVE  CLAUDE_PLUGIN_ROOT is honoured when it carries scripts/hooks"
else
    bad "7a plugin-root honoured (got $E)"
fi
# 7b NEGATIVE — a CLAUDE_PLUGIN_ROOT belonging to some OTHER plugin (no
# scripts/hooks) is ignored, and the location-derived answer wins. Without this
# check a co-installed plugin's root could silently become "the engine".
mkdir -p "$SANDBOX/otherplugin"
E="$(CLAUDE_PLUGIN_ROOT="$SANDBOX/otherplugin" bash -c 'set +u; . "$1"; resolve_engine_root "$2"' _ "$ELIB" "$ENGINE/scripts/lib")"
if [ "$E" = "$ENGINE" ] && [ "$E" != "$SANDBOX/otherplugin" ]; then
    ok "7b NEGATIVE  a foreign plugin root is ignored"
else
    bad "7b foreign plugin root accepted (got $E)"
fi

# ===========================================================================
# 8. subagent_type namespacing.
# `richos-engine:clark` could never match `.claude/agents/richos-engine:clark.md`,
# so the model-truthfulness clause degraded to "undeterminable -> accept" and
# STOPPED GUARDING without saying so.
# ===========================================================================
NS="$(bash -c 'set +u; . "$1"; strip_agent_namespace "richos-engine:clark"' _ "$ELIB")"
NS2="$(bash -c 'set +u; . "$1"; strip_agent_namespace "clark"' _ "$ELIB")"
NS3="$(bash -c 'set +u; . "$1"; agent_namespace "richos-engine:clark"' _ "$ELIB")"
NS4="$(bash -c 'set +u; . "$1"; agent_namespace "clark"' _ "$ELIB")"
if [ "$NS" = "clark" ] && [ "$NS2" = "clark" ] && [ "$NS3" = "richos-engine" ] && [ -z "$NS4" ]; then
    ok "8a POSITIVE  namespace split: richos-engine:clark -> (richos-engine, clark)"
else
    bad "8a namespace split (got '$NS' '$NS2' '$NS3' '$NS4')"
fi

# 8b — the entity's own roster wins for a bare type.
mkdir -p "$SESSREPO/.claude/agents"
printf -- '---\nname: mark\nmodel: opus\n---\nbody\n' >"$SESSREPO/.claude/agents/mark.md"
D="$(bash -c 'set +u; . "$1"; resolve_agent_def "$2" "$3" "$4"' _ "$ELIB" "$SESSREPO" "$ENGINE" "mark")"
if [ "$D" = "$SESSREPO/.claude/agents/mark.md" ]; then
    ok "8b POSITIVE  a bare type resolves against the ENTITY roster"
else
    bad "8b entity roster lookup (got $D)"
fi

# 8c — a namespaced type resolves against the ENGINE's roster, and the
# namespace is matched against the plugin manifest's declared name, not guessed.
D="$(bash -c 'set +u; . "$1"; resolve_agent_def "$2" "$3" "$4"' _ "$ELIB" "$SESSREPO" "$ENGINE" "richos-engine:clark")"
if [ "$D" = "$ENGINE/.claude/agents/clark.md" ]; then
    ok "8c POSITIVE  a namespaced type resolves against the ENGINE roster"
else
    bad "8c engine roster lookup (got $D)"
fi

# 8d NEGATIVE — a namespaced type whose definition cannot be found ANYWHERE
# returns rc 2 (fail loud), NOT rc 1 (which callers treat as the benign
# built-in case). This is the exact distinction that was missing: "I looked and
# there is nothing to look at" vs "I could not look".
bash -c 'set +u; . "$1"; resolve_agent_def "$2" "$3" "no-such-plugin:ghost" >/dev/null' _ "$ELIB" "$SESSREPO" "$ENGINE"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "8d NEGATIVE  an unresolvable NAMESPACED type returns rc 2 (fail loud)"
else
    bad "8d unresolvable namespaced type returned rc=$rc, wanted 2"
fi

# 8e NEGATIVE — a bare unknown type still returns rc 1, because host built-ins
# (general-purpose, Explore, ...) legitimately have no definition file and must
# not be blocked. Proves 8d is a real discrimination and not a blanket rc 2.
bash -c 'set +u; . "$1"; resolve_agent_def "$2" "$3" "general-purpose" >/dev/null' _ "$ELIB" "$SESSREPO" "$ENGINE"
rc=$?
if [ "$rc" -eq 1 ]; then
    ok "8e NEGATIVE  a bare unknown type returns rc 1 (built-ins stay allowed)"
else
    bad "8e bare unknown type returned rc=$rc, wanted 1"
fi

# 8f — AGENT_NAMESPACE_ROOTS covers a third-party plugin supplying agent types.
OTHER="$SANDBOX/otherplug"
mkdir -p "$OTHER/.claude/agents"
printf -- '---\nname: ray\nmodel: sonnet\n---\nbody\n' >"$OTHER/.claude/agents/ray.md"
D="$(AGENT_NAMESPACE_ROOTS="fb-bridge=$OTHER" bash -c 'set +u; . "$1"; resolve_agent_def "$2" "$3" "fb-bridge:ray"' _ "$ELIB" "$SESSREPO" "$ENGINE")"
if [ "$D" = "$OTHER/.claude/agents/ray.md" ]; then
    ok "8f POSITIVE  AGENT_NAMESPACE_ROOTS resolves a third-party namespace"
else
    bad "8f AGENT_NAMESPACE_ROOTS (got $D)"
fi

# ===========================================================================
# 9. require_asset
# ===========================================================================
if bash -c 'set +u; . "$1"; require_asset "$1" "unit-test" "the library" >/dev/null' _ "$ELIB"; then
    ok "9a POSITIVE  require_asset accepts a present asset"
else
    bad "9a require_asset rejected a present asset"
fi
OUT="$(bash -c 'set +u; . "$1"; require_asset "/nope/missing.sh" "unit-test" "the reaper"' _ "$ELIB" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'ROOT RESOLUTION FAILURE' && printf '%s' "$OUT" | grep -q 'the reaper'; then
    ok "9b NEGATIVE  require_asset on a missing asset is loud and non-zero"
else
    bad "9b require_asset missing (rc=$rc out=$OUT)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== resolve-roots tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== resolve-roots tests: all $PASS passed ==="
    exit 0
fi
