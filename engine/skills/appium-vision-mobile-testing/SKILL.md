---
name: appium-vision-mobile-testing
description: >
  Run native mobile app tests with a strict human-like policy: the agent may
  only observe screenshots or recordings and may only act through taps, swipes,
  typing and device controls via Appium. Use this for the target app's iOS and
  Android black-box testing, especially when validating real user flows
  without source, locator or accessibility-tree shortcuts.
---

# Appium Vision Mobile Testing

Use this skill for black-box mobile testing of `${APP_ROOT}` (your adopter-defined app source root — see `orchestration.config`).

## Policy

Appium is the robot hand, not the tester.

The tester:

- sees only the live screen image or recording
- decides based on visible UI only
- acts with human-like inputs only

Forbidden shortcuts:

- page source
- element IDs
- XPath
- accessibility tree
- semantic locators

## Allowed Action Set

- start session
- install app
- launch app
- capture screenshot or recording
- tap by coordinates
- swipe or drag by coordinates
- long press by coordinates
- type text
- press back, home or app-switcher level controls
- rotate, background and foreground app
- save artifacts

## Default Loop

1. capture current screen
2. interpret current visible state
3. choose next human-like action
4. send action through Appium
5. capture next screen
6. repeat until success, failure or stuck state

## Device Rules

- simulators and emulators are fine for iteration
- final signoff should happen on real devices when possible
- health-data, notification and background behavior must not be trusted from simulator-only evidence

## What To Validate

- first-run and install flows
- invite link and deep link handling
- auth flows
- permission prompts
- sync-status messaging
- navigation clarity
- interruption recovery
- visible regressions after updates

## Failure Reporting

When a run fails, capture:

- device and OS
- app build identifier
- visible last good screen
- visible failure screen
- action sequence
- whether the issue is likely product, environment or tooling

## Pairings

- use `mobile-qa-reporting-and-device-matrix` for test coverage and reporting
- use `health-data-sync-contracts` when testing sync correctness
