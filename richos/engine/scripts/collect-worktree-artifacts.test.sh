#!/usr/bin/env bash
#
# collect-worktree-artifacts.test.sh — regression + mutation harness for the
# gitignored-evidence collector.
#
# THE BUG THIS PINS (2026-09-02). The collector resolved "the main checkout"
# as `$SCRIPT_DIR/..` — its OWN parent, which is the ENGINE once the engine is
# run by reference. Invoked for femcboost (whose orchestration.config declares
# nine directories) it loaded the ENGINE's config (three), was blind to both
# visual-screenshots trees and both per-tree playwright-report trees, and
# rsynced what it did find INTO THE ENGINE CHECKOUT. The one step whose job is
# saving QA evidence before a worktree is destroyed could not see most of it,
# and reported success.
#
# Every property here is proven LOAD-BEARING in the second half: the shipped
# script is mutated (one line each, applied by exact match so a drifted needle
# is a harness failure, not a silent pass), and the property that guards that
# line must go red against the mutant. A property no mutant can break is a
# property this harness is not really checking.
#
# HERMETIC BY CONSTRUCTION. Each case runs a BYTE-COPY of the shipped script
# from a fake engine directory under the sandbox, carrying a copy of scripts/lib
# and an orchestration.config shaped like the engine's own
# (engine/orchestration.config ARTIFACT_MERGE_DIRS="test-results output",
# ARTIFACT_REPLACE_DIRS="playwright-report"). A red run therefore reproduces
# the exact mis-resolution — and pollutes the sandbox, never the real engine.
# Ambient identity (RICHOS_ENTITY_ROOT, CLAUDE_PROJECT_DIR, RICHOS_ENGINE_ROOT,
# CLAUDE_PLUGIN_ROOT) is scrubbed on every invocation so the resolver sees
# only what the case declares.
#
# Discovered and run by scripts/run-all-tests.sh (every *.test.sh under the
# engine) and therefore by ci-verify.sh step 3. Not a *.mutation.sh: those are
# run by nothing (richos-hq/wiki/open-items.md rows 3.22-3.29).
#
# Run directly: scripts/collect-worktree-artifacts.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.
#
# SC2016 is disabled file-wide: the mutation needles are literal lines of the
# shipped script, quoted so that nothing in them expands here.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIPPED="$SCRIPT_DIR/collect-worktree-artifacts.sh"
LIB_DIR="$SCRIPT_DIR/lib"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t collect-artifacts-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$SHIPPED" ] || { echo "FATAL: collector missing: $SHIPPED" >&2; exit 1; }
[ -d "$LIB_DIR" ]  || { echo "FATAL: scripts/lib missing: $LIB_DIR" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "FATAL: rsync is required by the collector" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required to apply mutations" >&2; exit 1; }

# The directory lists, verbatim from the two real configs on 2026-09-02:
#   femcboost/orchestration.config:157-158   (nine directories)
#   engine/orchestration.config:191-192      (three)
FEMC_MERGE='test-results avelor/test-results fitapp/test-results avelor/visual-screenshots fitapp/visual-screenshots output'
FEMC_REPLACE='playwright-report avelor/playwright-report fitapp/playwright-report'
ENGINE_MERGE='test-results output'
ENGINE_REPLACE='playwright-report'
ALL_NINE="$FEMC_MERGE $FEMC_REPLACE"
NINE_DIRS_CONFIG="ARTIFACT_MERGE_DIRS=\"$FEMC_MERGE\"
ARTIFACT_REPLACE_DIRS=\"$FEMC_REPLACE\""

# A directory that is neither a git checkout nor an adopter, and NOT an
# ancestor of any fake engine — so a run from here has no candidate root and
# cannot fall into the resolver's engine-self branch.
NOWHERE="$SANDBOX/nowhere"
mkdir -p "$NOWHERE"

# make_engine <name> <collector-source-file>
# A fake engine: scripts/<copy of the collector>, scripts/lib/<copy>, and the
# engine-shaped orchestration.config that the OLD code would load by mistake.
make_engine() {
    local dir="$SANDBOX/$1" src="$2"
    mkdir -p "$dir/scripts"
    cp -R "$LIB_DIR" "$dir/scripts/lib"
    cp "$src" "$dir/scripts/collect-worktree-artifacts.sh"
    chmod +x "$dir/scripts/collect-worktree-artifacts.sh"
    printf 'ARTIFACT_MERGE_DIRS="%s"\nARTIFACT_REPLACE_DIRS="%s"\n' "$ENGINE_MERGE" "$ENGINE_REPLACE" >"$dir/orchestration.config"
    printf '%s\n' "$dir"
}

# make_entity <label> [config-body]
# A fresh repository (unique directory per call), adopted when a config body
# is given. No local identity override — the machine-wide identity guard
# needs the operator's real one.
make_entity() {
    local repo
    repo="$(mktemp -d "$SANDBOX/entity-$1.XXXXXX")"; shift || true
    git -C "$repo" init -q -b main
    printf 'seed\n' >"$repo/seed.txt"
    if [ "$#" -gt 0 ]; then printf '%s\n' "$1" >"$repo/orchestration.config"; fi
    git -C "$repo" add -A
    git -C "$repo" commit -q -m seed
    printf '%s\n' "$repo"
}

# make_worktree <entity> <id> — a linked worktree carrying evidence in ALL nine
# directories, one file each, named after its directory.
make_worktree() {
    local repo="$1" id="$2" wt d
    wt="$repo/.claude/worktrees/agent-$id"
    git -C "$repo" worktree add -q -b "wt-$id" "$wt" || { echo "FATAL: git worktree add failed for $wt" >&2; exit 1; }
    for d in $ALL_NINE; do
        mkdir -p "$wt/$d"
        printf 'evidence from %s\n' "$d" >"$wt/$d/evidence.txt"
    done
    printf '%s\n' "$wt"
}

# run_collector <engine-dir> <entity-root-or-''> <worktree> [cwd]
# Ambient identity scrubbed; the case declares the root or declares nothing.
# Captures stdout+stderr in OUT and the exit code in RC.
OUT=""; RC=0
run_collector() {
    local eng="$1" root="$2" wt="$3" cwd="${4:-$NOWHERE}"
    if [ -n "$root" ]; then
        OUT="$(cd "$cwd" && env -u RICHOS_ENTITY_ROOT -u CLAUDE_PROJECT_DIR -u RICHOS_ENGINE_ROOT -u CLAUDE_PLUGIN_ROOT \
                 RICHOS_ENTITY_ROOT="$root" bash "$eng/scripts/collect-worktree-artifacts.sh" "$wt" 2>&1)"; RC=$?
    else
        OUT="$(cd "$cwd" && env -u RICHOS_ENTITY_ROOT -u CLAUDE_PROJECT_DIR -u RICHOS_ENGINE_ROOT -u CLAUDE_PLUGIN_ROOT \
                 bash "$eng/scripts/collect-worktree-artifacts.sh" "$wt" 2>&1)"; RC=$?
    fi
}

# count_collected <root> — how many of the nine directories carry the evidence
# file AND the provenance stamp under <root>.
count_collected() {
    local root="$1" d n=0
    for d in $ALL_NINE; do
        [ -f "$root/$d/evidence.txt" ] && [ -f "$root/$d/SOURCE.txt" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
}

# engine_polluted <engine-dir> — did anything get rsynced INTO the engine?
engine_polluted() {
    local eng="$1" d
    for d in $ALL_NINE; do
        [ -e "$eng/$d" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# PROPERTIES. Each takes an engine dir, builds its own fixtures, and returns
# 0 (holds) or 1 (violated), leaving a one-line reason in WHY.
# ---------------------------------------------------------------------------
WHY=""

# P1. THE BUG. Invoked for an entity declaring nine directories, all nine are
#     collected into THAT entity, and nothing lands in the engine.
prop_honors_entity_root() {
    local eng="$1" E WT n
    E="$(make_entity femc "$NINE_DIRS_CONFIG")"
    WT="$(make_worktree "$E" p1)"
    run_collector "$eng" "$E" "$WT"
    n="$(count_collected "$E")"
    if [ "$RC" -ne 0 ]; then WHY="rc=$RC: $OUT"; return 1; fi
    if [ "$n" -ne 9 ]; then WHY="collected $n of 9 into the entity: $OUT"; return 1; fi
    if engine_polluted "$eng"; then WHY="evidence was rsynced into the ENGINE directory"; return 1; fi
    if ! grep -q "source_sha:      $(git -C "$WT" rev-parse HEAD)" "$E/avelor/visual-screenshots/SOURCE.txt"; then
        WHY="SOURCE.txt does not carry the worktree's SHA"; return 1
    fi
    return 0
}

# P2. REFUSAL, both shapes. (a) A declared root that is not an adopter:
#     refuse with the root contract's banner. (b) No declared root and no
#     candidate: refuse the same way. In neither case is anything written
#     anywhere — not into the named directory, not into the engine.
prop_refuses_unresolvable() {
    local eng="$1" E WT NOPE
    E="$(make_entity femc "$NINE_DIRS_CONFIG")"
    WT="$(make_worktree "$E" p2)"
    NOPE="$(mktemp -d "$SANDBOX/unadopted.XXXXXX")"

    run_collector "$eng" "$NOPE" "$WT"
    if [ "$RC" -ne 2 ]; then WHY="(a) declared-but-unadopted root: rc=$RC, want 2: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'ROOT RESOLUTION FAILURE'; then WHY="(a) no root-contract banner: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'status : broken'; then WHY="(a) banner does not say broken: $OUT"; return 1; fi
    if [ "$(count_collected "$NOPE")" -ne 0 ] || engine_polluted "$eng"; then WHY="(a) refused yet wrote evidence somewhere"; return 1; fi

    run_collector "$eng" "" "$WT"
    if [ "$RC" -ne 2 ]; then WHY="(b) no root anywhere: rc=$RC, want 2: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'ROOT RESOLUTION FAILURE'; then WHY="(b) no root-contract banner: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'status : not-adopted'; then WHY="(b) banner does not say not-adopted: $OUT"; return 1; fi
    if engine_polluted "$eng"; then WHY="(b) refused yet wrote evidence into the engine"; return 1; fi
    return 0
}

# P3. OBSERVABLE. The run states which config it loaded and every directory
#     it will collect, with counts — so a wrong resolution is visible in the
#     output rather than inferable from what is missing.
prop_states_config_and_dirs() {
    local eng="$1" E WT d
    E="$(make_entity femc "$NINE_DIRS_CONFIG")"
    WT="$(make_worktree "$E" p3)"
    run_collector "$eng" "$E" "$WT"
    if [ "$RC" -ne 0 ]; then WHY="rc=$RC: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -qF "config      : $E/orchestration.config"; then WHY="does not state the config file it loaded: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -qF "entity root : $E"; then WHY="does not state the entity root: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'merge dirs   (6):'; then WHY="does not state the merge list with its count: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'replace dirs (3):'; then WHY="does not state the replace list with its count: $OUT"; return 1; fi
    for d in $ALL_NINE; do
        if ! printf '%s' "$OUT" | grep -q "dirs.*[ :]$d\( \|$\)"; then WHY="directory '$d' is not named in the announced list: $OUT"; return 1; fi
    done
    return 0
}

# P4. NO SILENT DEFAULT. A config that declares neither key is refused — the
#     collector carries no built-in list. A config that declares EMPTY lists
#     is honored (collects nothing, says so, exit 0). And the list is read
#     from the FILE: a value inherited from the environment cannot stand in
#     for a declaration the file does not make.
prop_refuses_undeclared_list() {
    local eng="$1" E WT
    E="$(make_entity nolist 'PROTECTED_PATHS="src"')"
    WT="$(make_worktree "$E" p4)"
    run_collector "$eng" "$E" "$WT"
    if [ "$RC" -ne 2 ]; then WHY="undeclared list: rc=$RC, want 2: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'declares neither ARTIFACT_MERGE_DIRS nor'; then WHY="undeclared list: refusal does not name the missing keys: $OUT"; return 1; fi
    if [ "$(count_collected "$E")" -ne 0 ]; then WHY="undeclared list: refused yet collected"; return 1; fi

    OUT="$(cd "$NOWHERE" && env -u RICHOS_ENTITY_ROOT -u CLAUDE_PROJECT_DIR -u RICHOS_ENGINE_ROOT -u CLAUDE_PLUGIN_ROOT \
             RICHOS_ENTITY_ROOT="$E" ARTIFACT_MERGE_DIRS="test-results" ARTIFACT_REPLACE_DIRS="playwright-report" \
             bash "$eng/scripts/collect-worktree-artifacts.sh" "$WT" 2>&1)"; RC=$?
    if [ "$RC" -ne 2 ] || [ "$(count_collected "$E")" -ne 0 ]; then WHY="an environment value stood in for the file's declaration (rc=$RC): $OUT"; return 1; fi

    E="$(make_entity empty 'ARTIFACT_MERGE_DIRS=""
ARTIFACT_REPLACE_DIRS=""')"
    WT="$(make_worktree "$E" p4e)"
    run_collector "$eng" "$E" "$WT"
    if [ "$RC" -ne 0 ]; then WHY="declared-empty list: rc=$RC, want 0: $OUT"; return 1; fi
    if [ "$(count_collected "$E")" -ne 0 ]; then WHY="declared-empty list collected something"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'nothing to collect'; then WHY="declared-empty list: does not say nothing to collect: $OUT"; return 1; fi
    return 0
}

# P5. Existing refusals survive: a missing worktree path, and the entity
#     collecting from itself into itself, are exit 1 and collect nothing.
prop_existing_refusals() {
    local eng="$1" E
    E="$(make_entity femc "$NINE_DIRS_CONFIG")"
    run_collector "$eng" "$E" "$E/.claude/worktrees/agent-missing"
    if [ "$RC" -ne 1 ]; then WHY="missing worktree path: rc=$RC, want 1: $OUT"; return 1; fi
    mkdir -p "$E/test-results"; printf 'self\n' >"$E/test-results/self.txt"
    run_collector "$eng" "$E" "$E"
    if [ "$RC" -ne 1 ]; then WHY="self-collection: rc=$RC, want 1: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'refusing to collect from the main checkout into itself'; then WHY="self-collection: wrong reason: $OUT"; return 1; fi
    return 0
}

# P6. A root that resolves but carries no orchestration.config is refused.
#     Reachable because the resolver's adoption marker is configurable
#     (RICHOS_ADOPTION_MARKER): mark the root with a different file, and the
#     config is absent while the root still resolves.
prop_refuses_missing_config() {
    local eng="$1" E WT
    E="$(make_entity marker)"; touch "$E/.adopted"
    WT="$(make_worktree "$E" p6)"
    OUT="$(cd "$NOWHERE" && env -u CLAUDE_PROJECT_DIR -u RICHOS_ENGINE_ROOT -u CLAUDE_PLUGIN_ROOT \
             RICHOS_ADOPTION_MARKER=.adopted RICHOS_ENTITY_ROOT="$E" \
             bash "$eng/scripts/collect-worktree-artifacts.sh" "$WT" 2>&1)"; RC=$?
    if [ "$RC" -ne 2 ]; then WHY="rc=$RC, want 2: $OUT"; return 1; fi
    if ! printf '%s' "$OUT" | grep -q 'orchestration.config'; then WHY="refusal does not name the missing config: $OUT"; return 1; fi
    if [ "$(count_collected "$E")" -ne 0 ] || engine_polluted "$eng"; then WHY="refused yet wrote evidence somewhere"; return 1; fi
    return 0
}

# ---------------------------------------------------------------------------
# 1. The shipped script holds every property.
# ---------------------------------------------------------------------------
echo "=== collect-worktree-artifacts tests ==="
ENG="$(make_engine engine-shipped "$SHIPPED")"

if prop_honors_entity_root "$ENG"; then ok "P1 invoked for an entity declaring nine directories, collects all nine into that entity and nothing into the engine"
else bad "P1 honors entity root — $WHY"; fi
if prop_refuses_unresolvable "$ENG"; then ok "P2 refuses (exit 2, root-contract banner) on a declared-but-unadopted root AND on no root at all; writes nothing"
else bad "P2 refuses unresolvable root — $WHY"; fi
if prop_states_config_and_dirs "$ENG"; then ok "P3 states the entity root, the config file loaded, and every directory with counts"
else bad "P3 states config and dirs — $WHY"; fi
if prop_refuses_undeclared_list "$ENG"; then ok "P4 refuses a config declaring no list; honors a declared-empty list; ignores an inherited environment value"
else bad "P4 no silent default — $WHY"; fi
if prop_existing_refusals "$ENG"; then ok "P5 missing worktree path and self-collection still refuse (exit 1)"
else bad "P5 existing refusals — $WHY"; fi
if prop_refuses_missing_config "$ENG"; then ok "P6 a resolved root with no orchestration.config is refused (exit 2), nothing written"
else bad "P6 refuses missing config — $WHY"; fi

# ---------------------------------------------------------------------------
# 2. MUTATIONS. Each breaks one line of the shipped script by EXACT match
#    (occurring exactly once — a drifted needle fails here, loudly) and the
#    property guarding that line must go red.
# ---------------------------------------------------------------------------
# mutate <name> <old> <new> — sets MUTANT to the mutant engine dir; records a
# failure and returns 1 if the needle is not found exactly once.
MUTANT=""
mutate() {
    local name="$1" old="$2" new="$3" src
    src="$SANDBOX/mutant-$name.sh"
    MUTANT=""
    if ! python3 - "$SHIPPED" "$src" "$old" "$new" <<'PY'
import sys
shipped, out, old, new = sys.argv[1:5]
text = open(shipped).read()
n = text.count(old)
if n != 1:
    sys.stderr.write("needle occurs %d times, want exactly 1: %r\n" % (n, old))
    sys.exit(1)
open(out, "w").write(text.replace(old, new))
PY
    then
        bad "mutation '$name' did not apply — its needle drifted; the harness is proving nothing about that line"
        return 1
    fi
    MUTANT="$(make_engine "engine-mutant-$name" "$src")"
}

expect_red() { # <property-fn> <engine-dir> <label>
    local fn="$1" eng="$2" label="$3"
    if "$fn" "$eng" 2>/dev/null; then
        bad "$label — the mutant PASSED; this property is not load-bearing"
    else
        ok "$label — went red on the mutant"
    fi
}

echo "--- mutations ---"

# The needles below are LITERAL lines of the shipped script; single quotes are
# deliberate so nothing in them expands here (SC2016 is disabled file-wide in
# the header for exactly this).

# M1: resolve the root from the script's own location again (the shipped bug).
if mutate root-from-script-dir \
        'MAIN_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"' \
        'MAIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"'; then
    expect_red prop_honors_entity_root "$MUTANT" "M1 root taken from SCRIPT_DIR/.. -> P1"
    expect_red prop_states_config_and_dirs "$MUTANT" "M1 root taken from SCRIPT_DIR/.. -> P3"
fi

# M2: on an unresolvable root, fall back to the script's own parent instead
#     of refusing.
if mutate fallback-on-unresolvable \
        'exit 2  # refuse: no governed entity' \
        'MAIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"; RICHOS_ROOT_STATUS=fallback; RICHOS_ROOT_SOURCE=script-dir'; then
    expect_red prop_refuses_unresolvable "$MUTANT" "M2 fallback instead of refusal -> P2"
fi

# M3: bring back the built-in default list when the config declares none.
if mutate builtin-default-list \
        'exit 2  # refuse: no declared list' \
        'ARTIFACT_MERGE_DIRS="test-results output"; ARTIFACT_REPLACE_DIRS="playwright-report"'; then
    expect_red prop_refuses_undeclared_list "$MUTANT" "M3 silent built-in default list -> P4"
fi

# M4: stop scrubbing inherited values before sourcing the config.
if mutate inherit-env-list \
        'unset ARTIFACT_MERGE_DIRS ARTIFACT_REPLACE_DIRS' \
        ':'; then
    expect_red prop_refuses_undeclared_list "$MUTANT" "M4 environment value accepted as a declaration -> P4"
fi

# M5: drop the line that names the config file.
if mutate silent-config-path \
        'echo "[collect] config      : $CONFIG"' \
        ':'; then
    expect_red prop_states_config_and_dirs "$MUTANT" "M5 config path not stated -> P3"
fi

# M6: drop the line that lists the directories.
if mutate silent-dir-list \
        'echo "[collect] merge dirs   ($N_MERGE): ${ARTIFACT_MERGE_DIRS:-<none>}"' \
        ':'; then
    expect_red prop_states_config_and_dirs "$MUTANT" "M6 directory list not stated -> P3"
fi

# M7: the missing-config refusal becomes a skip that fabricates a config
#     carrying the old built-in list.
if mutate skip-missing-config \
        'exit 2  # refuse: config missing' \
        'CONFIG="$(mktemp)"; printf '"'"'ARTIFACT_MERGE_DIRS="test-results output"\nARTIFACT_REPLACE_DIRS="playwright-report"\n'"'"' >"$CONFIG"'; then
    expect_red prop_refuses_missing_config "$MUTANT" "M7 missing-config refusal turned into a skip -> P6"
fi

echo ""
echo "collect-worktree-artifacts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
