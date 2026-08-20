# shellcheck shell=sh
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
# canonical-values.sh — single source of truth for every value Marcus's
# seeded staging account must render on Home (today) across Android, iOS,
# and the server-side seed.
#
# THIS FILE IS POSIX SH SOURCEABLE. No bashisms. No arrays. Every value is
# a plain `KEY=value` export (or a documented derivation rule). Sources:
#
#   - Convex seed:           example/convex/seedE2E.ts
#   - Android HC seeder:     example/android/app/src/debug/java/com/example/app/debug/HcSeederReceiver.kt
#   - Android Home projection: example/android/app/src/main/java/com/example/app/data/dashboard/DashboardRepository.kt
#   - iOS Home projection:   example/ios/ExampleApp/Features/Home/...
#
# Four categories of value:
#
#   1. STATIC — fixed constants. Seeds and clients must agree byte-for-byte.
#   2. DERIVED_TODAY — depends on wall-clock date. Documented as a rule.
#   3. DERIVED_FROM_PROFILE — depends on server-side state (createdAt, XP curve)
#      that callers resolve from live server queries, not from this file.
#   4. NONCANONICAL — values that vary per-seed (_id, authId, timestamps).
#      Listed so the verifier knows NOT to assert them.
#
# Every consumer (Convex seed, HC seeder, iOS HealthKit seeder, the client-
# data verifier, the V7 hook) sources this file. Hardcoded duplicates of
# any CANONICAL_* constant outside this file are a violation flagged by
# scripts/hooks/lint-canonical-literals.sh.
#
# CLIENT — identifies the test user Home is being verified for.
# --------------------------------------------------------------
CANONICAL_CLIENT_EMAIL="client-e2e@example.com"
CANONICAL_CLIENT_DISPLAY_NAME="Marcus Chen"
CANONICAL_CLIENT_FIRST_NAME="Marcus"

# Program metadata — pinned at seedE2E.ts:248-250.
# --------------------------------------------------------------
CANONICAL_PROGRAM_DURATION_MONTHS="3"
CANONICAL_WEIGHT_LOSS_TARGET_LBS="10"
# Program start-date offset (days before now) at seed time.
CANONICAL_PROGRAM_START_DAYS_AGO="42"

# Marcus's journey anchor (UTC-day offset from today). The seed re-anchors
# users.createdAt to `todayUtcStart - CANONICAL_MARCUS_CREATED_AT_DAYS_AGO
# days` on EVERY run so dayNumber is time-invariant. Without this anchor,
# dayNumber drifts upward by one every UTC midnight. See
# seedE2E.ts:setupE2EAccounts and docs/client-data-contract.md.
CANONICAL_MARCUS_CREATED_AT_DAYS_AGO="13"
CANONICAL_DAY_NUMBER="14"

# Activity targets — seedE2E profile defaults + Home projection fallbacks.
# --------------------------------------------------------------
CANONICAL_STEP_GOAL="10000"
CANONICAL_TARGET_CALORIES="2000"
CANONICAL_TARGET_PROTEIN_G="150"

# Canonical day-key timezone contract (docs/client-data-contract.md →
# "Canonical day-key timezone contract"). The seed keys "today" under the
# LOCAL civil day of this test-clock offset and stamps it onto Marcus's
# users.timeZone/tzOffsetMinutes, so coach reads + verify + probe resolve the
# SAME day the seed wrote. DEFAULT is UTC (offset 0) — identical to the
# historical UTC keying — so a normal deploy is unchanged; the P0-3 acceptance
# run overrides both via seedE2E:run args to match a non-UTC device clock.
# TS mirror: example/convex/canonicalValues.ts.
CANONICAL_SEED_TZ_OFFSET_MINUTES="0"
CANONICAL_SEED_TIME_ZONE="UTC"

