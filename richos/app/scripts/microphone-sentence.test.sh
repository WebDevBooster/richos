#!/usr/bin/env bash
# The sentence macOS shows when RichOS asks for the microphone is Iris's, word for word, as the CEO
# approved it (2026-10-08, round 19: "yes, also keep the sentence Iris wrote for when macOS shows
# when RichOS asks for the microphone"; dictation plan slice 2, section 2 row 7). A changed word is
# a sentence he never approved, so this compares the whole string.
# run-tests: no-host-screen: reads one property list; nothing is built, opened or asked
# run-tests: inputs richos/app/scripts/microphone-sentence.test.sh richos/app/src-tauri/Info.plist
# run-tests: covers richos/app/src-tauri/Info.plist
set -euo pipefail
cd "$(dirname "$0")/../src-tauri"
want='So you can talk instead of typing. I listen only after you tap F1 or press the talk button.'
got="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' Info.plist)"
if [ "$got" != "$want" ]; then
  echo "FAIL  NSMicrophoneUsageDescription is not Iris's approved sentence"
  echo "      expected: $want"
  echo "      actual:   $got"
  exit 1
fi
echo "PASS  NSMicrophoneUsageDescription is Iris's approved sentence, word for word"
