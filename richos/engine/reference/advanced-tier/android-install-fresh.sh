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
# android-install-fresh.sh — nuke / build / install / ground-truth verify
#
# Part of the freshness contract (docs/freshness-contract.md). This is the
# only sanctioned way to put a fresh Example staging APK onto an attached
# device. It refuses to report success unless the on-device BuildConfig.GIT_SHA
# matches the expected commit hash.
#
# Usage:
#   scripts/android-install-fresh.sh [--device <serial>] [<expected-sha>]
#
# Arguments:
#   expected-sha  The 12-char commit hash the installed APK MUST report.
#                 Defaults to `git rev-parse --short=12 HEAD` when omitted.
#
# Options:
#   --device <serial>  adb device serial. Takes precedence over ANDROID_SERIAL.
#
# Environment variables:
#   ANDROID_SERIAL     adb device serial, used when --device is not given.
#                      Standard adb convention; matches android-login.sh.
#
# Exit codes:
#   0  install verified — on-device BUILD_SHA matches expected
#   1  script error (missing tool, build failure, no device, etc.)
#   2  freshness MISMATCH — APK reports a different SHA than expected
#   3  no BUILD_SHA line in logcat — APK predates the freshness contract

set -euo pipefail

PKG="com.example.app.staging"
APK_PATH="example/android/app/build/outputs/apk/staging/app-staging.apk"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

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

# Parse --device flag. Any remaining positional arg is the expected SHA.
# Argument precedence for serial: --device <serial> > ANDROID_SERIAL env > none.
# If neither is provided, we fall back to the attached-device heuristic so
# single-device setups keep working without extra flags.
serial=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) serial="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- "${positional[@]:-}"

if [[ -z "${serial}" && -n "${ANDROID_SERIAL:-}" ]]; then
  serial="${ANDROID_SERIAL}"
fi

# Export ANDROID_SERIAL so every downstream `adb`, `./gradlew :app:install*`,
# and helper subshell picks up the same target without per-call -s plumbing.
if [[ -n "${serial}" ]]; then
  export ANDROID_SERIAL="${serial}"
fi

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

run() {
  blue "+ $*"
  "$@"
}

# ----- 0. resolve expected SHA --------------------------------------------------

EXPECTED_SHA="${1:-}"
if [[ -z "${EXPECTED_SHA}" ]]; then
  if ! EXPECTED_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null)"; then
    red "✗ could not resolve default expected SHA via git rev-parse --short=12 HEAD"
    exit 1
  fi
fi

