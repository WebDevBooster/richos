#!/bin/bash
#
# ============================================================================
# REFERENCE EXAMPLE — advanced "identity-or-refuse" tier. NOT wired into the
# engine's mechanical layer. This script came from a real Convex + native-mobile
# project; product identifiers were genericized to placeholders (example /
# legacyapp) and any test credential replaced with <TEST_PASSWORD>. It is
# illustrative, not runnable as-is — adapt it to your own deploy/device
# pipeline. See reference/advanced-tier/README.md.
# ============================================================================
#
#
# scripts/client-data-check.sh — universal client-data-render verifier.
#
# The consumer half of the Client Data-Render Contract
# (docs/client-data-contract.md). Every freshly installed Example client app
# (Android / iOS) must render Marcus's canonical seeded values on Home
# byte-for-byte. This script asks the installed client "what did you just
# render?" via a platform adapter, and compares every field against the
# canonical SSOT (scripts/client-data/canonical-values.sh) plus the live
# server state for DERIVED fields.
#
# Usage:
#   scripts/client-data-check.sh <platform> [expected-sha] [--screen <name>]
#
# Arguments:
#   platform       android | ios
#   expected-sha   12-char commit hash. Defaults to main tip. Forwarded to
#                  the adapter for its own sanity check; this verifier only
#                  uses it to key a deterministic output header.
#   --screen       Which rendered surface to verify. Valid: home (default),
#                  food-log, pantry, messages. Dispatches to
#                  scripts/client-data/<platform>-<screen>-state-adapter.sh.
#                  Each screen declares its own canonical-keys set + per-
#                  field comparisons inline below — add a new screen by
#                  extending the VALID_SCREENS list, the dispatcher adapter
#                  lookup, and the `run_checks_for_*` function.
#
# Environment:
#   CLIENT_DATA_CONTRACT_ENFORCE
#     When "1", exit-3 (adapter-missing) is promoted to exit-2 (hard fail).
#     Install-fresh flips this on after both adapters land. Default is off
#     so the verifier grades gracefully during rollout.
#
# Exit codes:
#   0  every canonical field rendered matches
#   1  script error / usage error
#   2  one or more canonical fields MISMATCH — contract VIOLATED
#   3  platform adapter missing or refused to run — contract NOT VERIFIED
#      (treated as warning by install-fresh during rollout, hard fail once
#      CLIENT_DATA_CONTRACT_ENFORCE=1)
#
# Output:
#   One line per canonical field:
#     ✓ <field>: <observed> (matches canonical <expected>)
#     ✗ <field>: FAIL — expected <expected>, got <observed>
#     ⊘ <field>: SKIPPED — <reason>
#
# Adapter contract (docs/client-data-contract.md §5):
#   scripts/client-data/<platform>-home-state-adapter.sh <sha>
#     - Reads the installed app's Home view state (however the platform
#       exposes it — ADB dump for Android, simctl URL scheme for iOS, etc.)
#     - Outputs a single JSON object on STDOUT with the v1 Home-surface
#       canonical keys listed below (12 numeric/categorical + cachePrimed
#       gate). Extra keys are allowed and ignored.
#     - Exits 0 on successful dump; non-zero on any error.
#
# v1 Home-surface keys (the intersection of what Android + iOS render on
# Home today — this is the adapter-check surface, NOT the full canonical
# SSOT. Server-side-only canonical values — email, displayName, etc. —
# live in canonical-values.sh and are verified by seedE2E:verify):
#
#     steps, activeKcal,
#     stepGoal, caloriesTarget, proteinTargetG,
#     xpLevel, xpProgressPercent,
#     foodLogCount, dayNumber
#
# v5.3.4 (backend Layer-3 remediation): `xpTotal` and `xpToNextLevel` are
# hidden from clients by `xp:getUserXP` when xpInvisibleToClients is
# true (default for every tenant today), so the adapter receives null
# for both and the Home tile renders percent+level only. The client
# surface therefore cannot meaningfully assert those two fields — they
# moved to SERVER_MARCUS_* in canonical-values.sh and are now checked
# exclusively by seedE2E:verify (admin context, sees the raw userXP
# row). xpLevel and xpProgressPercent remain on the client surface.
#
# v5 HIGH-4: weightKg removed from the v1 surface. It returns when
# Home actually renders weight (today both adapters emit `null`).
#
# Plus the boolean gate:
#
#     cachePrimed — if false, the client hasn't populated Home from the
#                   canonical cache yet; verifier fails with exit 2 even
#                   if every other key happens to match.
#
# Missing keys from this list are SKIPPED (⊘) with a loud warning; on the
# v1 surface, EVERY key is expected, so a skipped key is a real signal that
# the adapter is incomplete. Extra keys outside this set (feastDay*,
# activeChallenge*, plateauDaysRemaining, proteinG, caloriesConsumed,
# foodStreak, availableFreezes, schemaVersion, etc.) are valid and ignored.

set -uo pipefail

# Fail-closed, not fail-open: this "identity-or-refuse" verifier depends on
# python3 to parse each platform adapter's stdout and to write the signed
# seal. The adapter-output parse (`python3 - ... 2>/dev/null <<PY || true`) is
# explicitly fail-open-shaped; if python3 is absent it would silently degrade
# instead of blocking a check that is supposed to catch wrong-rendered-data
# (the whole reason this script exists — see the 2026-04-22 canonical
# regression this contract was built to prevent). Refuse outright instead.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: client-data-check.sh: python3 is required for adapter-output parsing + seal writing — refusing (fail-closed)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANONICAL="$SCRIPT_DIR/client-data/canonical-values.sh"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

usage() {
    sed -n '3,45p' "$0"
}

PLATFORM=""
EXPECTED_SHA=""
SCREEN="home"

while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    --screen)
        if [ -z "${2:-}" ]; then
            echo "ERROR: --screen requires an argument" >&2
            exit 1
        fi
        SCREEN="$2"
        shift 2
        ;;
    --*)
        echo "ERROR: unknown flag: $1" >&2
        exit 1
        ;;
    *)
        if [ -z "$PLATFORM" ]; then
            PLATFORM="$1"
        elif [ -z "$EXPECTED_SHA" ]; then
            EXPECTED_SHA="$1"
        else
            echo "ERROR: unexpected positional arg: $1" >&2
            exit 1
        fi
        shift
        ;;
    esac
done

if [ -z "$PLATFORM" ]; then
    echo "ERROR: platform argument required (android | ios)" >&2
    usage
    exit 1
fi

case "$PLATFORM" in
android | ios) ;;
*)
    echo "ERROR: platform must be android or ios (got: $PLATFORM)" >&2
    exit 1
    ;;
esac

# Screens are an explicit allowlist so typos fail loudly. Extend this list
# when adding a new screen dispatcher — and also extend the canonical-keys
# set + run_checks_for_<screen> function below.
case "$SCREEN" in
home | food-log | pantry | messages | steps | trophies | leaderboard | check-in | challenges | healthsync | profile) ;;
*)
    echo "ERROR: --screen must be 'home', 'food-log', 'pantry', 'messages', 'steps', 'trophies', 'leaderboard', 'check-in', 'challenges', 'healthsync', or 'profile' (got: $SCREEN)" >&2
    exit 1
    ;;
