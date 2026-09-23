#!/usr/bin/env bash
# native-ios-ui — the native iPhone app's screens (stream I2): every round-12 screen from the core's
# fixture of the same name, the visible controls, accessibility at the largest text size, contrast in
# both appearances.
#
# Two parts, fastest first:
#   1. HEADLESS (seconds, this Mac, no simulator), compiled from the app's own sources:
#      * every one of the core's 63 round-12 fixtures derives the screen round 12 names (ScreenModel);
#      * the adopted T3 viewport geometry, with round 12's 80-point threshold;
#      * WCAG contrast of every text and indicator pairing, from the app's own Palette values.
#   2. SIMULATOR (minutes): builds the app and its UI tests from `native-ios/project.yml`, then runs
#      them on an iPhone SE (3rd generation) and an iPhone 16 Pro Max — each device's tests split
#      across RICHOS_IOS_UI_SHARDS simulators of that device (default 2), every simulator created by
#      this script, booted headless (never Simulator.app), all running at once, shut down and deleted
#      by UDID after the run — in UTC and en_US so every picture matches the mockup's 8:02 AM.
#      Screenshots are exported per device.
#
#   native-ios-ui.test.sh                        both parts
#   native-ios-ui.test.sh --headless             part 1 only
#   native-ios-ui.test.sh --only <Class/test>    part 2 scoped (xcodebuild -only-testing), repeatable,
#                                                e.g. --only ScreenshotTests/testComposerDark
#   native-ios-ui.test.sh --device se|pm         part 2 on one device
#   RICHOS_IOS_UI_SHARDS=N native-ios-ui.test.sh  N simulators per device (default 2; 1 = unsplit)
#
# Missing Xcode, the iOS runtime, xcodegen or `native-ios/project.yml` exits 2 with NOT RUN; a failure
# on a capable host is red.
# run-tests: no-host-screen: simctl and XCUITest run on simulators this suite creates, booted headless without Simulator.app
# run-tests: inputs richos/app/scripts/native-ios-ui.test.sh richos/app/scripts/lib/ios_ui_shards.py richos/engine/scripts/lib/worker_tokens.py richos/mobile/native-ios/App/Design richos/mobile/native-ios/App/Features richos/mobile/native-ios/UITests richos/mobile/native-ios/UnitTests richos/mobile/native-ios/Core/Sources/RichOSCore richos/mobile/native-ios/Core/Sources/RichOSFixtures richos/mobile/native-ios/project.yml
# run-tests: covers richos/app/scripts/lib/ios_ui_shards.py richos/mobile/native-ios/App/Design/Palette.swift richos/mobile/native-ios/App/Design/Typography.swift richos/mobile/native-ios/App/Design/Motion.swift richos/mobile/native-ios/App/Design/SVGPath.swift richos/mobile/native-ios/App/Design/Icons.swift richos/mobile/native-ios/App/Design/Mark.swift richos/mobile/native-ios/App/Design/Components.swift richos/mobile/native-ios/App/Features/Root/ScreenModel.swift richos/mobile/native-ios/App/Features/Root/Intent.swift richos/mobile/native-ios/App/Features/Root/RootView.swift richos/mobile/native-ios/App/Features/Conversation/Rows.swift richos/mobile/native-ios/App/Features/Conversation/VoiceBubble.swift richos/mobile/native-ios/App/Features/Conversation/TranscriptView.swift richos/mobile/native-ios/App/Features/Conversation/TranscriptViewportGeometry.swift richos/mobile/native-ios/App/Features/Conversation/ConversationChrome.swift richos/mobile/native-ios/App/Features/Composer/ComposerView.swift richos/mobile/native-ios/App/Features/Voice/VoiceChrome.swift richos/mobile/native-ios/App/Features/Pairing/Takeovers.swift richos/mobile/native-ios/App/Features/Pairing/Scanner.swift richos/mobile/native-ios/App/Features/Pairing/PairingLinkSheet.swift richos/mobile/native-ios/App/Features/Settings/Overlays.swift richos/mobile/native-ios/App/Features/Attachments/AttachmentModel.swift richos/mobile/native-ios/App/Features/Attachments/AttachmentViews.swift richos/mobile/native-ios/App/Features/Attachments/PhotoScene.swift richos/mobile/native-ios/UITests/Support.swift richos/mobile/native-ios/UITests/ScreenshotTests.swift richos/mobile/native-ios/UITests/InteractionTests.swift richos/mobile/native-ios/UITests/AccessibilityLayoutTests.swift richos/mobile/native-ios/UnitTests/TranscriptViewportGeometryTests.swift
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
if [ -z "${RICHOS_WORKER_TOKENS:-}" ]; then
  exec python3 "$ROOT/richos/engine/scripts/lib/worker_tokens.py" machine -- bash "${BASH_SOURCE[0]}" "$@"