if [[ ${#EXPECTED_SHA} -ne 12 ]]; then
  red "✗ expected-sha must be exactly 12 chars (got ${#EXPECTED_SHA}: '${EXPECTED_SHA}')"
  exit 1
fi

blue "expected SHA: ${EXPECTED_SHA}"

# ----- 0a. v5 HIGH-5 — contract integrity probe --------------------------------
#
# Frank F-4: the §7 Bash hook lives in `.claude/settings.json` which is
# gitignored. If the operator never ran `scripts/hooks/install.sh` (or
# ran it and then deleted the file), Claude Code's tool-call channel
# has no Bash gate at all — install-fresh would mint a seal that QA
# trusts even though every test channel is wide open.
#
# Check 1 — verify `.claude/settings.json` exists and wires both the
# Bash + Agent hooks to the v5 scripts. Without this, Claude Code's
# tool plane never invokes the hooks no matter how well they work
# locally.
#
# Check 2 — sanity-execute the local hook binary on a known-bad input
# to confirm the regex/python machinery still rejects what it should.
# Catches the rare case where the hook file itself has been edited
# into a no-op.
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
  # Fallback: integrity-probe script not present (older checkout).
  # Sanity-execute the hook on a compound-bash input (seal-state-
  # independent: HIGH-1 REJECTS regardless of valid seals).
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

# ----- 0b. wipe any stale client-data seal -------------------------------------
#
# Client Data-Render Contract §7: any seal predating this install-fresh run
# is stale by definition. Wipe before we touch the device so that if
# install-fresh fails partway through, no valid seal is left behind for
# downstream tooling to trust.
assert_own_worktree_registered "before seal wipe" || exit 1
SEAL_PATH="${REPO_ROOT}/.claude/state/client-data-seal-android.json"
if [[ -f "${SEAL_PATH}" ]]; then
  blue "+ wiping stale client-data seal at ${SEAL_PATH}"
  rm -f "${SEAL_PATH}"
fi

# ----- 1. verify adb device connected ------------------------------------------

if ! command -v adb >/dev/null 2>&1; then
  red "✗ adb not found in PATH"
  exit 1
fi

DEVICE_LINES="$(adb devices | tail -n +2 | grep -E 'device$' || true)"
if [[ -z "${DEVICE_LINES}" ]]; then
  red "✗ no adb device connected. adb devices output:"
  adb devices
  exit 1
fi

DEVICE_COUNT="$(printf '%s\n' "${DEVICE_LINES}" | wc -l | tr -d ' ')"

# Multi-device safety: if more than one device is attached and no serial was
# specified, bail out rather than silently acting on whichever device adb
# picks. This matches android-login.sh's explicit handling and avoids the
# "ran against the wrong device" class of bug during QA sprints.
if [[ "${DEVICE_COUNT}" -gt 1 && -z "${serial:-}" ]]; then
  red "✗ ${DEVICE_COUNT} devices attached and no --device / ANDROID_SERIAL given. Specify one."
  adb devices >&2
  exit 1
fi

# If a serial was requested, verify it's actually attached and in 'device' state.
if [[ -n "${serial:-}" ]]; then
  if ! printf '%s\n' "${DEVICE_LINES}" | awk '{print $1}' | grep -qx "${serial}"; then
    red "✗ device '${serial}' is not connected or not in 'device' state"
    adb devices >&2
    exit 1
  fi
fi

blue "adb devices ready: ${DEVICE_COUNT}${serial:+  (targeting ${serial})}"

# ----- 2. force-stop the app ---------------------------------------------------

run adb shell am force-stop "${PKG}" || true

# ----- 3. uninstall (ignore "not installed") -----------------------------------

blue "+ adb uninstall ${PKG}"
adb uninstall "${PKG}" >/dev/null 2>&1 || true

# ----- 4. assemble fresh staging APK -------------------------------------------

cd "${REPO_ROOT}/example/android"
run ./gradlew :app:assembleStaging
cd "${REPO_ROOT}"

if [[ ! -f "${APK_PATH}" ]]; then
  red "✗ build did not produce ${APK_PATH}"
  exit 1
fi

# ----- 5. install ----------------------------------------------------------------

run adb install -r "${APK_PATH}"

# ----- 5b. pre-grant runtime permissions so nothing blocks the cold launch ----
#
# Android pops a POST_NOTIFICATIONS runtime-permission dialog on first launch
# of a freshly-installed app. That dialog is owned by
# com.google.android.permissioncontroller and sits on top of Example's task —
# when we then run `am start`, Android delivers the intent to the task whose
# top-most activity is the dialog, so ExampleApp's process never actually
# starts and the BUILD_SHA log never fires. Result: this script thinks the
# APK is "pre-contract" and exits 3, even though the build is fine.
#
# Fix: pre-grant the runtime permissions before the cold launch. This is the
# same technique scripts/android-login.sh uses for the same reason. Grants
# after install are idempotent and cheap.
run adb shell pm grant "${PKG}" android.permission.POST_NOTIFICATIONS || true

# Also dismiss any lingering permission dialog from a prior run by backing out
# of it twice. Cheap, idempotent, and no-op when no dialog is present.
adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true

# Kill the permission controller process too — if the dialog is still holding
# the foreground task even after our BACK presses, this forces it off so our
# am start actually lands on Example's MainActivity and not on the dialog.
adb shell am force-stop com.google.android.permissioncontroller >/dev/null 2>&1 || true

# Force-stop Example one more time post-grant to guarantee the next am start
# creates a fresh process (and therefore runs ExampleApp.onCreate and logs
# BUILD_SHA).
run adb shell am force-stop "${PKG}" || true

# ----- 6. clear logcat then cold-launch ----------------------------------------

run adb logcat -c
run adb shell am start -n "${PKG}/com.example.app.MainActivity"

# ----- 7. poll logcat for BUILD_SHA --------------------------------------------
#
# Hilt + Compose cold-init can take anywhere from ~3s on a warm device to 40+s
# on a cold emulator before Application.onCreate() body runs and emits
# BUILD_SHA. A fixed sleep is the wrong shape: it's either too short (false
# exit 3 on slow emulators — verified on emulator-5554 at +40.8s) or wastes
# time on fast devices. Instead, poll live logcat and return as soon as a
# BUILD_SHA line appears, capped at BUILD_SHA_WAIT_SECONDS (default 60).

WAIT_SECONDS="${BUILD_SHA_WAIT_SECONDS:-60}"
blue "+ polling logcat for BUILD_SHA (cap: ${WAIT_SECONDS}s)"

OBSERVED_SHA=""
LOGCAT_LINE=""
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while [[ $(date +%s) -lt ${deadline} ]]; do
  LOGCAT_LINE="$(adb logcat -d -s BUILD_SHA:I 2>/dev/null | grep -E 'BUILD_SHA' | tail -1 || true)"
  if [[ -n "${LOGCAT_LINE}" ]]; then
    OBSERVED_SHA="$(printf '%s\n' "${LOGCAT_LINE}" \
      | grep -oE '[A-Za-z0-9-]{12}' \
      | tail -1 || true)"
    if [[ -n "${OBSERVED_SHA}" ]]; then
      break
    fi
  fi
  sleep 1
done

printf '%s\n' "${LOGCAT_LINE}"

if [[ -z "${OBSERVED_SHA}" ]]; then
  red "✗ android freshness FAIL — no BUILD_SHA in logcat after ${WAIT_SECONDS}s, build is pre-contract"
  exit 3
fi

# ----- 8. compare ---------------------------------------------------------------

if [[ "${OBSERVED_SHA}" != "${EXPECTED_SHA}" ]]; then
  red "✗ android freshness FAIL — expected ${EXPECTED_SHA}, got ${OBSERVED_SHA}"
  exit 2
fi
green "✓ android APK freshness-verified at ${OBSERVED_SHA}"

# ----- 8b. seed Health Connect ------------------------------------------------
#
# Example's HomeView reads steps / active calories / heart rate from
# Health Connect on-device, NOT from Convex (see
# docs/testing/seed-system-architecture.md). A fresh emulator has an
# empty HC store, so Home sits on "Syncing with Health Connect..."
# indefinitely and the client-data-check below returns null for
# steps/activeKcal — client-data adapters can't produce canonical
# values when HC itself is empty.
#
# scripts/android-hc-seed.sh grants the debug-manifest HC
# permissions and fires the HcSeederReceiver broadcast
# (com.example.app.debug.SEED_HC), which writes Marcus-canonical
# step/calorie/HR history into HC. The seeder reports SEED_COMPLETE
# to logcat; we trust the exit code, not the marker.
#
# Scope: this seeding step is emulator/debug-only. The debug receiver
# is merged into both debug and staging build types (not release),
# and the broadcast action is namespaced to com.example.app.debug.
# Release builds lack the receiver AND the WRITE perms, so this
# invocation is structurally safe against a release APK — pm-grant
# would fail silently and the broadcast would no-op.
HC_SEED_SCRIPT="${SCRIPT_DIR}/android-hc-seed.sh"
if [[ -x "${HC_SEED_SCRIPT}" ]]; then
  # Canonical defaults (days, stepsPerDay) come from canonical-values.sh
  # inside the seeder; no args needed. Serial passthrough is handled via
  # ANDROID_SERIAL which is already set above when --device is given.
  set +e
  "${HC_SEED_SCRIPT}"
  hc_rc=$?
  set -e
  case "${hc_rc}" in
    0)
      green "✓ Health Connect seeded — Marcus step/activity history live on emulator"
      ;;
    1)
      red "✗ HC seeder script error (adb / APK / permission grant failure)"
      red "  The client-data-check below will report MISSING on steps/activeKcal."
      red "  Fix the adb state or rerun install-fresh on a known-good emulator."
      exit 2
      ;;
    2)
      red "✗ HC seeder receiver failed or timed out without SEED_COMPLETE"
      red "  Check logcat -s HcSeeder for SEED_FAILED reason=..."
      exit 2
      ;;
    3)
      red "✗ HC seeder reported SEED_COMPLETE but todayReadback was 0"
      red "  HC silently no-op'd the insert — usually means the debug HC"
      red "  WRITE permission grant didn't stick. Re-run install-fresh."
      exit 2
      ;;
    *)
      red "✗ HC seeder returned unexpected exit ${hc_rc}"
      exit 2
      ;;
  esac