# Today's activity — what Home must render in the "Steps" tile etc.
# --------------------------------------------------------------
# Nominal full-day steps for Marcus (ratio 1.05 of 10k baseline).
CANONICAL_TODAY_STEP_COUNT="10500"
# Active calories derivation: stepCount * 0.045 kcal/step (seeder rule).
# Today: 10500 * 0.045 = 472.5.
#
# Both platforms emit the INTEGER part — Android via `Double.toInt()`
# in example/android/app/src/main/java/com/example/app/debug/
# HomeStateSnapshot.kt:81, iOS via `Int($0)` in example/ios/ExampleApp/
# UI/Screens/Home/HomeStateSnapshot.swift:91. Swift `Int(Double)` and
# Kotlin `Double.toInt()` both TRUNCATE toward zero (not round-half-
# up, not round-half-to-even). 472.5 → 472 on both platforms. No
# platform divergence; parity is preserved because both conversions
# use the same truncation semantics.
#
# (The v1 comment here claimed 473 on the assumption of round-half-up.
#  Kotlin `Math.round` is round-half-to-even for .5, and `Double.toInt`
#  is truncation — neither produces 473 from 472.5.)
CANONICAL_TODAY_ACTIVE_KCAL="472"
# Total calories = active + basal (1650 kcal). Same truncation applies:
# 472.5 + 1650.0 = 2122.5 → .toInt()/Int() → 2122. Not on the v1 adapter
# surface today; kept here for canonical cross-reference.
CANONICAL_TODAY_TOTAL_KCAL="2122"
# Resting heart rate — fixed 62 bpm across all seeded days (HcSeederReceiver
# line 260; iOS seeder must match).
CANONICAL_TODAY_RESTING_HR="62"

# Weight — latest sample at seedLeaderboardPeers.
# --------------------------------------------------------------
CANONICAL_TODAY_WEIGHT_KG="84.2"

# XP / Level — Marcus is lifted to Level 7 (Silver tier +2) at 4500 XP
# server-side. The XP surface has a visibility split enforced by
# `xp:getUserXP` (example/convex/gamification/xp.ts:240): when the tenant
# has `xpInvisibleToClients` set (default true), the client response
# HIDES raw XP totals and the remaining-XP-to-next-level, exposing only
# `currentLevel`, `progressPercent`, and `rank`. Two parallel constant
# families reflect this:
#
#   CANONICAL_* — what a CLIENT adapter observes from Home (AFTER
#                 visibility filtering). These are the values
#                 client-data-check.sh compares against.
#   SERVER_*    — the RAW server row (userXP table) values, checked by
#                 seedE2E:verify running as internalQuery (admin
#                 context, no client hiding). Used for seeding.
#
# Derivation against LEVEL_THRESHOLDS in example/convex/gamification/
# levels.ts:17-48 (array is 0-indexed; Level N lives at index N-1):
#   thresholds[5]=2500 (Level 6); thresholds[6]=4000 (Level 7);
#   thresholds[7]=5500 (Level 8).
# For Marcus at totalXP=4500, currentLevel=7:
#   progressIntoLevel = 4500 - 4000 = 500
#   bandSize          = 5500 - 4000 = 1500
#   xpToNextLevel     = 5500 - 4500 = 1000        (server raw)
#   progressPercent   = round(500 / 1500 * 100) = 33
# Clients see `totalXP` and `xpToNextLevel` as `undefined`; adapters
# emit 0 for the null (hence CANONICAL_* = 0 on those two fields).
# --------------------------------------------------------------
CANONICAL_MARCUS_LEVEL="7"
CANONICAL_MARCUS_TOTAL_XP="0"
CANONICAL_MARCUS_XP_TO_NEXT_LEVEL="0"
CANONICAL_MARCUS_XP_PROGRESS_PERCENT="33"

# Server-side raw values — asserted by seedE2E:verify (admin context).
SERVER_MARCUS_TOTAL_XP="4500"
SERVER_MARCUS_XP_TO_NEXT_LEVEL="1000"

# Food logs for today (seedE2E line 700-703 et al).
# --------------------------------------------------------------
CANONICAL_TODAY_FOOD_LOG_COUNT_MIN="3"

