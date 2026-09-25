import Foundation

/// Every sentence the nameplate's one connection line can say, in ONE place (round 12's `screens.js`
/// group 7, `rec-unsupported`, `upd-feature-off`; D05's line is Android's `Header.kt` `noticeText`,
/// word for word). Each is the plain part, then the reassurance drawn in ink. Foundation only, so the
/// headless checks in `native-ios-ui.test.sh` read the same words the screen draws.
enum ConnectionWords {
    static func words(_ kind: ScreenModel.ConnectionLine.Kind) -> (lead: String, reassurance: String) {
        switch kind {
        case .reconnecting: return ("Reconnecting…", "Your messages are saved.")
        case .phoneOffline: return ("No internet connection.", "Messages stay on this phone.")
        case .serviceUnavailable: return ("RichOS Connect is temporarily unavailable.", "Messages stay on this phone.")
        case .macUnreachable: return ("Your Mac cannot be reached. Keep it awake with RichOS running.", "Messages stay on this phone.")
        case .incompatible: return ("This Mac needs a newer RichOS app.", "Your queued messages are kept.")
        case .voiceUnsupported: return ("This Mac cannot accept voice yet.", "Your recording stays on this phone.")
        case .voicePaused: return ("Voice messages are paused while we fix a problem.", "Typing works.")
        case .attachmentsUnsupported: return ("This Mac needs a newer RichOS for photos and files.", "Text and voice work.")
        // D05: said only when the OS shows no Tailscale tunnel on this phone, on the Tailscale route, once
        // the trouble has lasted 3 s. It says what the phone knows ("not on Tailscale") and names the one
        // fix. Never pulsing: nothing is happening that the person should watch.
        case .tailscaleOff: return ("This phone is not on Tailscale. Turn Tailscale on to reach your Mac.", "Messages stay on this phone.")
        }
    }
}