else
  printf '\033[33m⊘ scripts/android-hc-seed.sh not present — skipping HC seed (client-data-check may SKIP on steps/activeKcal)\033[0m\n'
fi

# ----- 8c. sign in as the client E2E account ----------------------------------
#
# The APK install at step 5 created a fresh, signed-out app state. Home
# renders the Sign In screen with cachePrimed=false; the Client
# Data-Render Contract adapter reads sentinel nulls and reports
# CONTRACT VIOLATED. Every install-fresh for QA/parity work needs a
# real signed-in Marcus session before client-data-check can exit 0.
#
# scripts/android-login.sh force-stops, `pm clear`s the app, grants
# POST_NOTIFICATIONS, launches MainActivity, types the canonical
# staging client creds, and polls the UI for the post-login Home. It
# reads credentials from $EXAMPLE_STAGING_CLIENT_EMAIL / _PASSWORD or
# $HOME/.example/staging-creds — no hardcoded secrets.
#
# NOTE: `pm clear` inside android-login.sh wipes app data INCLUDING
# the HC permission grants and the app's HC read state. The records
# we wrote at step 8b above REMAIN in the system HC datastore (HC is
# system-level, not per-app), but the app has to re-grant READ perms
# before it can see them. That's why step 8d below re-fires the HC
# seeder — its pm-grant arm re-establishes read perms, and its
# delete-then-insert idempotency ensures the records are still there.
LOGIN_SCRIPT="${SCRIPT_DIR}/android-login.sh"
if [[ -x "${LOGIN_SCRIPT}" ]]; then
  blue "+ signing in as client E2E account"
  set +e
  "${LOGIN_SCRIPT}"
  login_rc=$?
  set -e
  if [[ "${login_rc}" -ne 0 ]]; then
    red "✗ android-login.sh returned exit ${login_rc}"
    red "  Common causes: creds missing ($HOME/.example/staging-creds or env vars),"
    red "  emulator UI hung, or staging auth endpoint unreachable."
    red "  Install-fresh refuses to proceed without sign-in — the client-data"
    red "  contract cannot be verified on a signed-out app."
    exit 2
  fi
  green "✓ signed in"
