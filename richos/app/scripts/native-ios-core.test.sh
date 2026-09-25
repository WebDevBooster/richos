#!/usr/bin/env bash
# The RichOS native iPhone app's core, headless: the Swift package's unit tests and the `bin/rios`
# command line over the real core, on this Mac with no simulator (build plan §3.1 loops L1, L1′;
# stream I1). A host without Swift or the external SSD prints NOT RUN and exits 2; a failure on a
# capable host is red.
# run-tests: inputs richos/app/scripts/native-ios-lock.test.py richos/mobile/native-ios/Core richos/mobile/native-ios/bin richos/web/web-app/lib/wordlist.js richos/mobile/conformance/vectors richos/app/scripts/native-ios-core.test.sh
# run-tests: covers richos/app/scripts/native-ios-lock.test.py richos/mobile/native-ios/Core/Package.swift richos/mobile/native-ios/Core/Sources/RichOSCore/AppState.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Action.swift richos/mobile/native-ios/Core/Sources/RichOSCore/ActionCoding.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Ports.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Pairing/PairLink.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Pairing/PairingReducer.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Pairing/WordList.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Voice/VoiceGeometry.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Voice/VoiceReducer.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Settings/SettingsReducer.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Settings/AppLinks.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Conversation/AttachmentPicking.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Conversation/ConversationReducer.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Conversation/Attachments.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/AttachmentTests.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Connection/ConnectionReducer.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Connection/TailscaleTunnel.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Connection/LiveConnection.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Connection/NetworkEffects.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/Identity.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/NetworkEffectsTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/LiveConnectionTests.swift richos/mobile/native-ios/Core/Sources/RichOSFixtures/Commands.swift richos/mobile/native-ios/Core/Sources/RichOSFixtures/Fixtures.swift richos/mobile/native-ios/Core/Sources/RichOSCLI/main.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/CoreTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/AttachmentPickingTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/PairingRemovedTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/SettingsLinksTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/ConformanceTests.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/Signing.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/Stream.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/APIClient.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/Delivery.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Protocol/PairingAPI.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/PairingConformanceTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/TransportConformanceTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/StreamConformanceTests.swift richos/mobile/native-ios/bin/rios richos/mobile/native-ios/Core/Sources/RichOSCore/TickSchedule.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/TickScheduleTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/LifecycleTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/AppWiringTests.swift richos/mobile/native-ios/Core/Sources/RichOSCore/AppStore.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/AppStoreDurabilityTests.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Pairing/MacWait.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/PairingV2Tests.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Conversation/Transcript.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/EchoBeforeAcceptanceTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/PairWaitTests.swift richos/mobile/native-ios/Core/Sources/RichOSCore/Conversation/ReadReplies.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/ReadRepliesTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/MicrophoneCardTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/HungMacTests.swift richos/mobile/native-ios/Core/Tests/RichOSCoreTests/TailscaleOffTests.swift
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
RIOS="$ROOT/richos/mobile/native-ios/bin/rios"
VOLUME=/Volumes/E1TB

if [ "$(uname -s)" != Darwin ]; then echo '  NOT RUN  native-ios-core: macOS is required'; exit 2; fi
if ! command -v swift >/dev/null 2>&1; then echo '  NOT RUN  native-ios-core: swift is unavailable'; exit 2; fi
if [ ! -d "$VOLUME" ] || [ "$(stat -f %d "$VOLUME")" = "$(stat -f %d /Volumes)" ]; then
  echo '  NOT RUN  native-ios-core: /Volumes/E1TB is not mounted'; exit 2
fi

# The build cache is reused across runs of this checkout (a cold core build is ~20 s); the
# headless session inside it is reset at the start and removed at the end.
KEY="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-10)"
export RICHOS_NATIVE_IOS_CACHE="$VOLUME/caches/richos-native-ios-proof/$KEY"
SCRATCH="$(mktemp -d "$VOLUME/tmp/native-ios-core.XXXXXX")" || { echo '  FAIL  scratch directory'; exit 1; }
trap 'rm -rf "$SCRATCH" "$RICHOS_NATIVE_IOS_CACHE/headless"' EXIT HUP INT TERM

