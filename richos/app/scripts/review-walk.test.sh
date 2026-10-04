#!/usr/bin/env bash
# review-walk.test.sh — what can be checked of the iPhone App Review walk (`rios review-walk`,
# richos/mobile/native-ios/Tools/review-walk.mjs; CEO 2026-10-04, §107) without a simulator, a browser
# or the live review service: the app's step lines are read back exactly, the steps keep the review
# notes' order, every identifier the walk's UI test (UITests/ReviewWalkTests.swift) touches still
# exists in the app, and a bad commit is refused before anything is leased or built. The walk itself
# is proven by running it on the commit; `testflight.ts upload` refuses without its pass.
# run-tests: no-host-screen: Node and grep over source files only; no simulator, browser, phone or network
# run-tests: inputs richos/app/scripts/review-walk.test.sh richos/mobile/native-ios/Tools/review-walk.mjs richos/mobile/native-ios/Tools/review-walk.test.mjs richos/mobile/native-ios/UITests/ReviewWalkTests.swift richos/mobile/native-ios/App
# run-tests: covers richos/mobile/native-ios/Tools/review-walk.mjs richos/mobile/native-ios/Tools/review-walk.test.mjs richos/mobile/native-ios/UITests/ReviewWalkTests.swift
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node --test "$here/../../mobile/native-ios/Tools/review-walk.test.mjs"