# Today's food-log canonical totals. Source: seedE2E.ts
# `seedDashboardToday` Marcus's 3 meals (line 1690-1692):
#   Breakfast — Greek Yogurt with Berries: 320 cal / 22g P / 38g C / 6g F
#   Lunch     — Turkey Avocado Wrap:       540 cal / 34g P / 50g C / 18g F
#   Dinner    — Steak with Sweet Potato:   680 cal / 48g P / 55g C / 24g F
# Totals on render (sum of integer macros; no rounding step involved):
CANONICAL_TODAY_FOOD_LOG_COUNT="3"
CANONICAL_TODAY_FOOD_CALORIES="1540"
CANONICAL_TODAY_FOOD_PROTEIN_G="104"
CANONICAL_TODAY_FOOD_CARBS_G="143"
CANONICAL_TODAY_FOOD_FAT_G="48"

# Meal sections present on today's FoodLog. Snack is EMPTY on the canonical
# seed — the seed only writes breakfast/lunch/dinner (seedE2E.ts:1690-1692).
# The adapter emits a comma-delimited present-list; verifier asserts the
# exact set. "present" means "this section contains >=1 entry on today's
# canonical render."
CANONICAL_TODAY_FOOD_MEALS_PRESENT="breakfast,lunch,dinner"

# Pantry canonical state for Marcus's E2E tenant.
# --------------------------------------------------------------
# Seeded by seedE2E.ts → seedMarcusPantry. The helper wipes all
# pantryFoods for Marcus's tenant and re-inserts a deterministic set
# on every seed run, so the final state is invariant across wall-clock
# time and re-entrant on repeat runs.
#
# Composition (8 total):
#   - 5 tenant-shared foods (ownerType="team", createdBy=coach):
#       Chicken Breast, Brown Rice, Greek Yogurt, Oatmeal, Banana
#   - 3 Marcus-personal foods (ownerType="client", userId=Marcus):
#       Marcus's Protein Shake, Marcus's Smoothie, Marcus's Salad
#
# The Pantry adapter's derivation mirrors PantryView:
#   tenantFoodCount   = items where ownerType == "team"    → 5
#   personalFoodCount = items where ownerType != "team"    → 3
#   itemsTotal        = tenantFoodCount + personalFoodCount → 8
#
# Bump in lockstep with the TS mirror in
# `example/convex/canonicalValues.ts` and the seed helper itself.
CANONICAL_PANTRY_ITEMS_TOTAL="8"
CANONICAL_PANTRY_TENANT_FOOD_COUNT="5"
CANONICAL_PANTRY_PERSONAL_FOOD_COUNT="3"

# Messages tab canonical state for Marcus's E2E tenant.
# --------------------------------------------------------------
# Source: seedE2E.ts cleanAllTestMessages (line 467-575). On every
# seedE2E:run, the Marcus↔Sarah conversation is wiped clean and
# re-seeded with EXACTLY 12 natural coach-client messages spanning
# the last 72 hours. Every message is marked read
# (readAt = sentAt + 5min) so no unread badges linger across seeds.
#
# Coach display name is "Sarah Mitchell" (seedE2E.ts:221/251),
# client display name is "Marcus Chen" (CANONICAL_CLIENT_DISPLAY_NAME
# at top of this file).
#
# lastMessagePresent is asserted true (the seed always writes at
# least one message — the 12th is the most recent at ~2 hours ago
# from run time, body "Perfect, that's right on track...").
CANONICAL_MESSAGES_CONVERSATION_COUNT="1"
CANONICAL_MESSAGES_COACH_NAME="Sarah Mitchell"
CANONICAL_MESSAGES_CLIENT_NAME="Marcus Chen"
CANONICAL_MESSAGES_UNREAD_COUNT="0"
CANONICAL_MESSAGES_LAST_MESSAGE_PRESENT="true"
CANONICAL_MESSAGES_MESSAGE_COUNT="12"

