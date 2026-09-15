---
name: ios-native-dev
description: >
  Build and maintain a native iOS app in Swift and SwiftUI. Use this when
  working on iOS app architecture, SwiftUI UI, HealthKit integration,
  background tasks, Keychain storage, APNs, App Store readiness, or
  iOS-specific debugging and release work.
---

# iOS Native Dev

Use this skill for iOS work in `${APP_ROOT}` (your adopter-defined iOS source root — see `orchestration.config`).

## Scope

- Swift app code
- SwiftUI UI
- Xcode project structure
- HealthKit integration
- BGTaskScheduler usage
- Keychain token storage
- APNs push handling
- TestFlight and App Store concerns

## Repo Rules

<!-- TODO (adopter): if a legacy/reference tree exists alongside the active
     iOS app (e.g. a prior web or cross-platform client being replaced), name
     it here and state that new iOS work belongs in the active tree. Also note
     any surface split worth remembering (e.g. "client is native, admin/
     back-office remains web") and any route/naming renames engineers should
     know about. Delete this block if there's no legacy tree. -->

## Default Technical Stance

- Swift and SwiftUI first
- follow Apple-native interaction patterns unless the product requirement is stronger
- keep product state explicit and testable
- treat HealthKit sync reliability and stale-state handling as core app behavior
- never promise background behavior that iOS does not reliably guarantee

## iOS Checklist

When starting iOS work, verify:

1. app targets and bundle identifiers are intentional
2. required entitlements are explicit
3. privacy strings are present and specific
4. secrets are not in source
5. SwiftUI views are not hiding business logic
6. background tasks are realistic for iOS limits
7. HealthKit permission recovery flows exist

## HealthKit Rules

- request only required HealthKit types
- normalize data to the shared backend contract before upload
- treat partial-day data as partial
- keep source and freshness visible in app state
- never hide stale sync behind optimistic UI

## Background Rules

- background delivery is best-effort
- foreground refresh must be able to recover state
- stale sync states need clear user-facing handling
- do not build product logic on assumed exact delivery timing

## Security Rules

- store tokens in Keychain
- do not put secrets in UserDefaults
- keep sensitive data out of logs and crash breadcrumbs
- make auth refresh explicit in the data layer

## Verification

Before calling iOS work done:

1. build in Xcode successfully
2. test on simulator and at least one real iPhone when possible
3. verify permission grant, deny and revoke flows
4. verify fresh install and returning-user auth flow
5. verify the backend contract still matches the app payloads

## Pairings

- use `health-data-sync-contracts` for metric semantics
- use `mobile-release-and-build-ops` for build and release expectations
- use `using-git-worktrees` for version control