esac

if [ -z "$EXPECTED_SHA" ]; then
    EXPECTED_SHA="$(cd "$REPO_ROOT" && git rev-parse --short=12 main 2>/dev/null || true)"
fi
EXPECTED_SHA="$(printf '%s' "$EXPECTED_SHA" | tr 'A-Z' 'a-z' | cut -c1-12)"

# ---------------------------------------------------------------------------
# Source canonical SSOT
# ---------------------------------------------------------------------------

if [ ! -f "$CANONICAL" ]; then
    echo "ERROR: canonical values file missing: $CANONICAL" >&2
    exit 1
fi
# shellcheck source=scripts/client-data/canonical-values.sh
. "$CANONICAL"

# ---------------------------------------------------------------------------
# Output helpers (match freshness-check.sh aesthetics)
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_DIM=""
    C_RESET=""
fi

FAILURES=0
SKIPS=0
PASSES=0

pass_field() {
    local field="$1" observed="$2" expected="$3"
    printf "  %s✓%s %s: %s %s(matches canonical %s)%s\n" \
        "$C_GREEN" "$C_RESET" "$field" "$observed" "$C_DIM" "$expected" "$C_RESET"
    PASSES=$((PASSES + 1))
}

fail_field() {
    local field="$1" observed="$2" expected="$3"
    printf "  %s✗%s %s: FAIL — expected %s, got %s\n" \
        "$C_RED" "$C_RESET" "$field" "$expected" "$observed"
    FAILURES=$((FAILURES + 1))
}

skip_field() {
    local field="$1" reason="$2"
    printf "  %s⊘%s %s: SKIPPED — %s\n" \
        "$C_YELLOW" "$C_RESET" "$field" "$reason"
    SKIPS=$((SKIPS + 1))
}

# ---------------------------------------------------------------------------
# Invoke platform adapter
# ---------------------------------------------------------------------------

ADAPTER="$SCRIPT_DIR/client-data/${PLATFORM}-${SCREEN}-state-adapter.sh"

echo "Client data check: platform=$PLATFORM screen=$SCREEN expected-sha=${EXPECTED_SHA:-<unset>}"
echo ""

if [ ! -x "$ADAPTER" ]; then
    printf "  %s⊘%s adapter: SKIPPED — %s not present yet (rollout phase)\n" \
        "$C_YELLOW" "$C_RESET" "$ADAPTER"
    echo ""
    echo "Summary: 0 pass, 0 fail, 1 skipped (adapter missing)"
    if [ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" = "1" ]; then
        echo ""
        echo "CLIENT_DATA_CONTRACT_ENFORCE=1 but adapter missing — treating as HARD FAIL." >&2
        exit 2
    fi
    exit 3
fi

echo "${C_DIM}→ $ADAPTER ${EXPECTED_SHA}${C_RESET}"

ADAPTER_STDOUT="$(mktemp -t client-data-adapter.XXXXXX)"
ADAPTER_STDERR="$(mktemp -t client-data-adapter-err.XXXXXX)"
trap 'rm -f "$ADAPTER_STDOUT" "$ADAPTER_STDERR"' EXIT

if ! "$ADAPTER" "${EXPECTED_SHA}" >"$ADAPTER_STDOUT" 2>"$ADAPTER_STDERR"; then
    ADAPTER_EXIT=$?
    printf "  %s✗%s adapter: FAIL — exited %d\n" "$C_RED" "$C_RESET" "${ADAPTER_EXIT:-1}"
    printf "%s\n" "${C_DIM}adapter stderr (last 20 lines):${C_RESET}"
    tail -20 "$ADAPTER_STDERR" | sed 's/^/    /'
    echo ""
    echo "Summary: 0 pass, 1 fail, 0 skipped"
    exit 2
fi

if [ ! -s "$ADAPTER_STDOUT" ]; then
    printf "  %s✗%s adapter: FAIL — empty stdout (no JSON dump)\n" "$C_RED" "$C_RESET"
    echo ""
    echo "Summary: 0 pass, 1 fail, 0 skipped"
    exit 2
fi

# ---------------------------------------------------------------------------
# Parse JSON and compare
# ---------------------------------------------------------------------------

# Use python3 (always available on macOS + Linux CI) to extract each key;
# emit a TSV line `<key>\t<value-or-empty>` that bash can read without
# caring about JSON escaping.

# Per-screen canonical-keys set. Each screen declares the EXACT set of
# adapter-output keys the verifier reads (plus the cachePrimed gate).
# Keys absent from the adapter's JSON are ⊘ SKIPPED; unknown-key
# regressions therefore surface loudly.
#
# Server-side-only canonical fields (clientEmail, displayName, firstName,
# totalKcal, restingHeartRate, peerCount) live in canonical-values.sh and
# are verified by seedE2E:verify — NOT by adapter-based checks. See
# docs/client-data-contract.md §5.
#
# v5 HIGH-4 (Frank F-3): `weightKg` is dropped from the Home v1 surface.
# Both home adapters emit `weightKg: null` because Home does not render
# weight today; promoting null to hard-fail under ENFORCE=1 made the
# contract's stated closure unreachable. weightKg returns to the surface
# when Home actually renders weight; until then it lives in
# canonical-values.sh as a server-only field exercised by seedE2E:verify.
case "$SCREEN" in
home)
    KEYS="steps activeKcal stepGoal caloriesTarget proteinTargetG xpLevel xpProgressPercent foodLogCount dayNumber cachePrimed"
    ;;
food-log)
    # FoodLogStateSnapshot shape (see FoodLogStateSnapshot.swift): today's
    # count + macro totals + meal-section coverage + cachePrimed gate.
    # mealsPresent is a comma-delimited string; every other key is int.
    KEYS="todayLogCount caloriesTotal proteinG carbsG fatG mealsPresent cachePrimed"
    ;;
pantry)
    # PantryStateSnapshot shape (see PantryStateSnapshot.swift): total
    # entry count + breakdown by tenant vs personal scope + snapshot date
    # + cachePrimed gate + schemaVersion. Canonical values are all 0
    # today because seedE2E does not yet populate pantryFoods for Marcus;
    # contract will gain real non-zero expectations when the backend extends
    # the seed. `date` is NOT checked (wall-clock dependent, not
    # canonical); `schemaVersion` is compared for drift detection.
    KEYS="itemsTotal tenantFoodCount personalFoodCount date cachePrimed schemaVersion"
    ;;
