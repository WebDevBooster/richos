---
name: mobile-release-and-build-ops
description: >
  Operate the native build and release workflow. Use this when preparing
  iOS or Android builds, managing signing, TestFlight or Play Console flows,
  coordinating staging versus device builds, or deciding what "done" means for
  native app changes.
---

# Mobile Release And Build Ops

Use this skill for native build and release work for `${APP_ROOT}` (your adopter-defined app source root — see `orchestration.config`).

## Core Distinction

Native release work is not the same thing as web deployment.

For this project:

- your deploy platform matters for backend and web services
- TestFlight matters for iOS client distribution
- Play Console internal or testing tracks matter for Android client distribution

Do not confuse a backend deploy with a native release.

## Done Criteria

Native work is only done when the relevant parts are verified:

1. code is committed correctly
2. backend or web changes are deployed if required
3. native build is produced if required
4. build is installed in the right testing channel if required
5. the changed behavior is verified on device or simulator as appropriate

## Release Areas

- versioning and build numbers
- signing and provisioning
- release notes
- TestFlight distribution
- Play testing-track distribution
- environment selection
- crash and log visibility

## Repo Rules

<!-- TODO (adopter): note which trees are legacy vs. active (if you're migrating
     from a prior client), and which surfaces depend on which deploy pipeline —
     e.g. "the web/backend deploy pipeline covers X; native client distribution
     (TestFlight/Play Console) is separate from it." Delete this block if there's
     no legacy tree and only one deploy pipeline. -->

## Practical Rule

Before reporting native work complete, state clearly:

- whether backend changed
- whether a backend/web deploy was needed
- whether iOS build was needed
- whether Android build was needed
- what was actually verified

## Pairings

- use `use-railway` when Railway operations are involved
- use `android-native-dev` or `ios-native-dev` for platform-specific build details
