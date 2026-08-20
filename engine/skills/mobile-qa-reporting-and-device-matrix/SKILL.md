---
name: mobile-qa-reporting-and-device-matrix
description: >
  Plan and report native QA with a real device matrix, permission-state
  coverage and structured bug evidence. Use this when defining mobile test
  coverage, validating release readiness, or reporting native defects on iOS
  and Android.
---

# Mobile QA Reporting And Device Matrix

Use this skill for native QA planning and reporting.

## Coverage Model

Every important native test should state:

- platform
- OS version
- device model
- install state
- auth state
- permission state
- network state
- health-data source state
- expected outcome

## Minimum Matrix Thinking

Cover variation across:

- iPhone versus Android
- current OS versus older supported OS
- fresh install versus upgrade
- granted versus denied versus revoked permissions
- online versus offline versus flaky network
- simulator/emulator versus real device

## Bug Report Requirements

Every native bug report should include:

- device model
- OS version
- app build
- test environment
- exact steps
- expected result
- actual result
- severity
- artifacts: screenshots, recordings, logs if relevant

## Severity Rules

- data integrity and sync correctness issues are release blockers
- auth loss, broken invite flow and notification misrouting are high severity
- visual defects are logged but not inflated

## Release Readiness Questions

Before signoff, answer:

1. what devices were covered
2. what permission states were covered
3. what install and update paths were covered
4. whether real hardware was used
5. whether health store, app and backend values matched

## Pairings

- use `appium-vision-mobile-testing` for human-like black-box runs
- use `health-data-sync-contracts` for sync verification