messages)
    # MessagesStateSnapshot schema v2 (bumped 2026-04-24 by the
    # bubble-alignment fix). Thread identity + unread counter +
    # last-message presence + bucketed message counts + server
    # currentUserId + cachePrimed + schemaVersion.
    #
    # seedE2E pins exactly one conversation with 12 natural coach↔client
    # messages, all read, ordered over the last 72h (seedE2E.ts
    # cleanAllTestMessages). Post HC-seed,
    # `completeCoachChallenge` may insert a type:"system" 🏆 row once
    # Marcus crosses the 70k step threshold — that row inflates
    # `messageCount` to 13 but NOT `userMessageCount` (which filters
    # system rows). The adapter also emits `selfMessageCount` for the
    # bubble-alignment regression guard and `serverCurrentUserId` for
    # diagnostic parity with Android's ThreadViewModel.kt:191.
    KEYS="conversationCount coachName clientName unreadCount lastMessagePresent messageCount userMessageCount systemMessageCount selfMessageCount serverCurrentUserId cachePrimed schemaVersion"
    ;;
steps)
    # StepsStateSnapshot shape (see StepsStateSnapshot.swift): today's
    # hero values (step count + active kcal + step goal) + recent-days
    # history depth + cachePrimed gate + schemaVersion. Hero values
    # re-use the Sprint 1 Home anchors (CANONICAL_TODAY_STEP_COUNT,
    # CANONICAL_TODAY_ACTIVE_KCAL, CANONICAL_STEP_GOAL); recentDaysCount
    # is checked as a MIN per the seed-flex note at canonical-values.sh:267
    # (Marcus's profile createdAt anchor pins at LEAST 14 rows).
    KEYS="todayStepCount todayActiveKcal stepGoal recentDaysCount cachePrimed schemaVersion"
    ;;
trophies)
    # TrophiesStateSnapshot shape (see TrophiesStateSnapshot.swift:55-72):
    # 6 numeric fields covering the SummaryStrip (totalEarned/thisMonth/
    # gold), the InProgressCarousel (inProgressCount), the Mystery row
    # (mysterySlotCount), and the catalog gate (trophyCount) + the
    # cachePrimed primer + schemaVersion. Every numeric is checked as a
    # MIN, not EXACT — trophy earned-counts depend on runtime-variable
    # cron timing across the 16 source tables fanned out by
    # `gamification/trophies.ts:99-116`. See canonical-values.sh:317-348
    # for the doctrine.
    KEYS="trophyCount mysterySlotCount totalEarned thisMonth gold inProgressCount cachePrimed schemaVersion"
    ;;
leaderboard)
    # LeaderboardStateSnapshot shape (see LeaderboardStateSnapshot.swift:49-65).
    # Sprint 7 pins the weekly_logging category (snapshotCategory at
    # DebugLeaderboardStateURLHandler.swift:39). Adapter emits peerCount /
    # mySelfRowPresent / myRank / period / cachePrimed / schemaVersion=1.
    # Verifier reads peerCount + mySelfRowPresent + cachePrimed +
    # schemaVersion; myRank is intentionally NOT pinned (seedLeaderboardPeers
    # does not pin Marcus's exact rank position — see snapshot doc :35-36),
    # period is wall-clock-dependent ISO week format (NOT canonical-pinned).
    # Both keys are still listed so the parser can read them — the per-
    # screen comparison branch below simply doesn't reference them.
    KEYS="peerCount mySelfRowPresent myRank period cachePrimed schemaVersion"
    ;;
check-in)
    # CheckInStateSnapshot shape (see CheckInStateSnapshot.swift:50-71).
    # Adapter emits currentWeekSubmitted / historyCount / weekStart /
    # cachePrimed / schemaVersion=1. Verifier compares
    # currentWeekSubmitted + historyCount + cachePrimed + schemaVersion;
    # weekStart is intentionally NOT pinned (snapshot doc :58-60 —
    # today's UTC ISO-Monday is wall-clock-dependent and self-identifying
    # for cross-screen consistency, not for compare). The seed canonical
    # is the degenerate-zero baseline today (seedE2E.ts does NOT seed
    # any checkIns rows); see canonical-values.sh:218-239 for the
    # tenant-scoping-correctness rationale. weekStart is still listed
    # in KEYS for parser ingestion (matches pantry's `date` pattern).
    KEYS="currentWeekSubmitted historyCount weekStart cachePrimed schemaVersion"
    ;;
challenges)
    # ChallengesStateSnapshot shape (see ChallengesStateSnapshot.swift:43-127).
    # Adapter emits totalCount / activeCoachSurgePresent / myRow{...} /
    # cachePrimed / schemaVersion=1. The `myRow` field is a NESTED JSON
    # object — Sprint 9 introduced dotted-path key extraction to the
    # parser (see walk() above), so the comparison branch can pin
    # myRow.myProgress / myRow.targetValue / etc. directly without
    # changing the snapshot encoder. The 7 myRow fields plus
    # totalCount + activeCoachSurgePresent + cachePrimed + schemaVersion
    # = 11 KEYS / 11 PASS arithmetic per brief §7 done criterion 6.
    KEYS="totalCount activeCoachSurgePresent myRow.isParticipating myRow.myCompleted myRow.myProgress myRow.targetValue myRow.xpReward myRow.participantCount myRow.completedCount cachePrimed schemaVersion"
    ;;
healthsync)
    # HealthSyncStateSnapshot shape (see HealthSyncStateSnapshot.swift:38-50).
    # Pure-local, two-state canary — engaged-or-not. Adapter emits
    # isConnected / isHealthDataAvailable / cachePrimed / schemaVersion=1.
    # `isConnected` reflects `HealthKitRepository.isAnyAuthorizationRequested()`
    # which flips true after the HK seeder XCUITest grants the 5 read
    # types via Profile → Device & Health → Connect Health (per
    # `HealthKitRepository.swift:91-97 + :126-138`); the URL handler
    # reads from the SINGLETON repository, NOT from a screen-mounted
    # ViewModel — so no Navigate-to-HealthSync XCUITest is required
    # (correctness depends on install-fresh's existing HK seeder
    # dispatch at ios-install-fresh.sh:323 running BEFORE this screen's
    # invocation). `isHealthDataAvailable` is `HKHealthStore.is-
    # HealthDataAvailable()` — true on every modern Simulator.
    # No nested JSON; flat top-level keys only.
    KEYS="isConnected isHealthDataAvailable cachePrimed schemaVersion"
    ;;
profile)
    # ProfileStateSnapshot shape (see ProfileStateSnapshot.swift:51-83).
    # Adapter emits displayName / dayNumber / healthKitConnected /
    # buildSha / cachePrimed / schemaVersion=1. iOS Profile-tab IS
    # Settings inline (CEO 2026-04-21 rule), so this single dispatcher
    # branch covers both surfaces. URL handler reads from SINGLETONS
    # (DashboardRepository.state.profile + HealthKitRepository) — same
    # singleton-reads-no-Navigate-XCUITest pattern as Sprint 10
    # HealthSync. `healthKitConnected` is the same field HealthSync
    # reads as `isConnected`, just renamed for the Profile surface.
    # `buildSha` is dynamic per-run — the comparison branch below
    # checks it against $EXPECTED_SHA (the dispatcher arg), NOT a
    # canonical-values.sh constant.
    KEYS="displayName dayNumber healthKitConnected buildSha cachePrimed schemaVersion"
    ;;