else
  printf '\033[33m⊘ scripts/android-login.sh not present — skipping sign-in (client-data-check will VIOLATE on signed-out app)\033[0m\n'
fi

# ----- 8d. re-fire HC seeder (login wiped HC grants) -------------------------
#
# android-login.sh ran `pm clear` which dropped HC permissions.
# Re-invoke the HC seeder to re-grant + re-insert (idempotent). The
# records written at step 8b still exist in the system HC datastore;
# this run delete-then-re-inserts in the same time ranges, and —
# critically — re-grants the READ_* perms the app needs to query HC
# in step 8e's cold-restart refresh.
if [[ -x "${HC_SEED_SCRIPT}" ]]; then
  blue "+ re-seeding HC (login cleared permissions)"
  set +e
  "${HC_SEED_SCRIPT}"
  hc_reseed_rc=$?
  set -e
  case "${hc_reseed_rc}" in
    0)
      green "✓ HC re-seeded — Marcus data visible to signed-in app"
      ;;
    1)
      red "✗ HC re-seed script error — post-login adb state is broken"
      exit 2
      ;;
    2)
      red "✗ HC re-seed receiver failed or timed out"
      red "  Check logcat -s HcSeeder for SEED_FAILED reason=..."
      exit 2
      ;;
    3)
      red "✗ HC re-seed reported SEED_COMPLETE but todayReadback was 0"
      red "  Post-login HC WRITE grant didn't stick."
      exit 2
      ;;
    *)
      red "✗ HC re-seed returned unexpected exit ${hc_reseed_rc}"
      exit 2
      ;;
  esac
# No `else` branch — already warned at step 8b that the seeder is missing.
fi

