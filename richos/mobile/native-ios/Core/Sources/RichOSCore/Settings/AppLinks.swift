import Foundation

/// Every address outside the app that RichConnect opens, in ONE place: the privacy policy, support,
/// and this app's App Store listing (Settings rows, the update notices, `pair-stale`).
///
/// **PLACEHOLDERS — the CEO fills these before submission.** None of the three final addresses is
/// settled (App Store listing drafts, blockers 1-3: the policy and support pages are not hosted yet,
/// and the App Store Connect record, which assigns the numeric App ID, does not exist). Each value
/// below is a stand-in that opens something harmless; `placeholders` names the ones still unset so a
/// release check can refuse a build that ships them.
public enum AppLinks {
    /// PLACEHOLDER(CEO): the hosted privacy policy (Apple 5.1.1(i) requires a link inside the app).
    public static let privacyPolicy = URL(string: "https://richos.ceo/privacy")!

    /// PLACEHOLDER(CEO): the support page, with the contact details Apple requires.
    public static let support = URL(string: "https://richos.ceo/support")!

    /// PLACEHOLDER(CEO): the numeric Apple ID App Store Connect assigns when the record is created.
    public static let appStoreID = "0000000000"

    /// This app's listing. On iPhone updates come only from the App Store, so "Check for updates"
    /// and "Update in App Store" open it; an apps.apple.com link opens in the App Store app.
    public static var appStore: URL { URL(string: "https://apps.apple.com/app/id\(appStoreID)")! }

    /// The constants above still holding a stand-in. Empty once the CEO has filled all three.
    public static let placeholders: [String] = ["privacyPolicy", "support", "appStoreID"]

    /// Where an "open" effect goes, or `nil` for any other effect.
    public static func destination(of effect: Effect) -> URL? {
        switch effect {
        case .openAppStore: return appStore
        case .openSupport: return support
        case .openPrivacyPolicy: return privacyPolicy
        default: return nil
        }
    }
}