esac

PARSED="$(mktemp -t client-data-parsed.XXXXXX)"
trap 'rm -f "$ADAPTER_STDOUT" "$ADAPTER_STDERR" "$PARSED"' EXIT

python3 - "$ADAPTER_STDOUT" >"$PARSED" 2>/dev/null <<PY || true
import json, sys
KEYS = "$KEYS".split()
try:
    raw = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)

# Tolerate leading log noise by scanning for the first '{' that parses.
start = raw.find("{")
obj = None
dec = json.JSONDecoder()
while start != -1:
    try:
        obj, _end = dec.raw_decode(raw[start:])
        break
    except Exception:
        start = raw.find("{", start + 1)

if obj is None or not isinstance(obj, dict):
    sys.exit(0)

# Walk a dotted-path key (e.g. "myRow.isParticipating") through nested
# dicts. Returns None if any segment is missing or not a dict. Sprint 9
# (Challenges) introduced the first nested snapshot — `myRow` is a
# JSON object — so the comparison branch can pin per-row fields like
# `myRow.myProgress` against canonical-values.sh constants. Top-level
# (no dot) keys behave identically to the prior `obj.get(k, None)`.
def walk(o, key):
    cur = o
    for seg in key.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(seg, None)
        if cur is None:
            return None
    return cur

for k in KEYS:
    v = walk(obj, k)
    if v is None:
        print(k + "\t")
    else:
        # Preserve numeric shape as source wrote it; stringify floats faithfully.
        if isinstance(v, bool):
            sv = "true" if v else "false"
        elif isinstance(v, float):
            sv = ("%g" % v) if v == int(v) else ("%s" % v)
        else:
            sv = str(v)
        sv = sv.replace("\t", " ").replace("\n", " ")
        print(k + "\t" + sv)
PY

if [ ! -s "$PARSED" ]; then
    printf "  %s✗%s adapter: FAIL — could not parse JSON from adapter stdout\n" "$C_RED" "$C_RESET"
    head -200 "$ADAPTER_STDOUT" | sed 's/^/    /'
    echo ""
    echo "Summary: 0 pass, 1 fail, 0 skipped"
    exit 2
fi

# Build an associative lookup in a portable way.
get_observed() {
    local key="$1"
    awk -F'\t' -v k="$key" '$1 == k { print $2; found=1; exit } END { if (!found) print "__MISSING__" }' "$PARSED"
}

# Equality helpers.
num_eq() {
    # Compares as integers when both sides look integral, else as floats.
    # Returns 0 on equal.
    local a="$1" b="$2"
    awk -v a="$a" -v b="$b" 'BEGIN { exit !((a + 0) == (b + 0)) }'
}

str_eq() {
    [ "$1" = "$2" ]
}

# ---------------------------------------------------------------------------
# Compare canonical fields
# ---------------------------------------------------------------------------

compare_static_string() {
    local field="$1" expected="$2"
    local observed
    observed="$(get_observed "$field")"
    if [ "$observed" = "__MISSING__" ] || [ -z "$observed" ]; then
        skip_field "$field" "adapter did not report this field"
        return
    fi
    if str_eq "$observed" "$expected"; then
        pass_field "$field" "$observed" "$expected"
    else
        fail_field "$field" "$observed" "$expected"
    fi
}

compare_static_numeric() {
    local field="$1" expected="$2"
    local observed
    observed="$(get_observed "$field")"
    if [ "$observed" = "__MISSING__" ] || [ -z "$observed" ]; then
        skip_field "$field" "adapter did not report this field"
        return
    fi
    if num_eq "$observed" "$expected"; then
        pass_field "$field" "$observed" "$expected"
    else
        fail_field "$field" "$observed" "$expected"
    fi
}

compare_min_numeric() {
    # observed MUST be >= expected_min.
    local field="$1" expected_min="$2"
    local observed
    observed="$(get_observed "$field")"
    if [ "$observed" = "__MISSING__" ] || [ -z "$observed" ]; then
        skip_field "$field" "adapter did not report this field"
        return
    fi
    if awk -v a="$observed" -v b="$expected_min" 'BEGIN { exit !((a + 0) >= (b + 0)) }'; then
        pass_field "$field" "$observed" ">= $expected_min"
    else
        fail_field "$field" "$observed" ">= $expected_min"
    fi
}

# ---------------------------------------------------------------------------
# cachePrimed gate — check FIRST. If the adapter reports false (or an
# equivalent adapter-side exit-3 via empty state), the Home view hasn't
# loaded canonical values yet and every downstream comparison is noise.
# Fail with an explicit message instead of letting per-field failures
# flood the diagnostic.
# ---------------------------------------------------------------------------
# cachePrimed diagnostic text describes which view is not primed. Per-
# screen so operators see "Home view" vs "FoodLog view" vs …
case "$SCREEN" in
home)        SCREEN_VIEW_NAME="Home view" ;;
food-log)    SCREEN_VIEW_NAME="FoodLog view" ;;
pantry)      SCREEN_VIEW_NAME="Pantry view" ;;
messages)    SCREEN_VIEW_NAME="Messages view" ;;
steps)       SCREEN_VIEW_NAME="Steps view" ;;
trophies)    SCREEN_VIEW_NAME="Trophies view" ;;
leaderboard) SCREEN_VIEW_NAME="Leaderboard view" ;;
check-in)    SCREEN_VIEW_NAME="Check-In view" ;;
challenges)  SCREEN_VIEW_NAME="Challenges view" ;;
healthsync)  SCREEN_VIEW_NAME="HealthSync view" ;;
profile)     SCREEN_VIEW_NAME="Profile view" ;;
*)           SCREEN_VIEW_NAME="${SCREEN} view" ;;
esac

# Seal path — HOME uses the historical unsuffixed name to preserve
# byte-identical output for Android (which is always home today). Non-
# home screens get an explicit -<screen> suffix so multiple seals can
# coexist per platform.
if [ "$SCREEN" = "home" ]; then
    SEAL_PATH="$REPO_ROOT/.claude/state/client-data-seal-${PLATFORM}.json"
else
    SEAL_PATH="$REPO_ROOT/.claude/state/client-data-seal-${PLATFORM}-${SCREEN}.json"
fi

cache_primed_observed="$(get_observed cachePrimed)"
case "$cache_primed_observed" in
    true|True|1)
        pass_field cachePrimed "true" "true"
        ;;
    __MISSING__|"")
        skip_field cachePrimed "adapter did not report this field"
        ;;
    *)
        # Anything non-true is a hard fail. Mirror the fail_field shape but
        # with a clearer diagnostic that short-circuits the remaining checks.
        printf "  %s✗%s cachePrimed: FAIL — %s has NOT loaded canonical values yet (observed: %s)\n" \
            "$C_RED" "$C_RESET" "$SCREEN_VIEW_NAME" "$cache_primed_observed"
        FAILURES=$((FAILURES + 1))
        echo ""
        echo "${C_RED}CLIENT DATA CONTRACT VIOLATED${C_RESET}" >&2
        echo "  cachePrimed=false — the $SCREEN_VIEW_NAME has not populated" >&2
        echo "  canonical values from its local cache yet. Every other field" >&2
        echo "  comparison is meaningless until this is true. Re-run install-" >&2
        echo "  fresh and give the adapter more time (or investigate why the" >&2
        echo "  cache is not priming)." >&2
        echo "  Spec: docs/client-data-contract.md §5" >&2
        rm -f "$SEAL_PATH" 2>/dev/null
        exit 2
        ;;
