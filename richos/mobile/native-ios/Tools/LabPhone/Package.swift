// swift-tools-version: 6.0
//
// lab-phone: the iPhone app's own core (AppStore, NetworkEffects, URLSessionTransport) run headless on
// this Mac against the ISOLATED lab Mac, through the same managed route the phone uses. It pairs, then
// repeats the send-then-Home cycle the iPhone walks check (iPhone walk D3), printing the core's own
// account of each send (`AppStore.sendLog`). With `qa/lab-pause.py --log` following its marks, a
// message is kept in flight across "Home" exactly as on the phone, in about two minutes, with no
// phone, no UI-automation approval and no background allowance spent on the test phone.
//
// What it cannot show: iOS itself (UIKit's background time, suspension, the phone's radio). A send
// that leaves here but stays on the phone points at the phone; one that stays here points at the core
// or the route. See Sources/lab-phone/main.swift for usage.
import PackageDescription

let package = Package(
    name: "LabPhone",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Core")],
    targets: [
        .executableTarget(name: "lab-phone", dependencies: [
            .product(name: "RichOSCore", package: "Core"),
            .product(name: "RichOSFixtures", package: "Core"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
