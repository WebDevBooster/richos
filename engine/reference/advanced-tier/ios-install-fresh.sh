#!/usr/bin/env bash
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
# ios-install-fresh.sh — erase / build / install / ground-truth verify
#
# iOS Simulator analog of scripts/android-install-fresh.sh. Part of the
# freshness contract (docs/freshness-contract.md) — refuses to report success
# unless the on-device `BuildInfo.sha` matches the expected commit hash.
#
# This is the ONLY sanctioned way to put a fresh Example Debug build onto a
# booted iOS Simulator during QA. The Keychain-persists-across-uninstall bug
# (feedback_ios_simulator_keychain_persists_uninstall.md) means `simctl
# uninstall` is insufficient for a true fresh install — this script does a
# full `simctl erase` by default.
#
# Usage:
#   scripts/ios-install-fresh.sh [--device <udid|name>] [--keep-data]
#                                [--seed-healthkit] [<expected-sha>]
#
# Arguments:
#   expected-sha  The 12-char commit hash the installed app MUST report.
#                 Defaults to `git rev-parse --short=12 HEAD` when omitted.
#
# Options:
#   --device <udid|name>  Simulator UDID or name. Defaults to the currently
#                         booted device, or picks the first "iPhone 15 Pro"
#                         runtime if none is booted.
#   --keep-data           Skip `simctl erase` — uninstall only. Faster but
#                         Keychain + HealthKit samples persist. Use ONLY
#                         when you intentionally want to preserve prior
#                         seeder output (e.g. re-testing the same session).
#   --seed-healthkit      After the fresh install + launch, print the
#                         DEBUG-only seeder instructions. (We cannot
#                         programmatically trigger the button yet — that
#                         requires a signed-in session.)
#
# Exit codes:
#   0  install verified — on-Simulator BUILD_SHA matches expected
#   1  script error (missing tool, build failure, no simulator, etc.)
#   2  freshness MISMATCH — app reports a different SHA than expected
#   3  no BUILD_SHA line in syslog — build is pre-contract
#
# Canonical spec: docs/freshness-contract.md §iOS layer.

set -euo pipefail

BUNDLE_ID="com.example.app"
SCHEME="ExampleApp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/example/ios/ExampleApp.xcodeproj"
DEFAULT_DEVICE_NAME="iPhone 16 Pro"

# ----- zombie-path guard (identity-or-refuse on our OWN location) --------------
#
# A stalled agent's orphaned background install-fresh can outlive BOTH the agent
# AND its worktree: `git worktree remove` deletes the worktree dir + registry
# entry, but the still-running orphan re-creates the path on its way to a state
# write and mints a seal into that GHOST directory. Refuse to write state unless
# our resolved location is the true main checkout or a path currently REGISTERED
# in its `git worktree list`. Called at startup AND before each state-write phase
# below. (In the source project this lives in a shared
# lib/assert-own-worktree-registered.sh; inlined here so the reference file is
# self-contained.)
assert_own_worktree_registered() {
  local phase="${1:-state write}"
  local self main_co common_dir
  self="$( cd "${REPO_ROOT}" 2>/dev/null && pwd -P )" || self="${REPO_ROOT}"
  # The main checkout is the parent of git's SHARED .git dir; --git-common-dir
  # resolves it identically from the main checkout or any linked worktree — and,
  # from a reaped-then-recreated zombie path under the main tree, still walks up
  # to the real .git. Physical (pwd -P) paths so macOS /var->/private/var never
  # spuriously mismatches `git worktree list` output.
  common_dir="$(git -C "${self}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "${common_dir}" ]]; then
    main_co="$( cd "$(dirname "${common_dir}")" 2>/dev/null && pwd -P )" || main_co="${self}"
  else
    main_co="${self}"
  fi
  [[ "${self}" == "${main_co}" ]] && return 0
  if git -C "${main_co}" worktree list --porcelain 2>/dev/null \
       | sed -n 's|^worktree ||p' | grep -qxF "${self}"; then
    return 0
  fi
  printf '\033[31m✗ ZOMBIE-PATH ABORT (%s): '\''%s'\'' is neither the main checkout\033[0m\n' "${phase}" "${self}" >&2
  printf '\033[31m  nor a REGISTERED worktree of it. A worktree removed via '\''git worktree\033[0m\n' >&2
  printf '\033[31m  remove'\'' whose directory was re-created by an orphaned background run\033[0m\n' >&2
  printf '\033[31m  outliving its agent. State written here is a ghost — refusing (created\033[0m\n' >&2
  printf '\033[31m  nothing). Kill this stray process.\033[0m\n' >&2
  return 1
}
assert_own_worktree_registered "startup" || exit 1

# Default derivedData path keeps the build artifact predictable.
DERIVED_DATA="${REPO_ROOT}/example/ios/build"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/ExampleApp.app"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

run() {
    blue "+ $*"
    "$@"
}

# ----- 0. parse args -------------------------------------------------------

device_arg=""
keep_data=0
seed_healthkit=0
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --device) device_arg="${2:-}"; shift 2 ;;
    --keep-data) keep_data=1; shift ;;
    --seed-healthkit) seed_healthkit=1; shift ;;
    -h|--help)
        sed -n '2,42p' "$0"
        exit 0
        ;;
    *) positional+=("$1"); shift ;;
    esac