esac

# Per-screen field comparisons. Each branch reads from $KEYS (already
# screen-specialized above) via `get_observed`, and compares against the
# matching canonical-values.sh constants.
case "$SCREEN" in
home)
    # Today's activity — static constants (Home-surface names from the
    # landed adapter: steps, activeKcal. Server-only totalKcal and
    # restingHeartRate live in canonical-values.sh but are NOT checked here.)
    compare_static_numeric steps "$CANONICAL_TODAY_STEP_COUNT"
    compare_static_numeric activeKcal "$CANONICAL_TODAY_ACTIVE_KCAL"

    # Targets
    compare_static_numeric stepGoal "$CANONICAL_STEP_GOAL"
    compare_static_numeric caloriesTarget "$CANONICAL_TARGET_CALORIES"
    compare_static_numeric proteinTargetG "$CANONICAL_TARGET_PROTEIN_G"

    # Weight — v5 HIGH-4 (Frank F-3): dropped from the v1 Home surface
    # because Home does not render weight today. Restored when a Home tile
    # starts rendering weight; until then `weightKg` is exercised only by
    # seedE2E:verify on the server side.

    # XP / Level — v5.3.4: xpTotal + xpToNextLevel are hidden by the server
    # (xpInvisibleToClients=true) so they are no longer part of the client
    # surface. SERVER_* equivalents in canonical-values.sh are checked by
    # seedE2E:verify (admin context) instead.
    compare_static_numeric xpLevel "$CANONICAL_MARCUS_LEVEL"
    compare_static_numeric xpProgressPercent "$CANONICAL_MARCUS_XP_PROGRESS_PERCENT"

    # Counts (minimum — foodLogCount must be at least the canonical min).
    compare_min_numeric foodLogCount "$CANONICAL_TODAY_FOOD_LOG_COUNT_MIN"

    # dayNumber — pinned via the seed anchor (seedE2E.ts:setupE2EAccounts
    # re-writes users.createdAt to `todayUtcStart - CANONICAL_MARCUS_
    # CREATED_AT_DAYS_AGO * DAY` on every run). DAYS.between(createdAt,
    # today) + 1 therefore evaluates to CANONICAL_DAY_NUMBER on every
    # wall-clock day, making this check an exact-value equality instead of
    # the old >= 1 lower bound that let cold-start drift hide.
    compare_static_numeric dayNumber "$CANONICAL_DAY_NUMBER"
    ;;

food-log)
    # Today's FoodLog render (see FoodLogStateSnapshot.swift). Every key
    # is an exact-equality check against the canonical — FoodLog today
    # has a fixed 3-entry shape (breakfast/lunch/dinner), so the minimum
    # bound that Home uses for foodLogCount would hide drift here.
    compare_static_numeric todayLogCount "$CANONICAL_TODAY_FOOD_LOG_COUNT"
    compare_static_numeric caloriesTotal "$CANONICAL_TODAY_FOOD_CALORIES"
    compare_static_numeric proteinG "$CANONICAL_TODAY_FOOD_PROTEIN_G"
    compare_static_numeric carbsG "$CANONICAL_TODAY_FOOD_CARBS_G"
    compare_static_numeric fatG "$CANONICAL_TODAY_FOOD_FAT_G"
    compare_static_string mealsPresent "$CANONICAL_TODAY_FOOD_MEALS_PRESENT"
    ;;

pantry)
    # PantryStateSnapshot shape (see PantryStateSnapshot.swift). Canonical
    # counts are 8/5/3 — Marcus's tenant pantry is seeded at
    # seedE2E.ts:1990-2058 (`seedMarcusPantry`): 5 team-shared foods
    # (Banana, Brown Rice, Chicken Breast, Greek Yogurt, Oatmeal) +
    # 3 Marcus-personal foods (Marcus's Protein Shake, Salad, Smoothie).
    # The seed is wipe-and-reinsert idempotent so the totals are
    # invariant across wall-clock time and re-entrant on repeat runs.
    # See canonical-values.sh:147-169 for the canonical literals + the
    # ownerType derivation rule (tenant = "team", personal != "team").
    #
    # `date` is wall-clock dependent (today's local-date key) and not
    # canonical — intentionally not asserted.
    compare_static_numeric itemsTotal "$CANONICAL_PANTRY_ITEMS_TOTAL"
    compare_static_numeric tenantFoodCount "$CANONICAL_PANTRY_TENANT_FOOD_COUNT"
    compare_static_numeric personalFoodCount "$CANONICAL_PANTRY_PERSONAL_FOOD_COUNT"
    # schemaVersion drifts would signal a snapshot-schema refactor landed
    # without updating the adapter KEYS/canonical-keys in lock-step.
    # Pin to the integer value in PantryStateSnapshot.currentSchemaVersion
    # via the canonical constant if one is added; today compare against
    # literal 1 (the only version Pantry has shipped).
    compare_static_numeric schemaVersion "1"
    ;;

messages)
    # MessagesStateSnapshot schema v2. seedE2E pins 12 natural
    # coach↔client messages; post HC-seed the 🏆 system row may inflate
    # `messageCount` to 13 but `userMessageCount` stays pinned at 12
    # (filter excludes system rows by definition). The authoritative
    # bubble-alignment regression guard is the
    # `userMessageCount == 12` + `selfMessageCount >= 6` pair — going
    # below either catches the 2026-04-24 CEO bug ("only stuff a coach
    # would ever see").
    #
    # `messageCount` retained as an advisory MIN compare — a value
    # below 12 means the seed didn't land, which is upstream breakage
    # not a bubble bug. The exact value isn't pinned because
    # systemMessageCount is NONCANONICAL (depends on whether HC sync
    # has fired completeCoachChallenge; post-70k-steps it's 1, pre is
    # 0). `systemMessageCount` itself is NOT compared at all —
    # documented NONCANONICAL in canonical-values.sh.
    #
    # `serverCurrentUserId` is NOT compared — its value is the Convex
    # users._id for Marcus which varies per seed run. Presence is
    # implicit via the selfMessageCount assertion (a nil
    # serverCurrentUserId would zero out the self count).
    compare_static_numeric conversationCount "$CANONICAL_MESSAGES_CONVERSATION_COUNT"
    compare_static_string  coachName         "$CANONICAL_MESSAGES_COACH_NAME"
    compare_static_string  clientName        "$CANONICAL_MESSAGES_CLIENT_NAME"
    compare_static_numeric unreadCount       "$CANONICAL_MESSAGES_UNREAD_COUNT"
    compare_static_string  lastMessagePresent "$CANONICAL_MESSAGES_LAST_MESSAGE_PRESENT"
    compare_min_numeric    messageCount      "$CANONICAL_MESSAGES_MESSAGE_COUNT"
    compare_static_numeric userMessageCount  "$CANONICAL_MESSAGES_USER_MESSAGE_COUNT"
    compare_min_numeric    selfMessageCount  "$CANONICAL_MESSAGES_SELF_MESSAGE_COUNT"
    compare_static_numeric schemaVersion     "2"
    ;;