# ----- 8e. cold-restart + HC→Convex sync wait --------------------------------
#
# The signed-in app reads HC only on resume/refresh. Without a fresh
# process boot, the Room cache from before the HC re-seed is still
# what Home renders. Force-stop + am start triggers
# ExampleApp.onCreate → HomeViewModel init → refresh chain, which pulls
# HC and pushes to Convex via dailyActivity:syncActivity. The sync
# itself is async; empirically ~8s covers the 4 daily-activity rows
# + today's partial-day slice on a mid-range emulator.
#
# No sync-done signal exists today (candidate for a future
# observability sprint). Fixed 10s is conservative and documented.
blue "+ cold-restarting signed-in app"
run adb shell am force-stop "${PKG}"
run adb shell am start -n "${PKG}/com.example.app.MainActivity" >/dev/null

HC_SYNC_WAIT_SECONDS="${HC_SYNC_WAIT_SECONDS:-10}"
blue "+ waiting ${HC_SYNC_WAIT_SECONDS}s for HC→Convex sync"
sleep "${HC_SYNC_WAIT_SECONDS}"
green "✓ sync window elapsed"

# ----- 9. client-data render contract ------------------------------------------
#
# SHA match is necessary but not sufficient. The right bytes on the device
# still render zeros if the client isn't reading canonical seeded data. The
# Client Data-Render Contract (docs/client-data-contract.md) asserts every
# canonical Marcus value on every covered client screen matches the SSOT
# (scripts/client-data/canonical-values.sh). Install-fresh is the enforcement
# point: a fresh install is only "successful" when BOTH the SHA matches AND
# the seeded app state renders canonically across the full screen set.
#
# During the adapter-rollout phase the check returns exit-3 (adapter missing)
# which we treat as a warning. Once both Android and iOS adapters land, set
# CLIENT_DATA_CONTRACT_ENFORCE=1 to promote exit-3 to HARD FAIL.

# Final zombie-path re-check: client-data-check.sh below mkdir's .claude/state/
# and writes the per-screen seal — the exact ghost-write the guard prevents.
assert_own_worktree_registered "before client-data seal write" || exit 1

CLIENT_DATA_CHECK="${SCRIPT_DIR}/client-data-check.sh"
if [[ -x "${CLIENT_DATA_CHECK}" ]]; then
  # Resolve the device serial for the seal forensics payload. adb's
  # `get-serialno` returns the active serial when ANDROID_SERIAL is set.
  SEAL_DEVICE_ID="$(adb get-serialno 2>/dev/null || echo "unknown")"
  CLIENT_DATA_SCREENS=(
    home
    food-log
    pantry
    messages
    steps
    trophies
    leaderboard
    check-in
    challenges
    healthsync
    profile
  )

  for screen in "${CLIENT_DATA_SCREENS[@]}"; do
    blue "+ ${CLIENT_DATA_CHECK} android ${EXPECTED_SHA} --screen ${screen}  (seal device=${SEAL_DEVICE_ID})"
    set +e
    CLIENT_DATA_SEAL_DEVICE_ID="${SEAL_DEVICE_ID}" \
      "${CLIENT_DATA_CHECK}" android "${EXPECTED_SHA}" --screen "${screen}"
    data_rc=$?
    set -e
    case "${data_rc}" in
      0)
        green "✓ android client-data contract verified — ${screen} renders canonical values"
        ;;
      2)
        red "✗ CLIENT DATA CONTRACT VIOLATED on android screen=${screen}"
        red "  Install-fresh refuses to report success. See diff above."
        exit 2
        ;;
      3)
        if [[ "${CLIENT_DATA_CONTRACT_ENFORCE:-0}" == "1" ]]; then
          red "✗ client-data adapter missing for screen=${screen} and CLIENT_DATA_CONTRACT_ENFORCE=1 — hard fail"
          exit 2
        fi
        printf '\033[33m⊘ android client-data adapter missing for screen=%s — skipping remaining full-screen contract checks (rollout phase)\033[0m\n' "${screen}"
        exit 0
        ;;
      *)
        red "✗ client-data-check.sh returned unexpected exit ${data_rc} for screen=${screen}"
        exit 2
        ;;
    esac
  done

  green "✓ android client-data contract verified across all covered screens"
  exit 0
else
  printf '\033[33m⊘ client-data-check.sh not present — skipping contract check\033[0m\n'
  exit 0
fi
