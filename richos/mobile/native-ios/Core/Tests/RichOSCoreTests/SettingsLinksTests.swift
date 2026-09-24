import Foundation
import Testing
@testable import RichOSCore

/// Every Settings row does something (App Store listing drafts, blocker 4: a reviewer who taps a
/// dead row can reject under Guideline 2.1; 5.1.1(i) requires a privacy policy link in the app).
@Suite struct SettingsLinksTests {
    func effects(_ action: Action, in state: AppState = .initial) -> [Effect] {
        Reducer.reduce(state, action).effects.filter { $0 != .persist }
    }

    @Test func checkForUpdatesOpensTheAppStoreListing() {
        // On iPhone updates come from the App Store; the row opens the listing.
        #expect(effects(.checkForUpdates) == [.openAppStore])
        #expect(AppLinks.destination(of: .openAppStore) == AppLinks.appStore)
    }

    @Test func supportOpensTheSupportPage() {
        #expect(effects(.openSupport) == [.openSupport])
        #expect(AppLinks.destination(of: .openSupport) == AppLinks.support)
    }

    @Test func privacyPolicyOpensThePolicy() {
        #expect(effects(.openPrivacyPolicy) == [.openPrivacyPolicy])
        #expect(AppLinks.destination(of: .openPrivacyPolicy) == AppLinks.privacyPolicy)
    }

    @Test func theRowsChangeNoStateAndWriteNothing() {
        for action in [Action.checkForUpdates, .openSupport, .openPrivacyPolicy, .openAppStore] {
            let (next, fx) = Reducer.reduce(.initial, action)
            #expect(next == .initial)
            #expect(!fx.contains(.persist))
        }
    }

    @Test func everyDestinationIsHTTPSAndTheListingIsThisAppsNumericID() {
        for url in [AppLinks.privacyPolicy, AppLinks.support, AppLinks.appStore] {
            #expect(url.scheme == "https")
            #expect(url.host?.isEmpty == false)
        }
        let numeric = AppLinks.appStoreID.allSatisfy { $0.isNumber }
        #expect(numeric)
        #expect(AppLinks.appStore.absoluteString == "https://apps.apple.com/app/id\(AppLinks.appStoreID)")
    }

    @Test func thePlaceholdersAreNamedUntilTheCEOFillsThem() {
        // A release check refuses a build while this is not empty; today all three are stand-ins.
        #expect(Set(AppLinks.placeholders) == ["privacyPolicy", "support", "appStoreID"])
    }

    @Test func theCommandLineNamesTheNewRows() throws {
        #expect(try CoreJSON.decode(Action.self, from: Data(#"{"type":"check-updates"}"#.utf8)) == .checkForUpdates)
        #expect(try CoreJSON.decode(Action.self, from: Data(#"{"type":"privacy-policy"}"#.utf8)) == .openPrivacyPolicy)
    }
}