steps)
    # StepsStateSnapshot shape (see StepsStateSnapshot.swift:31-46). Today's
    # hero values re-use the Sprint 1 Home anchors — same canonical-values.sh
    # constants as Home's `steps` / `activeKcal` / `stepGoal` keys, but the
    # Steps view exposes them under different field names
    # (todayStepCount / todayActiveKcal / stepGoal). recentDaysCount is a
    # MIN per canonical-values.sh:268 because Marcus's profile createdAt
    # anchor (CANONICAL_MARCUS_CREATED_AT_DAYS_AGO=13) pins at LEAST 14
    # rows (today + 13 back) but the seed can flex how far back it fills.
    # schemaVersion drift would signal a snapshot-schema refactor without
    # adapter KEYS lock-step update.
    compare_static_numeric todayStepCount "$CANONICAL_TODAY_STEP_COUNT"
    compare_static_numeric todayActiveKcal "$CANONICAL_TODAY_ACTIVE_KCAL"
    compare_static_numeric stepGoal "$CANONICAL_STEP_GOAL"
    compare_min_numeric    recentDaysCount "$CANONICAL_STEPS_RECENT_DAYS_MIN"
    compare_static_numeric schemaVersion "1"
    ;;

trophies)
    # TrophiesStateSnapshot shape (see TrophiesStateSnapshot.swift:55-72).
    # Every numeric field is a MIN, not EXACT — trophy earned-counts depend
    # on runtime-variable cron timing across 16 source tables fanned out by
    # `gamification/trophies.ts:99-116`. The cachePrimed gate is checked in
    # the SHARED block above (lines ~494-518), so it is NOT compared here
    # again; the per-screen branch only covers the 6 numeric MINs +
    # schemaVersion drift detection. See canonical-values.sh:317-348 for
    # the runtime-non-determinism doctrine.
    compare_min_numeric trophyCount       "$CANONICAL_TROPHIES_TROPHY_COUNT_MIN"
    compare_min_numeric mysterySlotCount  "$CANONICAL_TROPHIES_MYSTERY_SLOT_COUNT_MIN"
    compare_min_numeric totalEarned       "$CANONICAL_TROPHIES_TOTAL_EARNED_MIN"
    compare_min_numeric thisMonth         "$CANONICAL_TROPHIES_THIS_MONTH_MIN"
    compare_min_numeric gold              "$CANONICAL_TROPHIES_GOLD_MIN"
    compare_min_numeric inProgressCount   "$CANONICAL_TROPHIES_IN_PROGRESS_COUNT_MIN"
    compare_static_numeric schemaVersion  "1"
    ;;

leaderboard)
    # LeaderboardStateSnapshot shape (see LeaderboardStateSnapshot.swift:49-65).
    # Sprint 7 pins the weekly_logging category. The cachePrimed gate is
    # checked in the SHARED block above (lines ~494-518), so it is NOT
    # compared here again. peerCount is a MIN per
    # canonical-values.sh:284-289 (5 seed peers + Marcus = 6 minimum,
    # MIN because future seed extensions may add more). mySelfRowPresent
    # asserts Marcus's own row appears in the rankings — a false reading
    # is a real regression in the rankings query. myRank is intentionally
    # NOT pinned (snapshot doc :35-36 — seedLeaderboardPeers does not pin
    # Marcus's exact rank). period is wall-clock-dependent ISO week format
    # (also NOT pinned). Both are listed in KEYS for parser ingestion but
    # skipped here.
    compare_min_numeric    peerCount        "$CANONICAL_LEADERBOARD_WEEKLY_LOGGING_TOTAL_MIN"
    compare_static_string  mySelfRowPresent "$CANONICAL_LEADERBOARD_SELF_ROW_PRESENT"
    compare_static_numeric schemaVersion    "1"
    ;;

check-in)
    # CheckInStateSnapshot shape (see CheckInStateSnapshot.swift:50-71).
    # The cachePrimed gate is checked in the SHARED block above
    # (lines ~494-518), so it is NOT compared here again.
    #
    # historyCount is a MIN per seedHeavyData.ts:661-702 (17 weekly
    # rows for clientIndex=0 → Marcus, idempotent on (tenantId,
    # userId, weekStart) via `by_tenant_user_week`); add 0-2 from
    # prior CheckIn-tab navigation submits via example/convex/checkIns.ts:72
    # in earlier audits, capped at one row per week. Range observed:
    # 17-19. The MIN floor passes any partially-seeded environment with
    # at least the seedHeavyData base. currentWeekSubmitted is EXACT
    # true — seedHeavyData includes week=0 (today's week) for
    # clientIndex=0 unconditionally (gapDays=0 → week=0 NOT skipped at
    # line 664). weekStart is intentionally NOT compared (snapshot
    # doc :58-60 — wall-clock-dependent UTC ISO-Monday, self-identifying
    # for cross-screen consistency).
    #
    # NOTE: tenant-scoping correctness on `checkIns:list` is NOT
    # proven by this contract anymore (it was, when the canonical
    # was zero-state — any non-zero row would have caught a leak).
    # That invariant is now enforced server-side at
    # example/convex/checkIns.ts:102-115 via `tenantGuard` + the
    # `by_tenant_user` index pinning both `tenantId` AND
    # `userId == user._id`. A separate test would be needed to
    # surface a tenant-scoping regression; see
    # `qa-audits/ios-real-data/check-in/sha-ef10924d-mark-diagnosis.md`
    # for the full rationale.
    compare_static_string currentWeekSubmitted "$CANONICAL_CHECKIN_CURRENT_WEEK_SUBMITTED"
    compare_min_numeric   historyCount         "$CANONICAL_CHECKIN_HISTORY_COUNT_MIN"
    compare_static_numeric schemaVersion       "1"
    ;;

