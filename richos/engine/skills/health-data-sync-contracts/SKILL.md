---
name: health-data-sync-contracts
description: >
  Define and enforce the shared health-data contract across iOS, Android,
  backend and QA. Use this when implementing or validating step counts,
  calories, partial-day sync, stale sync, source metadata, timezone handling,
  or app-display-to-backend parity for HealthKit and Health Connect data.
---

# Health Data Sync Contracts

Use this skill whenever health data moves between:

- HealthKit
- Health Connect
- native app state
- backend payloads
- user-facing displays
- QA verification

## Core Rule

One metric means one thing everywhere.

Do not let iOS, Android, backend and QA each invent their own interpretation.

## Contract Areas

- `stepCount`
- `activeCalories`
- `basalCalories`
- `totalCalories`
- sample window
- source metadata
- sync freshness
- partial versus complete day status
- manual fallback state

## Required Decisions

For any health-data feature, make these explicit:

1. source field on iOS
2. source field on Android
3. normalized backend field
4. partial-day behavior
5. stale-data behavior
6. timezone/date boundary behavior
7. duplicate-source handling
8. QA verification method

## Non-Negotiables

- `totalCalories` must never be ambiguous
- partial data must not be presented as complete data
- stale data must be represented explicitly
- manual entry must be distinguishable from synced data
- app display and backend payload must match the same normalized meaning

## QA Rule

For health-sync verification, compare three layers:

1. source health store data
2. app-displayed data
3. backend-stored data

All three must match within the agreed normalization rules.

## Change Rule

If any metric definition changes:

- update iOS logic
- update Android logic
- update backend handling
- update QA expectations
- update any user-facing sync-status copy affected by the change

## Pairings

- use with `android-native-dev`
- use with `ios-native-dev`
- use with `mobile-qa-reporting-and-device-matrix`
