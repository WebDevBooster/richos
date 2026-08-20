---
name: android-native-dev
description: >
  Build and maintain a native Android app in Kotlin and Jetpack Compose.
  Use this when working on Android app architecture, Gradle setup, Compose UI,
  Health Connect integration, WorkManager sync, secure storage, FCM,
  Play Store readiness, or Android-specific debugging and release work.
---

# Android Native Dev

Use this skill for Android work in `${APP_ROOT}` (your adopter-defined Android source root — see `orchestration.config`).

## Scope

- Kotlin app code
- Jetpack Compose UI
- Gradle and Android project setup
- Health Connect integration
- WorkManager background sync
- secure token storage
- FCM push handling
- Play Console and Android release concerns

## Repo Rules

<!-- TODO (adopter): if a legacy/reference tree exists alongside the active
     Android app (e.g. a prior web or cross-platform client being replaced),
     name it here and state that new Android work belongs in the active tree.
     Also note any surface split worth remembering (e.g. "client is native,
     admin/back-office remains web") and any route/naming renames engineers
     should know about. Delete this block if there's no legacy tree. -->

## Default Technical Stance

- Kotlin first, no cross-platform UI framework assumptions
- Compose-first UI with clear state ownership
- prefer unidirectional data flow through view model and repository layers
- treat Health Connect reads and sync status as product-critical, not nice-to-have
- design for degraded states from the start: denied permission, stale sync, unsupported source, partial-day data, offline, worker killed

## Android Checklist

When starting Android work, verify:

1. app module boundaries are clear
2. build types and flavors are intentional
3. minSdk and targetSdk are explicit and justified
4. signing and secrets are not hardcoded
5. Compose state is not leaking business logic into views
6. background sync has retry rules and battery-aware constraints
7. health permission flows have revoke and recovery handling

## Health Connect Rules

- read only the data the app actually uses
- normalize metrics to the shared backend contract before sending
- distinguish partial-day data from complete-day data
- surface stale or missing data as explicit app state
- never silently invent totals when source data is incomplete

## WorkManager Rules

- use WorkManager for scheduled and retryable background work
- make sync jobs idempotent
- use exponential backoff
- assume OEM battery restrictions will break ideal behavior
- design for foreground refresh to recover from missed background execution

## Security Rules

- store tokens in encrypted storage backed by Android Keystore
- keep secrets out of logs
- do not treat local storage as trusted state
- make auth refresh explicit and observable in the app state

## Verification

Before calling Android work done:

1. build the app successfully
2. test on emulator and at least one real Android device when possible
3. verify permission grant, deny and revoke flows
4. verify sync on fresh install and returning-user flow
5. verify the backend contract still matches the app payloads

## Pairings

- use `health-data-sync-contracts` for metric semantics
- use `mobile-release-and-build-ops` for build and release expectations
- use `using-git-worktrees` for version control