challenges)
    # ChallengesStateSnapshot shape (see ChallengesStateSnapshot.swift:43-127).
    # Sprint 9 introduced dotted-path key extraction to the parser (see
    # walk() above), so this branch can pin the nested `myRow` fields
    # directly. The cachePrimed gate is checked in the SHARED block above
    # (lines ~494-518), so it is NOT compared here again.
    #
    # Canonical traces back to seedE2E.ts:1440-1541 `seedCoachChallenge`:
    # one active "7-Day Step Surge" with targetValue=70000 / xpReward=300,
    # deterministic completion order
    # ["Derek Callahan","Tyler Okonkwo","Marcus Chen","Jordan Rivera",
    # "Nate Hoffman","Ben Quigley"], top 2 (Derek + Tyler) completed,
    # Marcus at rank 2 → currentValue = 49000, completed=false.
    # totalCount stays EXACT 1 because seedHeavyData.ts does NOT touch
    # the `challenges` table (only one string-literal mention in
    # messages seed at :979).
    #
    # `participantCount` is a MIN, not EXACT. The seedE2E enrollment
    # loop at example/convex/seedE2E.ts:1490-1495 collects participants
    # via `users.by_tenant_role` (every tenant-client, not just the
    # 6 named ones in completionOrder); seedHeavyData.ts:316-393 adds
    # 19 additional tenant-clients, so observed value = 25 on a fully
    # seeded environment. Floor = 6 (Marcus + 5 named leaderboard
    # peers from seedE2E.ts alone). MIN matches the Sprint 7
    # leaderboard precedent (CANONICAL_LEADERBOARD_WEEKLY_LOGGING_-
    # TOTAL_MIN) — same query shape, same MIN-vs-EXACT rationale.
    # See `qa-audits/ios-real-data/challenges/sha-1547b335-mark-diagnosis.md`
    # for the full seed-graph trace.
    #
    # `completedCount` stays EXACT 2 — only ranks 0-1 (Derek + Tyler)
    # have `completed=true`; everyone else (including all
    # seedHeavyData rank=-1 peers) is `completed=false`.
    # `myProgress` stays EXACT 49000 — Marcus is at completionOrder
    # index 2 unconditionally and short-circuits seedHeavyData's
    # `if (existing) continue` early-out.
    compare_static_numeric totalCount               "$CANONICAL_CHALLENGES_TOTAL_COUNT"
    compare_static_string  activeCoachSurgePresent "true"
    compare_static_string  myRow.isParticipating   "true"
    compare_static_string  myRow.myCompleted       "$CANONICAL_CHALLENGES_MY_COMPLETED"
    compare_static_numeric myRow.myProgress        "$CANONICAL_CHALLENGES_MY_PROGRESS"
    compare_static_numeric myRow.targetValue       "$CANONICAL_CHALLENGES_COACH_SURGE_TARGET"
    compare_static_numeric myRow.xpReward          "$CANONICAL_CHALLENGES_COACH_SURGE_XP_REWARD"
    compare_min_numeric    myRow.participantCount  "$CANONICAL_CHALLENGES_PARTICIPANT_COUNT_MIN"
    compare_static_numeric myRow.completedCount    "$CANONICAL_CHALLENGES_COMPLETED_COUNT"
    compare_static_numeric schemaVersion           "1"
    ;;

healthsync)
    # HealthSyncStateSnapshot shape (see HealthSyncStateSnapshot.swift:38-50).
    # Pure-local two-state canary — engaged-or-not. The cachePrimed gate
    # is checked in the SHARED block above (lines ~494-518), so it is
    # NOT compared here again. `isConnected` reflects
    # `HealthKitRepository.isAnyAuthorizationRequested()` — flips true
    # after install-fresh's HK seeder XCUITest grants the 5 read types
    # (steps / activeEnergyBurned / basalEnergyBurned / heartRate /
    # restingHeartRate per HealthKitRepository.swift:91-97). HK
    # deliberately hides per-type READ auth (privacy stance documented
    # at HealthKitRepository.swift:119-125), so the snapshot's two-field
    # shape is intentional and platform-correct — Sprint 10 must NOT
    # add per-category fields to "match" Android's per-type Health
    # Connect surface (see HealthSyncStateSnapshot.swift:33-37 for the
    # documented platform-asymmetry rationale). `isHealthDataAvailable`
    # is `HKHealthStore.isHealthDataAvailable()` — true on every modern
    # iOS Simulator. Both bool fields use compare_static_string with
    # "true"/"false" literals (the existing bool-as-string convention,
    # same as messages's lastMessagePresent and leaderboard's
    # mySelfRowPresent).
    compare_static_string  isConnected           "$CANONICAL_HEALTHSYNC_IS_CONNECTED"
    compare_static_string  isHealthDataAvailable "$CANONICAL_HEALTHSYNC_IS_HEALTH_DATA_AVAILABLE"
    compare_static_numeric schemaVersion         "1"
    ;;

profile)
    # ProfileStateSnapshot shape (see ProfileStateSnapshot.swift:51-83).
    # iOS Profile-tab IS Settings inline (CEO 2026-04-21 rule). The
    # cachePrimed gate is checked in the SHARED block above (lines
    # ~494-518), so it is NOT compared here again. `displayName` and
    # `dayNumber` re-use the shared canonicals (CANONICAL_CLIENT_DISPLAY_NAME
    # at :32 / CANONICAL_DAY_NUMBER at :48). `healthKitConnected` reads
    # the SAME `isAnyAuthorizationRequested()` singleton as HealthSync
    # — Sprint 11 flipped the canonical from "false" to "true" in
    # lockstep with Sprint 10's empirical PASS (canonical-values.sh
    # comment block at :273-285 documents the rationale). `buildSha`
    # is dynamic per-run — compared against the dispatcher's
    # `$EXPECTED_SHA` argument, NOT a canonical-values.sh constant.
    # The compare_static_string call accepts any string literal as the
    # expected value, so passing "$EXPECTED_SHA" works the same way
    # as passing a canonical constant.
    compare_static_string  displayName        "$CANONICAL_CLIENT_DISPLAY_NAME"
    compare_static_numeric dayNumber          "$CANONICAL_DAY_NUMBER"
    compare_static_string  healthKitConnected "$CANONICAL_PROFILE_HK_CONNECTED"
    compare_static_string  buildSha           "$EXPECTED_SHA"
    compare_static_numeric schemaVersion      "1"
    ;;
esac

# ---------------------------------------------------------------------------
# Seal emission on green exit — Client Data-Render Contract §7
# ---------------------------------------------------------------------------
#
# When every canonical field matches (FAILURES=0 AND SKIPS=0), write a seal
# artifact that downstream tooling (test-command Bash hook, V7 agent hook,
# freshness-check --with-data-contract) consumes as proof the installed app
# is rendering canonical Marcus values right now.
#
# Seal is NEVER written when anything is wrong (failure or skip). Consumers
# treat an absent seal as "not verified" — equivalent to invalid.