fi
NATIVE="$ROOT/richos/mobile/native-ios"
VOLUME=/Volumes/E1TB

MODE=all
ONLY=()
DEVICES=("iPhone SE (3rd generation)" "iPhone 16 Pro Max")
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) MODE=headless; shift ;;
    --only) ONLY+=("-only-testing:RichOSNativeUITests/$2"); shift 2 ;;
    --device)
      case "$2" in
        se) DEVICES=("iPhone SE (3rd generation)") ;;
        pm) DEVICES=("iPhone 16 Pro Max") ;;
        *) echo "native-ios-ui: --device se|pm" >&2; exit 64 ;;
      esac
      shift 2 ;;
    *) echo "native-ios-ui: unknown argument $1" >&2; exit 64 ;;
  esac
done

not_run() { echo "  NOT RUN  native-ios-ui: $*"; exit 2; }

command -v xcrun >/dev/null 2>&1 || not_run "Xcode command-line tools are unavailable"
if [ ! -d "$VOLUME" ] || [ "$(stat -f %d "$VOLUME")" = "$(stat -f %d /Volumes)" ]; then
  not_run "/Volumes/E1TB is not mounted (all build output lives there)"
fi

KEY="$(printf '%s' "$NATIVE" | shasum -a 256 | cut -c1-10)"
CACHE="${RICHOS_NATIVE_IOS_UI_CACHE:-$VOLUME/caches/richos-native-ios-ui/$KEY}"
case "$CACHE" in "$VOLUME"/*) ;; *) not_run "RICHOS_NATIVE_IOS_UI_CACHE must be on $VOLUME" ;; esac
mkdir -p "$CACHE"
WORK="$(mktemp -d "$CACHE/run.XXXXXX")"
CREATED=()
udid=""
# However the run ends: every simulator this run created is shut down and deleted, and the work
# directory removed. Inline, as in native-ios-app.test.sh, so no trap-only function trips SC2329.
trap 'rc=$?; for udid in "${CREATED[@]:-}"; do
  [ -n "$udid" ] || continue
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
done
if [ "$rc" -eq 0 ]; then rm -rf "$WORK"; else echo "native-ios-ui: failure evidence retained at $WORK"; fi' EXIT

# ------------------------------------------------------------------------------------------------
# 1. Headless. The core, its fixtures and the app's Foundation-only screen sources compile into one
#    module named RichOSCore, so their `import RichOSCore` resolves to the files beside them.
# ------------------------------------------------------------------------------------------------
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import SwiftUI

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("  ok    \(what)") } else { failures += 1; print("  FAIL  \(what)") }
}

// Every round-12 fixture draws the screen round 12 names. `expect` is keyed by id; an id the core
// adds without an expectation here is a failure, so a new fixture cannot go unchecked.
typealias M = ScreenModel
let expect: [String: (M) -> Bool] = [
    "pair-intro": { $0.takeover == .pairIntro(problem: nil) && $0.scanner == nil && $0.dialog == nil },
    "pair-scanner": { $0.scanner == .looking },
    "pair-scanner-found": { $0.scanner == .found },
    "pair-camera-denied": { $0.dialog == .cameraDenied },
    "pair-progress": { $0.takeover == .pairProgress },
    "pair-words": { if case .pairWords(let w)? = $0.takeover { return w.count == 6 } else { return false } },
    "pair-refused": { $0.takeover == .pairIntro(problem: .refused) },
    "pair-blocked": { if case .pairBlocked(let n)? = $0.dialog { return n >= 1 } else { return false } },
    "pair-stale": { $0.takeover == .pairStale },
    "pair-consent": { $0.takeover == .consent },
    "conv-empty": { $0.takeover == nil && $0.thread.isEmpty && $0.cards.isEmpty },
    "conv-populated": { $0.takeover == nil && $0.thread.rows.count == 10 && $0.thread.following },
    "conv-pending": { m in
        let d = m.thread.rows.compactMap(\.delivery)
        return d.contains(.sending) && d.contains(.waiting) && d.contains(.needsAttention) },
    "conv-replying": { $0.thread.rows.last?.body == .replying },
    "conv-streaming": { if case .streaming? = $0.thread.rows.last?.body { return true } else { return false } },
    "conv-playing-reply": { $0.thread.rows.contains { if case .playing? = $0.audio { return true } else { return false } } },
    "conv-preparing-reply": { $0.thread.rows.contains { $0.audio == .preparing } },
    "conv-older-loading": { $0.thread.loadingOlder && !$0.thread.following },
    "conv-beginning": { $0.thread.reachedBeginning && !$0.thread.following },
    "conv-scrolled": { !$0.thread.following && $0.thread.rows.count == 10 },
    "conv-focused": { $0.thread.focusedID != nil },
    "conv-retry": { $0.connection?.kind == .reconnecting && $0.cards.contains(.waitingToSend(count: 1)) },
    "comp-idle": { $0.takeover == nil && $0.composer.draft.isEmpty && $0.voice == nil },
    "comp-typing": { $0.composer.hasDraft && !$0.composer.focused },
    "comp-keyboard": { $0.composer.hasDraft && $0.composer.focused },
    "comp-disabled": { $0.composer.disabledReason != nil && $0.connection?.kind == .incompatible },
    "comp-too-long": { m in if case .tooLong? = m.toast { return m.composer.isTooLong } else { return false } },
    "voice-press": { $0.voice?.phase == .pressed },
    "voice-permission": { $0.voice?.phase == .pressed && $0.dialog == nil },
    "voice-holding": { $0.voice?.phase == .held && ($0.voice?.elapsedMs ?? 0) > 0 },
    "voice-slide-left": { $0.voice?.phase == .held && ($0.voice?.cancelProgress ?? 0) > 0.5 },
    "voice-bin": { $0.voice?.phase == .ending(.canceled) },
    "voice-sent": { $0.voice?.phase == .ending(.sent) },
    "voice-too-short": { $0.voice?.phase == .ending(.tooShort) && $0.toast == .tooShort },
    "voice-slide-up": { $0.voice?.phase == .held && ($0.voice?.lockProgress ?? 0) > 0.5 },
    "voice-lock-transition": { $0.voice?.phase == .locked },
    "voice-locked": { $0.voice?.phase == .locked },
    "voice-locked-scrolled": { $0.voice?.phase == .locked && !$0.thread.following },
    "voice-locked-cancel": { $0.voice?.phase == .ending(.canceled) && $0.voice?.wasLocked == true },
    "voice-locked-send": { $0.voice?.phase == .ending(.sent) && $0.voice?.wasLocked == true },
    "voice-ceiling-warning": { $0.voice?.phase == .locked && $0.toast == .ceilingWarning },
    "voice-ceiling-reached": { $0.cards.contains { if case .keptRecording(let r) = $0 { return r.reason == .ceiling } else { return false } } },
    "voice-interrupted": { $0.cards.contains { if case .keptRecording(let r) = $0 { return r.reason == .interrupted } else { return false } } },
    "rec-card": { $0.cards.contains { if case .keptRecording(let r) = $0 { return r.reason == .unsent } else { return false } } },
    "rec-unsupported": { $0.connection?.kind == .voiceUnsupported && !$0.composer.voiceAvailable },
    "rec-mic-denied": { $0.cards.contains(.microphoneDenied) },
    "conn-reconnecting": { $0.connection?.kind == .reconnecting },
    "conn-offline": { $0.connection?.kind == .phoneOffline },
    "conn-service": { $0.connection?.kind == .serviceUnavailable },
    "conn-mac": { $0.connection?.kind == .macUnreachable },
    "conn-revoked": { $0.takeover == .removedFromMac },
    "conn-incompatible": { $0.connection?.kind == .incompatible && $0.composer.disabledReason != nil },
    "conn-cached": { $0.thread.cached && $0.connection?.kind == .phoneOffline },
    "notif-offer": { $0.cards.contains(.notificationOffer) },
    "notif-settings": { if case .settings(let s)? = $0.sheet { return s.notifications == .denied } else { return false } },
    "settings": { if case .settings? = $0.sheet { return true } else { return false } },
    "settings-forget": { $0.dialog == .forget },
    "settings-forget-blocked": { if case .forgetBlocked? = $0.dialog { return true } else { return false } },
    "upd-banner": { $0.banner != nil && $0.dialog == nil && $0.takeover == nil },
    "upd-dialog": { if case .update? = $0.dialog { return true } else { return false } },
    "upd-blocking": { if case .updateRequired? = $0.takeover { return true } else { return false } },
    "upd-feature-off": { $0.connection?.kind == .voicePaused && !$0.composer.voiceAvailable },
    "launch-cached": { $0.thread.cached && $0.thread.rows.count == 10 },
]
check(Fixture.all.count == 63, "the core has all 63 in-app round-12 fixtures (it has \(Fixture.all.count))")
for f in Fixture.all {
    guard let rule = expect[f.name] else { check(false, "\(f.name): no expectation for this fixture"); continue }
    check(rule(ScreenModel(state: f.state)), "\(f.name) draws its round-12 screen")
}
check(Set(expect.keys) == Set(Fixture.all.map(\.name)), "every expectation names a fixture the core has")

// The adopted T3 viewport geometry, with round 12's 80-point threshold.
do {
    let g = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 400, topInset: 20, bottomInset: 100)
    check(g.bottomOffset == 900, "bottom offset includes the bottom inset")
    check(g.showsScrollToBottom(at: 820), "80 points up shows Latest")
    check(!g.showsScrollToBottom(at: 821), "79 points up does not")
    let short = TranscriptViewportGeometry(contentHeight: 100, viewportHeight: 400, topInset: 20, bottomInset: 0)
    check(!short.showsScrollToBottom(at: -20), "a short conversation never shows Latest")
    check(g.restoredBottomOffset(after: nil, maintainsBottomAnchor: true, isInteracting: false) == 900, "follows on first layout")
    check(g.restoredBottomOffset(after: g, maintainsBottomAnchor: true, isInteracting: false) == nil, "nothing changed: no jump")
    let grown = TranscriptViewportGeometry(contentHeight: 1_300, viewportHeight: 400, topInset: 20, bottomInset: 100)
    check(grown.restoredBottomOffset(after: g, maintainsBottomAnchor: true, isInteracting: false) == 1_000, "a growing reply keeps following")
    check(grown.restoredBottomOffset(after: g, maintainsBottomAnchor: false, isInteracting: false) == nil, "not following: stays put")
    check(grown.restoredBottomOffset(after: g, maintainsBottomAnchor: true, isInteracting: true) == nil, "never fights a finger")
    let keyboard = TranscriptViewportGeometry(contentHeight: 1_200, viewportHeight: 400, topInset: 20, bottomInset: 400)
    check(keyboard.restoredBottomOffset(after: g, maintainsBottomAnchor: true, isInteracting: false) == 1_200, "the keyboard keeps the newest message in view")
}

// WCAG 2 contrast of every pairing, from the Palette the app draws with.
func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func rgb(_ color: Color, over: (Double, Double, Double)? = nil) -> (Double, Double, Double) {
    let r = color.resolve(in: EnvironmentValues())
    let a = Double(r.opacity)
    let (fr, fg, fb) = (Double(r.red), Double(r.green), Double(r.blue))
    guard let b = over, a < 1 else { return (fr, fg, fb) }
    return (fr * a + b.0 * (1 - a), fg * a + b.1 * (1 - a), fb * a + b.2 * (1 - a))
}
func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2) }
func ratio(_ fg: Color, _ bg: Color, over: Color? = nil) -> Double {
    let base = rgb(bg, over: over.map { rgb($0) })
    let f = rgb(fg, over: base)
    let (l1, l2) = (lum(f), lum(base))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

for p in [Palette.sovereign, Palette.daybreak] {
    let name = p.appearance == .dark ? "dark" : "light"
    func text(_ label: String, _ fg: Color, _ bg: Color, over: Color? = nil) {
        let r = ratio(fg, bg, over: over)
        check(r >= 4.5, String(format: "%@ text  %-58@ %5.2f:1 (floor 4.5)", name, label as NSString, r))
    }
    func indicator(_ label: String, _ fg: Color, _ bg: Color, over: Color? = nil) {
        let r = ratio(fg, bg, over: over)
        check(r >= 3.0, String(format: "%@ ind.  %-58@ %5.2f:1 (floor 3.0)", name, label as NSString, r))
    }
    text("ink on ground (headings, ledes, dialogs, words)", p.ink, p.ground)
    text("ink on surface (Rich's bubbles, cards, rows, Latest)", p.ink, p.surface)
    text("ink on your bubble", p.ink, p.mine)
    text("ink-soft on ground (hints, steps' details, footers)", p.inkSoft, p.ground)
    text("ink-soft on surface (placeholder, timestamps, status line)", p.inkSoft, p.surface)
    text("ink-soft on your bubble (timestamps, Sending…)", p.inkSoft, p.mine)
    text("on-signal on signal (primary buttons, Hear it, Update)", p.onSignal, p.signal)
    text("danger on ground (Not sent)", p.danger, p.ground)
    text("danger on surface (Forget this pairing)", p.danger, p.surface)
    text("eyebrow on ground (gold dark, ink light)", p.accentGlyph, p.ground)
    indicator("signal on surface (the microphone inside the capsule)", p.signal, p.surface)
    indicator("signal on ground (thinking dots, caret, reference bar)", p.signal, p.ground)
    // The play button on your bubble: gold alone in dark; with its 1 pt ink edge in light, where gold
    // on the gold-washed plane is under 3:1 (printed below).
    indicator("play button edge on your bubble", p.playEdgeOnMine ?? p.signal, p.mine)
    indicator("on-signal glyph on signal (mic, send, play)", p.onSignal, p.signal)
    indicator("danger on surface (recording dot, bin, alert mark)", p.danger, p.surface)
    indicator("ink-soft ring on surface (disabled microphone, the +)", p.inkSoft, p.surface)
    indicator("ink knob 72% on surface (a switch that is off)", p.ink.opacity(0.72), p.surface)
    indicator("accent glyph on surface (consent and menu icons)", p.accentGlyph, p.surface)
    indicator("ink icons on surface (settings rows, lock pill)", p.ink, p.surface)
}
// The scanner and the photo overlays are always dark (round 12 `.scanner`; attachments NOTES A5).
do {
    let ink = Palette.sovereign.ink, scene = Color(hex: 0x060A12)
    let chip = Color(hex: 0x141E34).opacity(0.85)
    let disc = Color(red: 8 / 255, green: 12 / 255, blue: 22 / 255).opacity(0.8)
    check(ratio(ink, scene) >= 4.5, String(format: "scanner caption on the scene %5.2f:1", ratio(ink, scene)))
    check(ratio(ink.opacity(0.78), scene) >= 4.5, String(format: "scanner second line on the scene %5.2f:1", ratio(ink.opacity(0.78), scene)))
    check(ratio(ink, chip, over: scene) >= 4.5, String(format: "scanner buttons %5.2f:1", ratio(ink, chip, over: scene)))
    check(ratio(Color(hex: 0xC2A35C), scene) >= 3, String(format: "gold viewfinder on the scene %5.2f:1", ratio(Color(hex: 0xC2A35C), scene)))
    check(ratio(ink, disc, over: .white) >= 4.5, String(format: "time and glyphs on a photo's disc, over white %5.2f:1", ratio(ink, disc, over: .white)))
    check(ratio(Color(hex: 0xC2A35C), disc, over: .white) >= 3, String(format: "upload ring on the disc, over white %5.2f:1", ratio(Color(hex: 0xC2A35C), disc, over: .white)))
}
// Declared, not asserted (round-12 NOTES "Declared exemptions"): the dark hairline `trim` on the
// ground and surface (GAP 1; no control is identified by a line alone), the light-mode gold halo
// behind the recording circle, and the waveform bars (a picture of the audio; its length is text).
print(String(format: "  info  dark trim line on ground %.2f:1, on surface %.2f:1 (GAP 1, declared)",
             ratio(Palette.sovereign.trim, Palette.sovereign.ground), ratio(Palette.sovereign.trim, Palette.sovereign.surface)))
print(String(format: "  info  gold alone on your bubble in light %.2f:1, so it wears the ink edge",
             ratio(Palette.daybreak.signal, Palette.daybreak.mine)))
print(String(format: "  info  waveform bar 32%% ink on your bubble: dark %.2f:1, light %.2f:1 (decoration, declared)",
             ratio(Palette.sovereign.ink.opacity(0.32), Palette.sovereign.mine), ratio(Palette.daybreak.ink.opacity(0.32), Palette.daybreak.mine)))

if failures > 0 { print("  \(failures) headless check(s) failed"); exit(1) }
print("  headless: all checks passed")
SWIFT

HEADLESS_BIN="$WORK/headless"
START=$(date +%s)
CORE_SOURCES=()
while IFS= read -r f; do CORE_SOURCES+=("$f"); done < <(find "$NATIVE/Core/Sources/RichOSCore" "$NATIVE/Core/Sources/RichOSFixtures" -name '*.swift' | sort)
if ! xcrun swiftc -Onone -D DEBUG -module-name RichOSCore -target "$(uname -m)-apple-macos14" \
    -module-cache-path "$CACHE/module-cache" -suppress-warnings \
    "${CORE_SOURCES[@]}" \
    "$NATIVE/App/Design/Palette.swift" \
    "$NATIVE/App/Features/Root/ScreenModel.swift" \
    "$NATIVE/App/Features/Attachments/AttachmentModel.swift" \
    "$NATIVE/App/Features/Conversation/TranscriptViewportGeometry.swift" \
    "$WORK/main.swift" -o "$HEADLESS_BIN" > "$WORK/headless-build.log" 2>&1; then
  tail -30 "$WORK/headless-build.log"
  echo "  FAIL  native-ios-ui: the headless checks did not compile"
  exit 1
fi
echo "native-ios-ui: headless (compiled in $(( $(date +%s) - START )) s)"
"$HEADLESS_BIN"
# The split and the by-name proof the simulator part relies on, against fixtures (no simulator).
if ! python3 "$DIR/lib/ios_ui_shards.py" selftest; then
  echo "  FAIL  native-ios-ui: the shard split or its proof"; exit 1
fi

[ "$MODE" = headless ] && exit 0

# ------------------------------------------------------------------------------------------------
# 2. Simulator
# ------------------------------------------------------------------------------------------------
[ -f "$NATIVE/project.yml" ] || not_run "native-ios/project.yml is not in this tree yet (stream I1)"
command -v xcodegen >/dev/null 2>&1 || not_run "xcodegen is not installed"
RUNTIME="$(xcrun simctl list runtimes available | sed -n 's/.*\(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\).*/\1/p' | tail -1)"
[ -n "$RUNTIME" ] || not_run "no iOS simulator runtime is installed"