done
set -- "${positional[@]:-}"

EXPECTED_SHA="${1:-}"
if [[ -z "${EXPECTED_SHA}" ]]; then
    # git works in both the main checkout and linked worktrees.
    if EXPECTED_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null)"; then
        :
    else
        red "✗ could not resolve default expected SHA via git"
        exit 1
    fi
fi
if [[ ${#EXPECTED_SHA} -ne 12 ]]; then
    red "✗ expected-sha must be exactly 12 chars (got ${#EXPECTED_SHA}: '${EXPECTED_SHA}')"
    exit 1
fi

blue "expected SHA: ${EXPECTED_SHA}"

# ----- 0a. v5 HIGH-5 — contract integrity probe ----------------------------
#
# Frank F-4: confirm `.claude/settings.json` wires the §7 Bash + Agent
# hooks BEFORE we mint a seal. See android-install-fresh.sh §0a for
# full rationale.
INTEGRITY_PROBE="${SCRIPT_DIR}/hooks/contract-integrity-probe.sh"
HOOK_BIN="${SCRIPT_DIR}/hooks/verify-test-bash.sh"
if [[ -x "${INTEGRITY_PROBE}" ]]; then
    blue "+ contract integrity probe (v5 HIGH-5)"
    set +e
    "${INTEGRITY_PROBE}" >&2
    probe_rc=$?
    set -e
    if [[ "${probe_rc}" -ne 0 ]]; then
        red "✗ contract integrity probe FAILED (exit ${probe_rc})"
        red "  Run: scripts/hooks/install.sh"
        red "  Then re-run this install-fresh."
        exit 2
    fi
elif [[ -x "${HOOK_BIN}" ]]; then
    set +e
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo a && ./gradlew test"}}' \
        | "${HOOK_BIN}" >/dev/null 2>&1
    probe_rc=$?
    set -e
    if [[ "${probe_rc}" -ne 2 ]]; then
        red "✗ v5 hook binary did not block compound bash (exit=${probe_rc})"
        red "  ${HOOK_BIN} is broken or has been modified."
        exit 2
    fi
fi

# ----- 0b. wipe any stale client-data seal ---------------------------------
#
# Client Data-Render Contract §7: any seal predating this install-fresh run
# is stale by definition. Wipe before we touch the simulator so that if
# install-fresh fails partway through, no valid seal is left behind for
# downstream tooling to trust.
assert_own_worktree_registered "before seal wipe" || exit 1
SEAL_PATH="${REPO_ROOT}/.claude/state/client-data-seal-ios.json"
if [[ -f "${SEAL_PATH}" ]]; then
    blue "+ wiping stale client-data seal at ${SEAL_PATH}"
    rm -f "${SEAL_PATH}"
fi

# ----- 1. locate simulator -------------------------------------------------

if ! command -v xcrun >/dev/null 2>&1; then
    red "✗ xcrun not found — Xcode command-line tools missing"
    exit 1
fi

resolve_udid() {
    local hint="$1"
    if [[ -z "${hint}" ]]; then
        # First pass: any currently booted simulator.
        local booted
        booted="$(xcrun simctl list devices booted -j 2>/dev/null | \
            /usr/bin/python3 -c "import json,sys
data=json.load(sys.stdin)
for runtime, devs in data.get('devices', {}).items():
    for d in devs:
        if d.get('state')=='Booted':
            print(d['udid']); sys.exit(0)" 2>/dev/null || true)"
        if [[ -n "${booted}" ]]; then
            echo "${booted}"
            return
        fi
        hint="${DEFAULT_DEVICE_NAME}"
    fi
    # If hint looks like a UDID (36 chars with dashes), use as-is.
    if [[ "${hint}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        echo "${hint}"
        return
    fi
    # Otherwise match by name — prefer Shutdown devices so we can boot fresh.
    xcrun simctl list devices available -j | /usr/bin/python3 -c "
import json, sys
name=sys.argv[1]
data=json.load(sys.stdin)
matches=[]
for runtime, devs in data.get('devices', {}).items():
    for d in devs:
        if d.get('name')==name and d.get('isAvailable', True):
            matches.append(d['udid'])
if matches:
    print(matches[0])
" "${hint}"
}

UDID="$(resolve_udid "${device_arg}")"
if [[ -z "${UDID}" ]]; then
    red "✗ could not resolve a simulator matching '${device_arg:-${DEFAULT_DEVICE_NAME}}'"
    xcrun simctl list devices available | sed -n '1,40p'
    exit 1
fi
blue "simulator UDID: ${UDID}"

# ----- 2. boot simulator if shutdown ---------------------------------------

STATE="$(xcrun simctl list devices -j | /usr/bin/python3 -c "
import json, sys
udid=sys.argv[1]
data=json.load(sys.stdin)
for runtime, devs in data.get('devices', {}).items():
    for d in devs:
        if d.get('udid')==udid:
            print(d.get('state','Unknown')); sys.exit(0)
" "${UDID}")"
blue "simulator state: ${STATE}"

if [[ "${STATE}" != "Booted" ]]; then
    run xcrun simctl boot "${UDID}"
    # Give SpringBoard time to settle so the subsequent install lands cleanly.
    sleep 5
fi

# ----- 3. erase (or uninstall) ---------------------------------------------

if [[ "${keep_data}" -eq 0 ]]; then
    # Full erase — clears Keychain, HealthKit samples, UserDefaults, SwiftData.
    # Simulator must be shutdown before erase; re-boot after.
    run xcrun simctl shutdown "${UDID}" || true
    run xcrun simctl erase "${UDID}"
    run xcrun simctl boot "${UDID}"
    sleep 5
else
    # Uninstall-only. Keychain persists — SignInView will be bypassed if a
    # prior JWT is cached. See feedback_ios_simulator_keychain_persists_uninstall.md.
    run xcrun simctl uninstall "${UDID}" "${BUNDLE_ID}" || true
fi

# ----- 4. build Debug for Simulator ----------------------------------------
#
# GOTCHA (learned the hard way): the Xcode project's own pre-build phase
# ("Stamp BUILD_SHA" in the XcodeGen project.yml / generated .pbxproj — not
# shown in this reference tier) overwrites BuildInfo.swift on every single
# `xcodebuild build`, including every run of this script. If BuildInfo.swift
# is TRACKED source, that overwrite leaves the working tree permanently
# dirty after every install-fresh run — which breaks worktree auto-cleanup
# and any "clean status" land gate. Fix it at the source: `git rm --cached`
# the generated file and gitignore it, so it becomes a true build output
# (mirror Android's gitignored, Gradle-generated BuildConfig — a
# `buildConfigField` never lands in git either). Do NOT "fix" this by having
# THIS script `git checkout --` the file afterward as a band-aid; untracking
# it at the project level is the root-cause fix and needs no cleanup step
# here at all.

cd "${REPO_ROOT}"
# Pass BUILD_SHA explicitly so the stamped SHA is exactly the one this run
# verified, regardless of what `git rev-parse` resolves inside the build
# environment. Without the override BuildInfo.swift could stamp "unknown"
# and the freshness verification at step 7 would exit 3.
run env BUILD_SHA="${EXPECTED_SHA}" xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -quiet \
    build

if [[ ! -d "${APP_PATH}" ]]; then
    red "✗ build did not produce ${APP_PATH}"
    exit 1
fi

# ----- 5. install ----------------------------------------------------------

run xcrun simctl install "${UDID}" "${APP_PATH}"

# ----- 6. launch + capture BUILD_SHA from syslog ---------------------------

# Truncate the syslog buffer before launch so our tail is deterministic.
# simctl doesn't expose a log-reset; we instead stream the log to a tmp file
# and filter by the launch timestamp.
TMP_LOG="$(mktemp -t example-ios-install-fresh.XXXXXX.log)"
trap 'rm -f "${TMP_LOG}"' EXIT

blue "+ streaming syslog to ${TMP_LOG}"
xcrun simctl spawn "${UDID}" log stream --predicate 'eventMessage CONTAINS "BUILD_SHA"' --style compact > "${TMP_LOG}" 2>&1 &
LOG_PID=$!
sleep 1

launch_args=(xcrun simctl launch "${UDID}" "${BUNDLE_ID}")
if [[ "${seed_healthkit}" -eq 1 ]]; then
    launch_args=(xcrun simctl launch --terminate-running-process --stdout="${TMP_LOG}.stdout" --stderr="${TMP_LOG}.stderr" "${UDID}" "${BUNDLE_ID}")
fi
run "${launch_args[@]}" || true

# Give the app time to run its init (BuildShaLogger.logAtLaunch fires very
# early — within ~1s on a modern Mac — but SwiftUI scene setup can stall
# the first NSLog flush).
sleep 6

kill "${LOG_PID}" 2>/dev/null || true
wait "${LOG_PID}" 2>/dev/null || true

blue "+ BUILD_SHA lines captured:"
grep -E 'BUILD_SHA=' "${TMP_LOG}" | tail -5 || true

OBSERVED_SHA="$(grep -oE 'BUILD_SHA=[0-9a-f]{12}' "${TMP_LOG}" | tail -1 | cut -d= -f2 || true)"

if [[ -z "${OBSERVED_SHA}" ]]; then
    red "✗ ios freshness FAIL — no BUILD_SHA in syslog, build is pre-contract"
    exit 3
fi

# ----- 7. compare ----------------------------------------------------------

if [[ "${OBSERVED_SHA}" != "${EXPECTED_SHA}" ]]; then
    red "✗ ios freshness FAIL — expected ${EXPECTED_SHA}, got ${OBSERVED_SHA}"
    exit 2
fi
green "✓ ios Simulator freshness-verified at ${OBSERVED_SHA}"

# ----- 7b. drive the HealthKit seeder + sign-in via XCUITest ---------------
#
# The simctl install above left a signed-out app with an empty HealthKit
# store. Home renders the Sign In screen; the Client Data-Render Contract
# adapter therefore reports cachePrimed=false and the contract is
# VIOLATED even though the SHA matches.
#
# scripts/ios-hk-seed.sh runs the ExampleAppUITests/HealthKitSeederE2EUITests
# XCUITest which signs in as client-e2e@example.com, taps the DEBUG-only
# seeder button inside Profile → Device & Health, accepts the HealthKit
# auth sheet, waits for the Seeded banner, returns to Home, and pull-to-
# refreshes. Post-test the app is left on Home with DashboardState hydrated
# from the newly-written HK samples — exactly the state the Android script
# reaches via force-stop + am start + HC_SYNC_WAIT_SECONDS sleep.
#
# Test-infra-only surface: the DEBUG seeder button and the
# HealthKitSeederE2EUITests target ship only in Debug builds.
HK_SEED_SCRIPT="${SCRIPT_DIR}/ios-hk-seed.sh"
if [[ -x "${HK_SEED_SCRIPT}" ]]; then
    set +e
    "${HK_SEED_SCRIPT}" --device "${UDID}"
    hk_rc=$?
    set -e
    case "${hk_rc}" in
        0)
            green "✓ HK seeded — Marcus HealthKit history live on simulator, Home hydrated"
            ;;
        1)
            red "✗ HK seeder script error (missing tool, sim gone, app uninstalled)"
            exit 2
            ;;
        2)
            red "✗ HK seeder XCUITest failed — sign-in or seeder banner did not complete"
            exit 2
            ;;
        3)
            red "✗ HK seeder green but today-readback did not match canonical"
            exit 2
            ;;
        *)
            red "✗ HK seeder returned unexpected exit ${hk_rc}"
            exit 2
            ;;
    esac
