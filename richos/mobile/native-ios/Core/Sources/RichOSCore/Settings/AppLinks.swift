import Foundation

/// Every address outside the app that RichConnect opens, in ONE place: the privacy policy, support,
/// and this app's App Store listing (Settings rows, the update notices, `pair-stale`).
///
/// The policy and support pages are published. The numeric ID belongs to the
/// RichConnect for RichOS record in App Store Connect; its listing opens once released.
public enum AppLinks {
    /// The hosted privacy policy (Apple 5.1.1(i) requires a link inside the app).
    public static let privacyPolicy = URL(string: "https://richos.ceo/privacy")!

    /// The support page, with the contact details Apple requires.
    public static let support = URL(string: "https://richos.ceo/support")!

    /// The numeric Apple ID assigned by App Store Connect.
    public static let appStoreID = "6818948353"

    /// This app's listing. On iPhone updates come only from the App Store, so "Check for updates"
    /// and "Update in App Store" open it; an apps.apple.com link opens in the App Store app.
    public static var appStore: URL { URL(string: "https://apps.apple.com/app/id\(appStoreID)")! }

    /// Whether the listing above is live in the App Store. Until it is, the listing answers 404, so
    /// Settings shows no "Check for updates" row (App Review rehearsal 2026-10-04, row 7; Apple 2.1(a):
    /// "fully functional URLs"). Set it to `true` in the first build after the app is released.
    public static let appStoreListingLive = false

    /// Unresolved destinations for the release check. All three have been configured.
    public static let placeholders: [String] = []

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