# Messages — segmented counts for the bubble-alignment regression
# guard (2026-04-24 CEO report: "only stuff a coach would ever see").
#
#   USER_MESSAGE_COUNT = rows with type != "system".  seedE2E.ts
#   cleanAllTestMessages writes 12 natural coach↔client messages;
#   none of those are typed "system". Post-HC-sync, completeCoachChallenge
#   may insert a 🏆 system row — that row is excluded from this count
#   by definition, so the user count stays pinned at 12.
#
#   SELF_MESSAGE_COUNT = non-system rows whose senderId equals the
#   server's currentUserId for the conversation. seedE2E's 12-row
#   script alternates coach / client with 6 of each, so Marcus's
#   self-count is exactly 6. Going below 6 means the server's
#   currentUserId envelope is not being applied to bubble alignment
#   on iOS — which is exactly the bubble-alignment regression this
#   fix eliminates. Lint'd.
#
# SYSTEM_MESSAGE_COUNT is NONCANONICAL — depends on whether HC sync
# has triggered completeCoachChallenge. The adapter tracks it for
# diagnostics but does NOT assert it. iOS client-side VM filters
# `type == "system"` rows out of the rendered thread regardless of
# count, so UI correctness is enforced by the USER + SELF pair.
# --------------------------------------------------------------
CANONICAL_MESSAGES_USER_MESSAGE_COUNT="12"
CANONICAL_MESSAGES_SELF_MESSAGE_COUNT="6"

# CheckIn canonical state for Marcus's E2E tenant.
# --------------------------------------------------------------
# SEED DEPENDENCY (TWO sources, not one):
#
#   1. `example/convex/seedE2E.ts` — does NOT seed any `checkIns` rows.
#      Confirmed by case-insensitive grep for checkIns/checkIn/CheckIn:
#      zero matches. The seedE2E.ts file owns the deterministic
#      foundation (Marcus user, today's foodLogs, weights, etc.) but
#      not check-ins.
#
#   2. `example/convex/seedHeavyData.ts:316-393` (`seedClients`) pins
#      `i=0` to `E2E_CLIENT_EMAIL = "client-e2e@example.com"` (Marcus),
#      then `seedClientActivity(..., clientIndex=0)` at lines 527-668
#      hits the weekly-check-in loop at lines 661-702 which inserts up
#      to 17 weekly check-ins for Marcus's `userId` in tenant
#      `e2e-test-gym`. With `clientIndex=0 → isGreen=true → gapDays=0`,
#      week=0 (today's week) is included — so the current week ALWAYS
#      has a row whenever seedHeavyData has run against this tenant.
#      The insert at line 692 is idempotent on (tenantId, userId,
#      weekStart) via the `by_tenant_user_week` dupe-find at lines
#      670-675, so re-runs don't duplicate.
#
# Real-world historyCount range observed: 17-19. The +0-2 above the
# seedHeavyData baseline of 17 comes from prior `checkIns:submit`
# calls (example/convex/checkIns.ts:72) made during earlier iOS
# Simulator CheckIn-tab navigation in audits — those too are
# correctly user-scoped and idempotent on weekStart, so they cap
# at one row per week regardless of how many simulator submits ran.
#
# What the canonical contract proves now:
#   (a) the CheckInView bootstrap-primed state is reached — handler
#       fires, JSON writes successfully (cachePrimed=true,
#       schemaVersion=1).
#   (b) seed expectations match the actual seed graph — CheckIn surface
#       reflects seedHeavyData reality, not a stale "zero state"
#       assumption that ignored the second seed source.
#
# What this contract NO LONGER proves directly: tenant-scoping
# correctness on `checkIns:list`. That invariant is now enforced
# server-side at example/convex/checkIns.ts:102-115 via `tenantGuard`
# + the `by_tenant_user` index pinning both `tenantId` AND
# `userId == user._id`. A separate test would be needed to surface a
# tenant-scoping regression; this canonical surface is no longer
# sensitive to it.
CANONICAL_CHECKIN_CURRENT_WEEK_SUBMITTED="true"
CANONICAL_CHECKIN_HISTORY_COUNT_MIN="17"

