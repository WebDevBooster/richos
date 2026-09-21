import UIKit
import AVFoundation

// A visible camera sheet returns text to the same pairing validator used by the CLI.
// It never follows the QR URL or pairs a Mac automatically.
final class PairScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate, UIAdaptivePresentationControllerDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.richos.mobile.qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    var completion: ((String?, String?) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel scanning", for: .normal)
        cancel.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(cancel)
        NSLayoutConstraint.activate([cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor), cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                guard granted else { self.finish(nil, "Camera access is denied. Enable RichOS camera access in Settings, or paste the pairing link."); return }
                do {
                    guard let camera = AVCaptureDevice.default(for: .video) else { throw NSError(domain: "RichOS", code: 1) }
                    let input = try AVCaptureDeviceInput(device: camera), output = AVCaptureMetadataOutput()
                    guard self.capture.canAddInput(input), self.capture.canAddOutput(output) else { throw NSError(domain: "RichOS", code: 2) }
                    self.capture.addInput(input); self.capture.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                    let layer = AVCaptureVideoPreviewLayer(session: self.capture); layer.videoGravity = .resizeAspectFill
                    self.view.layer.insertSublayer(layer, at: 0); self.preview = layer; self.view.setNeedsLayout()
                    self.queue.async { self.capture.startRunning() }
                } catch { self.finish(nil, "Camera could not start. Paste the pairing link instead.") }
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); finish(nil, "Scanning cancelled") }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil, "Scanning cancelled") }
    @objc private func cancelScan() { finish(nil, "Scanning cancelled") }
    private func finish(_ text: String?, _ error: String?) {
        guard !done else { return }; done = true
        queue.async { self.capture.stopRunning() }
        completion?(text, error); completion = nil; dismiss(animated: true)
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { finish(value, nil) }
    }
}