PROJECT_DIR="$CACHE/project"
mkdir -p "$PROJECT_DIR"
# Generated exactly as `bin/rios` generates it: no --project-root, and RICHOS_NATIVE_IOS_ROOT set, which
# I3's Release/platform.yml expands into the extensions' entitlement paths.
export RICHOS_NATIVE_IOS_ROOT="$NATIVE"
xcodegen generate --spec "$NATIVE/project.yml" --project "$PROJECT_DIR" --quiet
DERIVED="$CACHE/derived"
SHOTS="$CACHE/screenshots/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SHOTS"

START=$(date +%s)
# CEO, 2026-09-22: native builds run at lowered priority for this build window.
nice -n 10 xcodebuild -project "$PROJECT_DIR/RichOSNative.xcodeproj" -scheme RichOSNative \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$CACHE/SourcePackages" CODE_SIGN_IDENTITY=- \
  build-for-testing > "$WORK/build.log" 2>&1 || {
    { grep -E ' error: |error:' "$WORK/build.log" || tail -30 "$WORK/build.log"; } | head -30
    echo "  FAIL  native-ios-ui: build"; exit 1; }
echo "native-ios-ui: built for testing in $(( $(date +%s) - START )) s"

STATUS=0
# ------------------------------------------------------------------------------------------------
# The simulators: every device's tests are split across RICHOS_IOS_UI_SHARDS simulators of that
# device (default 2), and every simulator runs at the same time.
#
# MEASURED, 2026-09-23, this Mac, standalone: the build is 23 s cold and 5 s warm, a boot about
# 30 s, and the tests the rest — 661 s for one device's 42 tests on one simulator, 686 s for the
# other, one after the other: 1428 s for the suite (1438 s in the 184-commit land). A running UI
# test waits on the app and on XCUITest rather than computing (user CPU 10-15% of the Mac with a
# simulator mid-run), so the time is bought back with more simulators, not more cores — the
# shape T3 Code uses for its own suite (adoption ledger §2.3: "sharding spreads them over separate
# runners instead of separate workers"), so no two shards ever share a device. Each shard is its
# own simulator, created, booted headless, shut down and deleted by this run, as before.
#
#   simulators per device   wall (whole suite)
#   1, one device at a time      1428 s   (the old shape)
#   2, all four at once           535 s   (the default)
#   3, all six at once            970 s   (six first boots took 255 s together, and another
#                                          agent's simulators were running at the time)
# Past two, first boots and the host's simulator services are the bottleneck, not the tests.
#
# NOTHING IS DROPPED BY SPLITTING. The test list comes from xcodebuild itself (-enumerate-tests),
# never from the Swift sources, and after the run the tests the result bundles report for a device
# must equal that list, name for name. A shard that ran fewer tests than it was given is a failure.
# `--only` runs unsplit, as before; so does RICHOS_IOS_UI_SHARDS=1.
# ------------------------------------------------------------------------------------------------
SHARDS="${RICHOS_IOS_UI_SHARDS:-2}"
case "$SHARDS" in ''|*[!0-9]*|0) echo "native-ios-ui: RICHOS_IOS_UI_SHARDS must be a positive integer" >&2; exit 64 ;; esac
[ "${#ONLY[@]}" -gt 0 ] && SHARDS=1
XCTESTRUN="$(find "$DERIVED/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)"
[ -n "$XCTESTRUN" ] || { echo "  FAIL  native-ios-ui: build-for-testing left no .xctestrun in $DERIVED/Build/Products"; exit 1; }
SELECT=("-only-testing:RichOSNativeUITests" "-only-testing:RichOSNativeTests")
[ "${#ONLY[@]}" -gt 0 ] && SELECT=("${ONLY[@]}")
# Per-test seconds from the last run of this checkout, so the split is balanced by what each test
# costs rather than by how many there are. Missing on a first run: the split is then by count.
TIMES="$CACHE/test-seconds.tsv"