else
    printf '\033[33m⊘ scripts/ios-hk-seed.sh not present — skipping HK seed (client-data-check will VIOLATE)\033[0m\n'
fi

# ----- 7b.5 uninstall stray test-runner bundles ----------------------------
#
# `xcodebuild test` (via ios-hk-seed.sh) leaves the XCUITest runner app
# and the unit-test bundle installed on the Simulator home screen —
# visible as "ExampleAppUITes…" and "ExampleAppTests" icons with generic
# test-runner art that pollute the Simulator's SpringBoard. They have
# no runtime purpose after the test run completes. Uninstall them so
# the only Example icon the CEO sees on the home screen is the real
# ExampleApp. Silent failure is fine — `simctl uninstall` exits non-zero
# when the bundle isn't installed, which is a valid state if the HK
# seeder was skipped or the runner never installed on a stale sim.
blue "+ cleaning up stray XCUITest runner bundles from Simulator home screen"
xcrun simctl uninstall "${UDID}" com.example.app.uitests >/dev/null 2>&1 || true
xcrun simctl uninstall "${UDID}" com.example.app.tests   >/dev/null 2>&1 || true

# ----- 7c. cold-restart + bootstrap sync window ----------------------------
#
# XCUITest terminates the app-under-test on test teardown. After ios-hk-
# seed.sh returns the Simulator is signed in + HK-seeded but the app
# process is gone — `scripts/client-data-check.sh` therefore can't fire
# the `example-debug://home-state` URL handler (handler requires the app
# to be in foreground on Home). Without this step the adapter times out
# at 5s waiting for home-state.json and the contract check returns
# exit-2 even though everything upstream is correct.
#
# Mirror Android steps 10-11: cold-launch via `simctl launch`, then
# wait for:
#   (a) KeychainStorage → AuthRepository auto-sign-in (Keychain
#       persists HK-seed-run's JWT across app process death),
#   (b) RootViewModel → MainTabView → HomeView mount,
#   (c) DashboardBootstrapRunner hydrate from local SwiftData cache
#       (instant — cachePrimed flips true), and
#   (d) silent HK→Convex backfill resolve (parity with Android's
#       HC_SYNC_WAIT_SECONDS).
#
# Step (c) is fast but non-deterministic; (d) is the slow path (4 daily-
# activity rows + today's partial-day slice, each a Convex mutation).
# Empirically 8s covers (a)+(b)+(c) reliably, ~10-12s covers (d) on
# staging. Default 12s; overridable via IOS_COLD_RESTART_WAIT_SECONDS
# for fast iteration during development.

