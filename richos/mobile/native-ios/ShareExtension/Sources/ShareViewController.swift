import SwiftUI
import UIKit
import RichOSCore

/// "Share to Rich": the extension's entry point (NSExtensionPrincipalClass). It hosts the SwiftUI
/// sheet and ends the request when the sheet is done.
///
/// No signed connection to the Mac exists in this build yet: the device key and the request signer
/// are the core's (stream I1) and not written. So `transport` is `nil`, every share is written to
/// the inbox and the sheet says "Saved for Rich … the next time you open RichOS" — never "Sent" —
/// until the core's `APIClient` (a `MacRequests`) is passed here. Everything after that (uploads, the commit,
/// the 3-second rule, "Sent to Rich" only on the commit's 200) is built and tested now.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(inbox: ShareInbox.shared, transport: nil) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        self.model = model
        let palette = Palette.for(model.context.appearance == "light" ? .light : .dark)
        let host = UIHostingController(rootView: ShareSheetView(model: model).palette(palette))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }
}
