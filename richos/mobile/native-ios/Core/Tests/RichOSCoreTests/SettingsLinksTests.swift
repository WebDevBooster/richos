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

/// I04 (native acceptance r1, the physical iPhone SE): "Not now" on the notification offer is never a
/// one-way door, and the app's notification state stays true to iOS's own answer.
@Suite struct NotificationWayBackTests {
    func paired(_ status: Notifications.Status, dismissed: Bool = false) -> AppState {
        var s = AppState.initial
        s.pairing = .paired
        s.notifications = Notifications(status: status, offerDismissed: dismissed)
        return s
    }

    @Test func afterNotNowTheSwitchStillAsksIOSAndTheOfferStaysAnswered() {
        let answered = Reducer.reduce(paired(.notAsked), .dismissNotificationOffer).state
        #expect(answered.notifications.offerDismissed)
        #expect(answered.notifications.status == .notAsked)
        // The Settings switch sends the same action the offer's "Turn on notifications" sends.
        let (asking, effects) = Reducer.reduce(answered, .turnOnNotifications)
        #expect(asking.notifications.status == .turningOn)
        #expect(effects.contains(.requestNotifications(previews: true)))
        #expect(asking.notifications.offerDismissed, "the offer is not put back")
    }

    @Test func allowedAgainInIPhoneSettingsRegistersAgainWithoutAsking() {
        let denied = paired(.denied, dismissed: true)
        #expect(NotificationPermissionCheck.action(system: .allowed, state: denied) == .turnOnNotifications)
        let (next, effects) = Reducer.reduce(denied, .turnOnNotifications)
        #expect(next.notifications.status == .turningOn)
        #expect(effects.contains(.requestNotifications(previews: true)))
    }

    @Test func turnedOffInIPhoneSettingsReadsAsDenied() {
        #expect(NotificationPermissionCheck.action(system: .denied, state: paired(.on)) == .notificationsResult(.denied))
        #expect(NotificationPermissionCheck.action(system: .denied, state: paired(.serviceUnavailable)) == .notificationsResult(.denied))
    }

    @Test func anAnswerIOSForgotLeavesTheAppsOwnSwitch() {
        #expect(NotificationPermissionCheck.action(system: .notDetermined, state: paired(.denied)) == .notificationsResult(.off))
    }

    @Test func nothingChangesWhenIOSAgreesAndNotNowIsNeverReopened() {
        let quiet: [(Notifications.Status, SystemNotificationPermission)] = [
            (.on, .allowed), (.on, .notDetermined), (.denied, .denied), (.off, .allowed), (.off, .denied), (.off, .notDetermined),
            (.notAsked, .notDetermined), (.notAsked, .allowed), (.notAsked, .denied), (.turningOn, .allowed),
            (.turningOn, .notDetermined), (.unsupported, .allowed), (.appleUnavailable, .allowed),
        ]
        for (status, system) in quiet {
            #expect(NotificationPermissionCheck.action(system: system, state: paired(status, dismissed: true)) == nil,
                    "\(status) with iOS \(system) must change nothing")
        }
        var unpaired = paired(.denied)
        unpaired.pairing = .unpaired
        #expect(NotificationPermissionCheck.action(system: .allowed, state: unpaired) == nil)
    }
}