blue "+ cold-restarting signed-in app"
# terminate is idempotent — XCUITest's tearDown may have already killed
# the app, in which case simctl prints "found nothing to terminate" to
# stderr. Silencing keeps the install-fresh console clean; the subsequent
# simctl launch is the authoritative step.
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
run xcrun simctl launch "${UDID}" "${BUNDLE_ID}" >/dev/null

COLD_RESTART_WAIT_SECONDS="${IOS_COLD_RESTART_WAIT_SECONDS:-12}"
blue "+ waiting ${COLD_RESTART_WAIT_SECONDS}s for auto-sign-in + bootstrap + HK→Convex sync"
sleep "${COLD_RESTART_WAIT_SECONDS}"
green "✓ cold-restart + sync window elapsed — app should be on Home with canonical render"

# ----- 8. client-data render contract --------------------------------------
#
# See android-install-fresh.sh §9 for rationale. Identical policy on iOS:
# after SHA match, invoke scripts/client-data-check.sh ios <sha>. During
# adapter rollout exit-3 is a warning; once the iOS adapter lands, flip
# CLIENT_DATA_CONTRACT_ENFORCE=1 to make it hard-fail. Spec:
# docs/client-data-contract.md.

# Final zombie-path re-check: client-data-check.sh below mkdir's .claude/state/
# and writes the per-screen seal — the exact ghost-write the guard prevents.
assert_own_worktree_registered "before client-data seal write" || exit 1