# Profile / Settings canonical state for Marcus's fresh-install tenant.
# --------------------------------------------------------------
# Most Profile canonicals re-use the client-identity constants at the
# top of this file (CANONICAL_CLIENT_DISPLAY_NAME, CANONICAL_DAY_NUMBER)
# so the Profile adapter compares its rendered values back against the
# same single source of truth Home asserts against.
#
# The Profile-specific constant below covers the "Device & Health"
# trailing-text row state. Post-install-fresh — after the HK seeder
# XCUITest at ios-install-fresh.sh:323 dispatches via
# Profile → Device & Health → Connect Health and grants the 5 read
# types per HealthKitRepository.swift:91-97 — the singleton's
# `isAnyAuthorizationRequested()` flips true. ProfileStateSnapshot
# reads from the SAME singleton at the SAME install-fresh phase as
# HealthSyncStateSnapshot (which Sprint 10 PASS-VERIFIED at main
# `3b4a96c54bc5` with `CANONICAL_HEALTHSYNC_IS_CONNECTED=true`), so
# the canonical here must agree with HealthSync. Sprint 11 flipped
# this from "false" to "true" as the stale-canonical fix prompted by
# Sprint 10's empirical PASS — the prior "Not connected" baseline
# predated the install-fresh HK seeder dispatch.
CANONICAL_PROFILE_HK_CONNECTED="true"

# Steps screen canonical state for Marcus.
# --------------------------------------------------------------
# Hero values re-use the server-seeded activity constants at the top
# of this file:
#   todayStepCount  — CANONICAL_TODAY_STEP_COUNT    = 10500
#   todayActiveKcal — CANONICAL_TODAY_ACTIVE_KCAL   = 472
#   stepGoal        — CANONICAL_STEP_GOAL           = 10000
#
# Additional Steps-specific canonical for the 30-day history count.
# seedLeaderboardPeers / seedDashboardToday populate Marcus's
# activity history; his profile's createdAt anchor
# (CANONICAL_MARCUS_CREATED_AT_DAYS_AGO = 13) plus daily seeding
# gives at least 14 rows (today + 13 back). Using a MIN here rather
# than EXACT because the seed can flex how far back it fills.
CANONICAL_STEPS_RECENT_DAYS_MIN="14"

# Leaderboard peer breadth — dataFreshnessProbe asserts >= 5 peers at
# level >= 6. Home's leaderboard tile shows at least 5 rows.
# --------------------------------------------------------------
CANONICAL_LEADERBOARD_MIN_PEERS="5"

# Leaderboard self-row presence — Marcus's own row must appear in the
# rankings (rankings query must not drop the client's own row). A false
# reading on a fresh install is a real regression. Consumed by
# ios-leaderboard-state-adapter.sh.
# --------------------------------------------------------------
CANONICAL_LEADERBOARD_SELF_ROW_PRESENT="true"

# Leaderboard weekly_logging total rows — seedLeaderboardPeers writes 5
# peers + Marcus = 6 rows minimum for the weekly_logging category. Using
# MIN because future seed extensions may add more peers. Consumed by
# ios-leaderboard-state-adapter.sh.
# --------------------------------------------------------------
CANONICAL_LEADERBOARD_WEEKLY_LOGGING_TOTAL_MIN="6"