# Create destinations for enumeration; boot only after acquiring a worker lease.
SIM_DEV=(); SIM_UDID=(); SIM_TYPE=()
for DEVICE in "${DEVICES[@]}"; do
  TYPE="com.apple.CoreSimulator.SimDeviceType.$(printf '%s' "$DEVICE" | sed 's/[() ]/-/g; s/--*/-/g; s/-$//')"
  s=1
  while [ "$s" -le "$SHARDS" ]; do
    UDID="$(xcrun simctl create "rios-ui-$$-${TYPE##*.}-$s" "$TYPE" "$RUNTIME")"
    CREATED+=("$UDID")
    # Registered to this shell before it boots, so the engine removes it if this run is killed
    # before its trap (§54; richos/engine/scripts/lib/testdevices.py).
    python3 "$ROOT/richos/engine/scripts/lib/testdevices.py" register --kind ios-simulator --id "$UDID" \
      --owner-pid $$ --script native-ios-ui.test.sh >/dev/null || exit 1
    SIM_DEV+=("$DEVICE"); SIM_UDID+=("$UDID"); SIM_TYPE+=("${TYPE##*.}")
    s=$((s + 1))
  done
done
# The test list, from xcodebuild itself, before simulators boot (it needs a destination to
# resolve, not a booted one: measured 2026-09-23 on a created, never-booted simulator).
if [ "$SHARDS" -gt 1 ]; then
  ( if xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=${SIM_UDID[0]}" \
         -derivedDataPath "$WORK/dd-enumerate" "${SELECT[@]}" -enumerate-tests -test-enumeration-style flat \
         -test-enumeration-format json -test-enumeration-output-path "$WORK/tests.json" > "$WORK/enumerate.log" 2>&1
    then echo 0 > "$WORK/enumerate.rc"; else echo 1 > "$WORK/enumerate.rc"; fi ) &
fi
wait
# The list, and the split: one file of -only-testing arguments per shard. (Listed while the
# simulators booted, above.)
if [ "$SHARDS" -gt 1 ] && [ "$(cat "$WORK/enumerate.rc" 2>/dev/null)" != 0 ]; then
  tail -20 "$WORK/enumerate.log"
  echo "  FAIL  native-ios-ui: xcodebuild could not list the tests, so they cannot be split without risking one"
  exit 1
fi
if ! python3 "$DIR/lib/ios_ui_shards.py" split "$WORK" "$SHARDS" "$TIMES" "${SELECT[@]}"; then
  echo "  FAIL  native-ios-ui: the test list could not be split"; exit 1
fi

# One lease covers boot, UI execution and deletion. Idle booted simulators are not free.
cat > "$WORK/run-simulator.sh" <<'SIMULATOR'
#!/usr/bin/env bash
set -euo pipefail
work="$1"; xctestrun="$2"; i="$3"; udid="$4"; shift 4
trap 'rc=$?; xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || rc=1
  exit "$rc"' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleLocale -string en_US
xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleLanguages -array en-US
xcrun simctl privacy "$udid" grant microphone dev.richos.native.ios >/dev/null 2>&1 || true
TZ=UTC xcodebuild test-without-building -xctestrun "$xctestrun" -destination "id=$udid" \
  -derivedDataPath "$work/dd-$i" -resultBundlePath "$work/result-$i.xcresult" \
  -parallel-testing-enabled NO "$@"
SIMULATOR
START=$(date +%s)
for i in "${!SIM_UDID[@]}"; do
  s=$(( i % SHARDS + 1 ))
  ARGS=()
  while IFS= read -r a; do [ -n "$a" ] && ARGS+=("$a"); done < "$WORK/shard-$s.args"
  # Under proof-run.py (RICHOS_WORKER_TOKENS set), the simulators count against the run the way a
  # mutation pool's workers do (richos/engine/scripts/lib/worker_tokens.py): one runs on this
  # suite's own free slot, whichever simulator holds it, and every other on a token of the budget.
  TOKEN=()
  if [ -n "${RICHOS_WORKER_TOKENS:-}" ]; then
    TOKEN=(python3 "${RICHOS_WORKER_TOKENS_TOOL:-$ROOT/richos/engine/scripts/lib/worker_tokens.py}" run
           "$RICHOS_WORKER_TOKENS" --free "$WORK/free.lock" --)
  fi
  ( T0=$(date +%s)
    if ${TOKEN[@]+"${TOKEN[@]}"} bash "$WORK/run-simulator.sh" "$WORK" "$XCTESTRUN" "$i" "${SIM_UDID[$i]}" \
         "${ARGS[@]}" > "$WORK/test-$i.log" 2>&1; then rc=0; else rc=$?; fi
    echo "$rc" > "$WORK/test-$i.rc"; echo $(( $(date +%s) - T0 )) > "$WORK/test-$i.secs" ) &
done
wait

# Per device: every shard green, and the tests its bundles report are exactly the tests listed.
if python3 "$DIR/lib/ios_ui_shards.py" verify "$WORK" "$SHARDS" "$TIMES" "${DEVICES[@]}"; then STATUS=0; else STATUS=1; fi
for i in "${!SIM_UDID[@]}"; do
  if [ "$(cat "$WORK/test-$i.rc" 2>/dev/null)" != 0 ]; then
    { grep -E "error:|Test Case .* failed" "$WORK/test-$i.log" || true; } | head -40
  fi
done
echo "native-ios-ui: every simulator finished in $(( $(date +%s) - START )) s"

# Screenshots, per device, named after their screen (`se-dark-conv-populated.png`) so each sits
# beside the mockup of the same name; the failure evidence keeps its test's name.
for i in "${!SIM_UDID[@]}"; do
  OUT="$SHOTS/${SIM_TYPE[$i]}"
  mkdir -p "$OUT/shard-$i"
  xcrun xcresulttool export attachments --path "$WORK/result-$i.xcresult" --output-path "$OUT/shard-$i" > /dev/null 2>&1 || true
  python3 "$DIR/lib/ios_ui_shards.py" name-shots "$OUT/shard-$i" "$OUT" || true
  rm -rf "$OUT/shard-$i"
done
for i in "${!SIM_UDID[@]}"; do
  xcrun simctl shutdown "${SIM_UDID[$i]}" > /dev/null 2>&1 || true
  xcrun simctl delete "${SIM_UDID[$i]}" > /dev/null 2>&1 || true
  CREATED=("${CREATED[@]/${SIM_UDID[$i]}}")
done
echo "native-ios-ui: screenshots in $SHOTS"
exit "$STATUS"