write_seal() {
    local platform="$1" sha="$2" values_file="$3" screen="$4" seal_path="$5"
    local state_dir canonical_hash canonical_file_hash ts device_id secret_file
    state_dir="$REPO_ROOT/.claude/state"
    mkdir -p "$state_dir" 2>/dev/null || true

    # SHA256 of the authoritative canonical-values.sh file (the SSOT).
    # We deliberately hash the .sh file — the TS mirror
    # (example/convex/canonicalValues.ts) is a projection, not the source.
    if command -v shasum >/dev/null 2>&1; then
        canonical_file_hash="$(shasum -a 256 "$CANONICAL" 2>/dev/null | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
        canonical_file_hash="$(sha256sum "$CANONICAL" 2>/dev/null | awk '{print $1}')"
    else
        canonical_file_hash="unknown"
    fi
    canonical_hash="sha256:${canonical_file_hash}"

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    device_id="${CLIENT_DATA_SEAL_DEVICE_ID:-unknown}"

    # H-4 (docs/client-data-contract.md §7) — HMAC the seal. A secret
    # lives at .claude/state/seal-hmac.secret (0600, gitignored via the
    # blanket /.claude/* rule). Created here on first seal mint if
    # missing; reused on every subsequent mint. Seal-verify reads the
    # same file and rejects forged seals whose HMAC doesn't match.
    #
    # This does NOT defend against an adversary with read access to the
    # secret file (they can mint a valid seal). The goal is closing the
    # "naive agent writes a 4-field JSON" bypass class, not
    # cryptographic sandboxing.
    secret_file="$state_dir/seal-hmac.secret"
    if [ ! -f "$secret_file" ]; then
        # Prefer openssl (ubiquitous on macOS + every standard Linux);
        # fall back to /dev/urandom + base64 for portability on minimal
        # environments where openssl isn't present. Either source yields
        # 32 random bytes in the same base64-on-one-line shape.
        if command -v openssl >/dev/null 2>&1; then
            openssl rand -base64 32 > "$secret_file" 2>/dev/null
        elif [ -r /dev/urandom ] && command -v base64 >/dev/null 2>&1; then
            head -c 32 /dev/urandom | base64 > "$secret_file" 2>/dev/null
        else
            printf "  %s✗%s seal-hmac: FAIL — neither openssl nor /dev/urandom+base64 available to mint secret\n" \
                "$C_RED" "$C_RESET" >&2
            return 1
        fi
        chmod 600 "$secret_file" 2>/dev/null || true
    fi

    # Seal path is passed in — HOME keeps the historical unsuffixed name
    # so Android's seal is byte-identical across this refactor; non-home
    # screens get the -<screen> suffix. See the caller for derivation.
    local tmp_seal
    tmp_seal="$(mktemp -t client-data-seal.XXXXXX)"

    # Inline the adapter's JSON payload under `values` so operators can
    # forensically read what was rendered at seal time. Python computes
    # HMAC-SHA256 over a deterministic canonical-sorted JSON of the
    # seal-minus-hmac fields, then serializes the final seal (with hmac
    # field appended) for disk.
    #
    # Seal body includes `screen` for non-home surfaces. For home the
    # key is omitted so Android's existing seal format is preserved
    # exactly (downstream verifiers that key on canonical-sorted JSON
    # would otherwise see a shape change).
    python3 - "$values_file" "$platform" "$sha" "$canonical_hash" "$ts" "$device_id" "$secret_file" "$screen" \
        >"$tmp_seal" 2>/dev/null <<'PY' || true
import base64, hashlib, hmac, json, sys
values_file, platform, sha, canonical_hash, ts, device_id, secret_file, screen = sys.argv[1:]
try:
    with open(values_file, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    start = raw.find("{")
    obj = None
    dec = json.JSONDecoder()
    while start != -1:
        try:
            obj, _end = dec.raw_decode(raw[start:])
            break
        except Exception:
            start = raw.find("{", start + 1)
    values = obj if isinstance(obj, dict) else {}
except Exception:
    values = {}
seal_body = {
    "sha": sha,
    "canonicalHash": canonical_hash,
    "timestamp": ts,
    "platform": platform,
    "deviceId": device_id,
    "values": values,
}
# Preserve the pre-dispatcher seal shape for the Home surface by only
# emitting `screen` when it's non-home. Android Home seals are byte-
# identical before/after this change.
if screen != "home":
    seal_body["screen"] = screen
# Canonical JSON: sort keys, compact separators — deterministic bytes.
payload = json.dumps(seal_body, sort_keys=True, separators=(",", ":")).encode("utf-8")
try:
    with open(secret_file, "rb") as f:
        secret = f.read().strip()
except Exception:
    secret = b""
mac = hmac.new(secret, payload, hashlib.sha256).digest()
seal = dict(seal_body)
seal["hmac"] = "hmac-sha256:" + base64.b64encode(mac).decode("ascii")
print(json.dumps(seal, indent=2))
PY

    if [ -s "$tmp_seal" ]; then
        mv "$tmp_seal" "$seal_path"
        printf "  %s✓%s seal written: %s\n" "$C_GREEN" "$C_RESET" "$seal_path"
    else
        rm -f "$tmp_seal"
        printf "  %s✗%s seal write FAILED (python3 not available or empty output)\n" \
            "$C_RED" "$C_RESET" >&2
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Summary: ${PASSES} pass, ${FAILURES} fail, ${SKIPS} skipped"

if [ "$FAILURES" -gt 0 ]; then
    echo ""
    echo "${C_RED}CLIENT DATA CONTRACT VIOLATED${C_RESET}" >&2
    echo "  One or more canonical values did NOT render on the installed client." >&2
    echo "  Do NOT proceed to QA. Diagnose the mismatch before testing." >&2
    echo "  Spec: docs/client-data-contract.md" >&2
    # Proactively wipe any stale seal so downstream tooling sees the break.
    rm -f "$SEAL_PATH" 2>/dev/null
    exit 2
fi
if [ "$SKIPS" -gt 0 ]; then
    # Skipped fields mean the adapter RAN but omitted one or more of the
    # canonical-keys set for this screen. Either way the contract is NOT
    # fully verified; wipe any stale seal so downstream tooling refuses
    # to trust a partial run.
    rm -f "$SEAL_PATH" 2>/dev/null
    # M-2 (automation-QA Layer 2): under ENFORCE=1, required-key-missing must be
    # a HARD fail, not exit-3. Exit-3 is reserved for "adapter binary
    # not present" (handled earlier in the script). Once the adapter
    # runs and returns JSON, every v1 key must be present; an
    # adapter-renamed-a-key regression should loudly fail, not sail
    # through as "rollout skip."
    if [ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" = "1" ]; then
        echo ""
        echo "${C_RED}CLIENT DATA CONTRACT VIOLATED${C_RESET}" >&2
        echo "  CLIENT_DATA_CONTRACT_ENFORCE=1 and adapter ran but omitted" >&2
        echo "  ${SKIPS} required canonical key(s). A real adapter regression" >&2
        echo "  must not masquerade as 'adapter not landed yet'." >&2
        echo "  Spec: docs/client-data-contract.md §5 (v1 Home-surface keys)" >&2
        exit 2
    fi
    exit 3
fi

# All-green: write the seal. Downstream hooks (verify-test-bash.sh,
# freshness-check.sh --with-data-contract, V7 agent hook) will honor it.
write_seal "$PLATFORM" "$EXPECTED_SHA" "$ADAPTER_STDOUT" "$SCREEN" "$SEAL_PATH"
exit 0