# Challenges — seedCoachChallenge writes exactly one active coach
# challenge ("7-Day Step Surge") with targetValue=70000 step total
# across 7 days and xpReward=300.
# --------------------------------------------------------------
# SEED DEPENDENCY (TWO sources; participantCount is the union):
#
#   1. `example/convex/seedE2E.ts:1488-1505` (`seedCoachChallenge`)
#      collects participants via `users.by_tenant_role` filtered to
#      `(tenantId == e2e-test-gym, role == "client")` and inserts a
#      `challengeParticipants` row for EVERY result. The 6-name
#      `completionOrder` array at lines 1498-1505 is used ONLY to
#      compute per-row `currentValue` / `completed` — clients NOT in
#      that array still get a participant row with `rank=-1` →
#      `currentValue = round(70000 * 0.3) = 21000`, `completed=false`.
#      So `participantCount` is "every tenant-client", not "the 6
#      named ones."
#
#   2. `example/convex/seedHeavyData.ts:316-393` (`seedClients`)
#      iterates `i = 0..19`, short-circuits `i=0` (Marcus exists),
#      and inserts 19 NEW peer users (`client2-e2e..client20-e2e`)
#      with `tenantId: tenant._id` (the e2e-test-gym tenant) and
#      `role: "client"`. These are picked up by the seedE2E
#      enrollment loop on the next `seedE2E:run`, raising
#      participantCount from 6 (Marcus + 5 leaderboard peers seeded
#      by seedE2E.ts:1016/1039) to 25.
#
# Real-world `participantCount` floor: 6 (Marcus + 5 named leaderboard
# peers from seedE2E.ts alone). On a fully seeded staging environment
# with seedHeavyData run, observed value is 25. MIN-floor matches the
# Sprint 7 leaderboard precedent below
# (`CANONICAL_LEADERBOARD_WEEKLY_LOGGING_TOTAL_MIN`) — same query
# shape (tenant-wide collect), same MIN-vs-EXACT rationale.
#
# Deterministic completion pattern (unchanged): top 2 of the 6
# named peers done — Derek Callahan + Tyler Okonkwo (rank 0, 1) —
# everyone else (Marcus at rank 2 → currentValue = round(70000 *
# max(0.2, 1 - 2*0.15)) = 49000; rank 3-5 named peers; rank=-1
# seedHeavyData peers) is `completed=false`. So `completedCount`
# stays EXACT 2 regardless of seedHeavyData. `myProgress` stays
# EXACT 49000 because Marcus short-circuits at seedHeavyData's
# `if (existing) continue` and stays at completionOrder index 2.
#
# Tenant-scoping correctness on `challenges:getActive` is enforced
# server-side by `tenantGuard` (example/convex/gamification/challenges.ts);
# the canonical adapter no longer attempts to prove it via a
# zero-state assertion. See
# `qa-audits/ios-real-data/challenges/sha-1547b335-mark-diagnosis.md`
# for the full seed-graph trace.
# --------------------------------------------------------------
CANONICAL_CHALLENGES_TOTAL_COUNT="1"
CANONICAL_CHALLENGES_COACH_SURGE_TITLE="7-Day Step Surge"
CANONICAL_CHALLENGES_COACH_SURGE_TARGET="70000"
CANONICAL_CHALLENGES_COACH_SURGE_XP_REWARD="300"
CANONICAL_CHALLENGES_MY_PROGRESS="49000"
CANONICAL_CHALLENGES_MY_COMPLETED="false"
CANONICAL_CHALLENGES_PARTICIPANT_COUNT_MIN="6"
CANONICAL_CHALLENGES_COMPLETED_COUNT="2"

# HealthSync — post ios-install-fresh.sh the HK seeder has requested
# authorization (via XCUITest-driven tap on the DEBUG "Seed HealthKit"
# button in Profile → Device & Health) and written Marcus's 7-day
# history. So isConnected = true on the canonical fresh-install state.
# HKHealthStore.isHealthDataAvailable() is true on all modern iOS
# simulators. `lastSyncDescription` is NOT canonical — wallclock string.
# Consumed by ios-healthsync-state-adapter.sh.
# --------------------------------------------------------------
CANONICAL_HEALTHSYNC_IS_CONNECTED="true"
CANONICAL_HEALTHSYNC_IS_HEALTH_DATA_AVAILABLE="true"