PASS=0; FAILED=0
ok()  { PASS=$((PASS + 1)); echo "  ok  $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

echo "=== native-ios-core ==="

# C1 — the core's unit tests (loop L1). The count is read back so a run of nothing cannot pass.
if "$RIOS" test >"$SCRATCH/test.log" 2>&1; then
  COUNT="$(grep -Eo 'Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed' "$SCRATCH/test.log" | grep -Eo 'with [0-9]+' | grep -Eo '[0-9]+' | tail -1)"
  if [ "${COUNT:-0}" -gt 0 ]; then ok "C1 core unit tests: $COUNT passed (bin/rios test)"
  else bad "C1 core unit tests" "no passing test count in the output: $(tail -3 "$SCRATCH/test.log" | tr '\n' ' ')"; fi
else
  bad "C1 core unit tests" "$(grep -E 'error:|✘|failed' "$SCRATCH/test.log" | head -5 | tr '\n' ' ')"
fi

# C2 — a scenario through the real core, as a separate CLI process (loop L1′).
if "$RIOS" headless reset >/dev/null 2>"$SCRATCH/err" \
   && "$RIOS" headless scenario compose-draft >"$SCRATCH/scenario.json" 2>"$SCRATCH/err"; then
  if [ "$(json 'd["ok"] and d["result"]["name"] == "compose-draft" and len(d["result"]["trace"]) == 6' < "$SCRATCH/scenario.json")" = True ]; then
    ok "C2 headless scenario compose-draft: six steps, its checks passed"
  else bad "C2 headless scenario compose-draft" "unexpected result: $(head -c 300 "$SCRATCH/scenario.json")"; fi
else
  bad "C2 headless scenario compose-draft" "$(cat "$SCRATCH/err")"
fi

# C3 — state persists across separate CLI processes, as it will across app launches.
"$RIOS" headless fixture conv-empty >/dev/null 2>&1
"$RIOS" headless action '{"type":"compose","text":"Persisted across processes"}' >/dev/null 2>&1
if "$RIOS" headless state >"$SCRATCH/state.json" 2>"$SCRATCH/err" \
   && [ "$(json 'd["result"]["state"]["draft"] + "|" + d["result"]["state"]["screen"]' < "$SCRATCH/state.json")" = "Persisted across processes|conv-empty" ]; then
  ok "C3 a draft written by one CLI process is read by the next"
else
  bad "C3 a draft written by one CLI process is read by the next" "$(head -c 300 "$SCRATCH/state.json") $(cat "$SCRATCH/err")"
fi

# C4 — a refusal is structured: JSON on stderr naming what exists, exit 1, nothing on stdout.
"$RIOS" headless fixture no-such-screen >"$SCRATCH/out" 2>"$SCRATCH/err"; CODE=$?
if [ "$CODE" = 1 ] && [ ! -s "$SCRATCH/out" ] \
   && [ "$(json 'd["ok"] is False and "known: pair-intro" in d["error"]' < "$SCRATCH/err")" = True ]; then
  ok "C4 an unknown fixture is a structured refusal listing the known ones"
else
  bad "C4 an unknown fixture is a structured refusal" "exit $CODE; stderr $(head -c 300 "$SCRATCH/err")"
fi

# C5 — build output may never be pointed off the external SSD.
RICHOS_NATIVE_IOS_CACHE=/tmp/rios-off-ssd-$$ "$RIOS" headless state >/dev/null 2>"$SCRATCH/err2"; CODE2=$?
if [ "$CODE2" = 2 ] && grep -q 'must be on /Volumes/E1TB' "$SCRATCH/err2" && [ ! -e /tmp/rios-off-ssd-$$ ]; then
  ok "C5 a cache off /Volumes/E1TB is refused and nothing is created there"
else
  bad "C5 a cache off /Volumes/E1TB is refused" "exit $CODE2: $(cat "$SCRATCH/err2")"
fi

# C6: the built CLI refuses overlapping owners and recovers after a hard kill.
# Its throwaway cache comes from Python's tempfile, so TMPDIR is pinned to this suite's own
# scratch on the SSD: rios refuses a cache off /Volumes/E1TB (C5), and under the nightly gate,
# which passes the operator's TMPDIR through, C6 failed on exactly that refusal
# (run 20260925T190759Z-2b4b0a7e, "the cache must be on /Volumes/E1TB, not /var/folders/...").
if TMPDIR="$SCRATCH" python3 "$DIR/native-ios-lock.test.py" "$RICHOS_NATIVE_IOS_CACHE/spm/debug/rios-cli" >"$SCRATCH/lock.log" 2>&1; then
  ok "C6 $(tail -1 "$SCRATCH/lock.log")"
else
  bad "C6 command-lock crash recovery" "$(tail -15 "$SCRATCH/lock.log")"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "=== native-ios-core tests: all $PASS passed ==="
  exit 0
fi
echo "=== native-ios-core tests: $FAILED FAILED, $PASS passed ==="
exit 1