CLIENT_DATA_CHECK="${SCRIPT_DIR}/client-data-check.sh"
if [[ -x "${CLIENT_DATA_CHECK}" ]]; then
    # Home surface — historical default. cachePrimed=true gates every
    # downstream comparison; any mismatch is a contract violation.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=home"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}"
    data_rc=$?
    set -e
    case "${data_rc}" in
        0)
            green "✓ ios client-data contract verified — Home renders canonical values"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (home)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data home adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data home adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (home) returned unexpected exit ${data_rc}"
            exit 2
            ;;
    esac

    # FoodLog surface — Sprint 2 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint2-foodlog.md §4 done criterion 2).
    # The food-log adapter reads via the `example-debug://food-log-state`
    # URL handler, which reads `container.foodLog.listByDate(todayKey())`.
    # FoodLog rows are hydrated as part of `DashboardBootstrapRunner`
    # (see DashboardBootstrapRunner.swift:122-133) so by the time the Home
    # check has passed, today's food logs are guaranteed in SwiftData
    # regardless of whether the FoodLog tab has been visited.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=food-log"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen food-log
    foodlog_rc=$?
    set -e
    case "${foodlog_rc}" in
        0)
            green "✓ ios client-data contract verified — FoodLog renders canonical totals (1540 kcal / 104g P / 143g C / 48g F / 3 rows / breakfast,lunch,dinner)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (food-log)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data food-log adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data food-log adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (food-log) returned unexpected exit ${foodlog_rc}"
            exit 2
            ;;
    esac

    # Pantry surface — Sprint 3 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint3-pantry.md §4 done criterion 2).
    # The pantry adapter reads via the `example-debug://pantry-state` URL
    # handler, which reads `container.pantry.listAll()`. Pantry rows are
    # NOT part of the DashboardBootstrapRunner critical path; they are
    # pulled by `PantryViewModel.init` Task on first read of the tab.
    # Today's bootstrap pulls pantryFoods at sign-in via the broader sync
    # service drain (see PantryFoodsRepository.swift:131-135 + bootstrap
    # entity order list), so by the time install-fresh's Home check has
    # passed, the canonical 5+3 split is guaranteed in SwiftData.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=pantry"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen pantry
    pantry_rc=$?
    set -e
    case "${pantry_rc}" in
        0)
            green "✓ ios client-data contract verified — Pantry renders canonical totals (itemsTotal=8 / tenantFoodCount=5 / personalFoodCount=3)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (pantry)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data pantry adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data pantry adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (pantry) returned unexpected exit ${pantry_rc}"
            exit 2
            ;;
    esac

    # Steps surface — Sprint 4 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint4-steps.md §4 done criterion 3).
    # The steps adapter reads via the `example-debug://steps-state` URL
    # handler, which projects DashboardRepository.state today's activity
    # plus a separately-counted recent-days history total. Today's
    # DailyActivityEntity row is hydrated as part of DashboardBootstrapRunner;
    # the 30-row history list is pulled separately via
    # DailyActivityRepository.pullFromConvex(userId, limit: 30) at
    # StepsViewModel.init's Task (StepsViewModel.swift:51-53). Recent-days
    # depth is a MIN check (>=14) per the seed-flex note at
    # canonical-values.sh:267.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=steps"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen steps
    steps_rc=$?
    set -e
    case "${steps_rc}" in
        0)
            green "✓ ios client-data contract verified — Steps renders canonical totals (todayStepCount=10500 / todayActiveKcal=472 / stepGoal=10000 / recentDaysCount>=14)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (steps)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data steps adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data steps adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (steps) returned unexpected exit ${steps_rc}"
            exit 2
            ;;
    esac

    # Trophies surface — Sprint 5 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint5-trophies.md §4 done criterion 3).
    # The trophies adapter reads via the `example-debug://trophies-state`
    # URL handler, which projects the full `TrophyProgressPayload` cached
    # by TrophiesRepository (server-side aggregator at
    # `example/convex/gamification/trophies.ts:82-` fans out across 16
    # source tables; client caches one JSON blob). Every numeric is a
    # MIN check, NOT EXACT — trophy earned-counts depend on runtime-
    # variable cron timing. See canonical-values.sh:317-348 for the
    # doctrine.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=trophies"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen trophies
    trophies_rc=$?
    set -e
    case "${trophies_rc}" in
        0)
            green "✓ ios client-data contract verified — Trophies renders >= MIN canonicals (trophyCount>=10 / mysterySlotCount>=1 / totalEarned/thisMonth/gold/inProgressCount>=0)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (trophies)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data trophies adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data trophies adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (trophies) returned unexpected exit ${trophies_rc}"
            exit 2
            ;;
    esac

    # Messages surface — Sprint 6 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint6-messages.md §4 done criterion 1).
    # The messages adapter reads via the `example-debug://messages-state`
    # URL handler, which projects MessagesRepository.listThreads() +
    # observeMessages() state. Like Trophies, Messages is intentionally
    # lazy: ThreadViewModel is constructed inside MessagesTabRoot.body
    # only after `await resolveThread()` resolves a conversationId. The
    # adapter therefore dispatches NavigateToMessagesTabUITests
    # synchronously before firing the URL (see ios-messages-state-
    # adapter.sh §3b) — install-fresh just invokes the dispatcher.
    # Asserts: 1 conversation row, coachName="Sarah Mitchell",
    # clientName="Marcus Chen", userMessageCount=12 (anchor),
    # selfMessageCount>=6 (bubble-alignment regression guard from the
    # 2026-04-24 CEO bug). schemaVersion=2 (bumped by bubble-alignment fix).
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=messages"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen messages
    messages_rc=$?
    set -e
    case "${messages_rc}" in
        0)
            green "✓ ios client-data contract verified — Messages renders canonical thread (1 conversation / Sarah Mitchell ↔ Marcus Chen / userMessageCount=12 / selfMessageCount>=6)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (messages)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data messages adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data messages adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (messages) returned unexpected exit ${messages_rc}"
            exit 2
            ;;
    esac

    # Leaderboard surface — Sprint 7 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint7-leaderboard.md §7 done criterion 4).
    # The leaderboard adapter reads via `example-debug://leaderboard-state`,
    # which projects LeaderboardRepository's weekly_logging cache slice.
    # Like Trophies/Messages, Leaderboard is intentionally lazy — but it
    # is a TWO-step lazy-mount: (1) tap Trophies tab; (2) tap "Leaderboard"
    # feature-nav card whose NavigationLink destination closure
    # (TrophiesView.swift:228) constructs LeaderboardViewModel. The
    # adapter therefore dispatches NavigateToLeaderboardUITests
    # synchronously before firing the URL (see ios-leaderboard-state-
    # adapter.sh §3b) — install-fresh just invokes the dispatcher.
    # Asserts: peerCount>=6 (5 seed peers + Marcus), mySelfRowPresent=true
    # (Marcus's own row must appear in the rankings — false is a real
    # regression). schemaVersion=1.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=leaderboard"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen leaderboard
    leaderboard_rc=$?
    set -e
    case "${leaderboard_rc}" in
        0)
            green "✓ ios client-data contract verified — Leaderboard renders canonical (peerCount>=6 / mySelfRowPresent=true / weekly_logging category)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (leaderboard)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data leaderboard adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data leaderboard adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (leaderboard) returned unexpected exit ${leaderboard_rc}"
            exit 2
            ;;
    esac

    # CheckIn surface — Sprint 8 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint8-checkin.md §4 done criterion 4).
    # The check-in adapter reads via `example-debug://check-in-state`,
    # which projects CheckInRepository.listAll() (server `checkIns:list`
    # query, capped at 20 rows). Like Trophies/Messages/Leaderboard,
    # CheckIn is intentionally lazy — and same TWO-step lazy-mount as
    # Leaderboard: (1) tap Trophies tab; (2) tap "Check-In" feature-nav
    # card whose NavigationLink destination closure
    # (TrophiesView.swift:233-236) constructs CheckInViewModel. The
    # adapter therefore dispatches NavigateToCheckInUITests synchronously
    # before firing the URL (see ios-check-in-state-adapter.sh §3b) —
    # install-fresh just invokes the dispatcher.
    # Asserts: cachePrimed=true (handler ran cleanly), currentWeekSubmitted
    # =true + historyCount>=17 (MIN per seedHeavyData.ts:661-702 — 17
    # weekly rows for clientIndex=0 → Marcus, +0-2 from prior tab-
    # navigation submits, all idempotent on (tenantId, userId, weekStart)
    # via `by_tenant_user_week`; see canonical-values.sh:218-251 for the
    # full doctrine and `qa-audits/ios-real-data/check-in/
    # sha-ef10924d-mark-diagnosis.md` for the seed-graph trace).
    # schemaVersion=1.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=check-in"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen check-in
    checkin_rc=$?
    set -e
    case "${checkin_rc}" in
        0)
            green "✓ ios client-data contract verified — Check-In renders canonical seed (currentWeekSubmitted=true / historyCount>=17 per seedHeavyData.ts:661-702)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (check-in)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data check-in adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data check-in adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (check-in) returned unexpected exit ${checkin_rc}"
            exit 2
            ;;
    esac

    # Challenges surface — Sprint 9 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint9-challenges.md §7 done criterion 5).
    # The challenges adapter reads via `example-debug://challenges-state`,
    # which projects ChallengesRepository.listAll() (server
    # `challenges/challenges:getActive` query with per-challenge
    # `Promise.all` enrichment that joins challengeParticipants for
    # isParticipating / myProgress / myCompleted / participantCount /
    # completedCount). Like Trophies/Messages/Leaderboard/CheckIn,
    # Challenges is intentionally lazy — same TWO-step lazy-mount as
    # Leaderboard + CheckIn: (1) tap Trophies tab; (2) tap "Challenges"
    # feature-nav card whose NavigationLink destination closure
    # (TrophiesView.swift:220-224) constructs ChallengesViewModel. The
    # adapter therefore dispatches NavigateToChallengesUITests
    # synchronously before firing the URL (see ios-challenges-state-
    # adapter.sh §3b) — install-fresh just invokes the dispatcher.
    # Asserts: cachePrimed=true, totalCount=1 (one active "7-Day Step
    # Surge"), activeCoachSurgePresent=true, Marcus's myRow at rank-2
    # canonical (myProgress=49000 / targetValue=70000 / xpReward=300 /
    # participantCount>=6 MIN per seedE2E.ts:1490 + seedHeavyData.ts:
    # 316-393 peers — observed 25 on fully seeded staging /
    # completedCount=2 EXACT). schemaVersion=1.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=challenges"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen challenges
    challenges_rc=$?
    set -e
    case "${challenges_rc}" in
        0)
            green "✓ ios client-data contract verified — Challenges renders canonical (totalCount=1 / 7-Day Step Surge active / Marcus rank-2 myProgress=49000 / participantCount>=6 per seedE2E + seedHeavyData)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (challenges)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data challenges adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data challenges adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (challenges) returned unexpected exit ${challenges_rc}"
            exit 2
            ;;
    esac

    # HealthSync surface — Sprint 10 of the iOS real-data wiring plan
    # (docs/ios-real-data-wiring-sprint10-healthsync.md §11 done criterion 2).
    # The healthsync adapter reads via `example-debug://healthsync-state`,
    # which projects HealthKitRepository.isAnyAuthorizationRequested() +
    # HKHealthStore.isHealthDataAvailable() — pure local HK system probe
    # against the SINGLETON repository (NOT a tab-mounted ViewModel).
    # NO Navigate-to-tab XCUITest required: the HK seeder dispatch above
    # (ios-hk-seed.sh at line ~324) already grants HK authorization for
    # the 5 read types via Profile → Device & Health → Connect Health,
    # which flips `isAnyAuthorizationRequested()` true on the singleton.
    # CRITICAL ORDERING: this --screen invocation MUST run AFTER the HK
    # seeder dispatch above; placing it earlier (e.g. before the seeder)
    # would read isConnected=false because authorization hasn't been
    # granted yet. Asserts: isConnected=true, isHealthDataAvailable=true
    # (true on every modern Simulator), schemaVersion=1.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=healthsync"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen healthsync
    healthsync_rc=$?
    set -e
    case "${healthsync_rc}" in
        0)
            green "✓ ios client-data contract verified — HealthSync renders canonical (isConnected=true / isHealthDataAvailable=true)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (healthsync)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data healthsync adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data healthsync adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (healthsync) returned unexpected exit ${healthsync_rc}"
            exit 2
            ;;
    esac

    # Profile (Settings) surface — Sprint 11 of the iOS real-data wiring
    # plan (docs/ios-real-data-wiring-sprint11-settings.md §11 done
    # criterion 3). iOS Profile-tab IS Settings inline (CEO 2026-04-21
    # rule), so this single invocation covers both surfaces. The profile
    # adapter reads via `example-debug://profile-state`, which projects
    # DashboardRepository.state.profile (singleton, hydrated by
    # DashboardBootstrapRunner during cold-bootstrap) +
    # HealthKitRepository.isAnyAuthorizationRequested() (same singleton
    # HealthSync reads) + BuildInfo.sha (compile-time stamp). NO
    # Navigate-to-tab XCUITest required — same singleton-reads-no-VM
    # pattern as Sprint 10 HealthSync.
    # CRITICAL ORDERING: this --screen invocation MUST run AFTER the HK
    # seeder dispatch above (same as HealthSync); placing it earlier
    # would read healthKitConnected=false because authorization hasn't
    # been granted yet. Asserts: displayName="Marcus Chen",
    # dayNumber=14, healthKitConnected=true (post-seeder),
    # buildSha=$EXPECTED_SHA (dynamic per-run), schemaVersion=1.
    blue "+ ${CLIENT_DATA_CHECK} ios ${EXPECTED_SHA}  (seal device=${UDID}) screen=profile"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${UDID}" \
        "${CLIENT_DATA_CHECK}" ios "${EXPECTED_SHA}" --screen profile
    profile_rc=$?
    set -e
    case "${profile_rc}" in
        0)
            green "✓ ios client-data contract verified — Profile renders canonical (Marcus Chen / day 14 / HK connected / buildSha matches expected)"
            ;;
        2)
            red "✗ CLIENT DATA CONTRACT VIOLATED on ios (profile)"
            red "  Install-fresh refuses to report success. See diff above."
            exit 2
            ;;
        3)
            if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
                red "✗ client-data profile adapter missing and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
                exit 2
            fi
            printf '\033[33m⊘ ios client-data profile adapter not landed yet — skipping contract check (rollout phase)\033[0m\n'
            ;;
        *)
            red "✗ client-data-check.sh (profile) returned unexpected exit ${profile_rc}"
            exit 2
            ;;
    esac
else
    printf '\033[33m⊘ client-data-check.sh not present — skipping contract check\033[0m\n'
fi

# ----- 9. seed-healthkit reminder (optional) -------------------------------

if [[ "${seed_healthkit}" -eq 1 ]]; then
    echo ""
    blue "NEXT STEP — seed Marcus's HealthKit history:"
    echo "  1. Sign in as client-e2e@example.com / <TEST_PASSWORD> in the Simulator."
    echo "  2. Profile → Device & Health → tap 'Seed HealthKit (Marcus — DEBUG)'."
    echo "  3. Accept the HealthKit share/read prompt (Turn On All → Allow)."
    echo "  4. Return to Home — today's steps, weekly leaderboard, and streak"
    echo "     should populate within seconds."
    echo ""
    echo "  The seeder is DEBUG-only, idempotent, and safe to re-run."
fi
exit 0