# Trophies screen canonical state for Marcus's E2E tenant.
# --------------------------------------------------------------
# UNLIKE every other screen above, Trophies does NOT pin EXACT canonical
# values. Trophy earned-counts depend on runtime-variable inputs:
#   - seedE2E seeds 30d of activity / streak / food-log history, but the
#     trophy-award logic in `example/convex/gamification/trophies.ts:99-116`
#     fans out across 16 source tables (userAchievements, mysteryAchieve-
#     ments, coachRewards, streaks, stepSubmissions, strengthSessions,
#     foodLogs, xpEvents, snackLogs, snackWalkerStatus, cleanCloseStatus,
#     intentLoggerStatus, streakRecoveries, checkIns, challengeParticipants,
#     messages) — whether the award-cron has fired by the time install-fresh
#     polls is non-deterministic. This is the same runtime-flex class the backend
#     flagged for Messages's `completeCoachChallenge` trophy-message append
#     (see CANONICAL_MESSAGES_MESSAGE_COUNT MIN-not-EXACT note).
#   - Per `example/ios/ExampleApp/UI/Screens/Trophies/TrophiesStateSnapshot.swift:29-46`
#     the snapshot ships explicitly WITHOUT hard-pinned canonicals; the
#     verifier asserts MIN floors instead.
#
# If the backend pins the trophy cron to a deterministic seed-time state in a
# future seedE2E extension, bump these MIN constants to EXACT in lockstep
# with the TS mirror and the adapter — same lockstep rule the file's
# header doc applies to every canonical.
#
# Adapter shape (TrophiesStateSnapshot.swift:55-72): totalEarned / thisMonth
# / gold / inProgressCount / mysterySlotCount / trophyCount / cachePrimed
# / schemaVersion=1. Six numeric fields → six MIN constants below.
CANONICAL_TROPHIES_TROPHY_COUNT_MIN="10"
CANONICAL_TROPHIES_MYSTERY_SLOT_COUNT_MIN="1"
CANONICAL_TROPHIES_TOTAL_EARNED_MIN="0"
CANONICAL_TROPHIES_GOLD_MIN="0"
CANONICAL_TROPHIES_THIS_MONTH_MIN="0"
CANONICAL_TROPHIES_IN_PROGRESS_COUNT_MIN="0"

# dayNumber — now a pinned constant. The seed re-anchors users.createdAt
# to `todayUtcStart - CANONICAL_MARCUS_CREATED_AT_DAYS_AGO` on every run,
# which makes `dayNumber = DAYS.between(createdAt, today) + 1` evaluate
# to CANONICAL_DAY_NUMBER on every wall-clock day. The verifier asserts
# this exact value on the rendered Home.
# --------------------------------------------------------------
CANONICAL_DAY_NUMBER_RULE="pinned via seed anchor: CANONICAL_DAY_NUMBER = DAYS.between(todayUtcStart - CANONICAL_MARCUS_CREATED_AT_DAYS_AGO * DAY, today) + 1"

# STREAKS — both start at 0 on fresh seed (seedE2E.ts:256-271), and are
# incremented by seedLeaderboardPeers/seedDashboardToday to match Marcus's
# 30d food history. The exact values are NONCANONICAL (depend on run date)
# and asserted by dataFreshnessProbe, not here.
CANONICAL_FOOD_STREAK_MIN="1"
CANONICAL_STEP_STREAK_MIN="1"

# NONCANONICAL — listed for documentation; verifier MUST skip these.
# --------------------------------------------------------------
# CLIENT_AUTH_ID, CLIENT_USER_ID, CLIENT_TENANT_ID, _creationTime,
# program start date string (shifts every wall-clock day), seed timestamps.

# Sanity guard — POSIX sh only. Bash-only shells may source this fine, but
# `set -u`-safe consumers need every reference to work.
: "${CANONICAL_CLIENT_EMAIL:?}"
: "${CANONICAL_TODAY_STEP_COUNT:?}"
: "${CANONICAL_MARCUS_LEVEL:?}"
