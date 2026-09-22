// The camera half of this file is adapted from T3 Code (https://github.com/pingdotgg/t3code) at
// 2eb6a53343ffb4ce747617746ee85433115ad18f, apps/swift-ios/Features/Connection/QRCodeScannerView.swift,
// MIT License, Copyright (c) 2026 T3 Tools Inc. Adoption ledger §2.8 P1: ADOPT AS-IS, swapping T3's copy
// and typography for RichOS's. `QRScannerCameraView` and `QRScannerViewController` below are T3's
// unchanged except the queue label; the SwiftUI screen above them is round 12's `pair-scanner` design
// (T3's system symbols and system type are replaced: ceo-decisions §22). It returns only the scanned
// text; the six-word check stays entirely RichOS's.
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera with a gold viewfinder; the beam says it is looking (`pair-scanner`), and the
/// viewfinder flashes closed once when it finds the code (`pair-scanner-found`).
struct ScannerView: View {
    let state: ScreenModel.Scanner
    /// A simulator has no camera. Debug simulator builds draw round 12's pretend Mac screen in its
    /// place, so a screenshot of `pair-scanner` can be compared with the mockup; a phone always uses the
    /// camera.
    var pretendScene: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()
    let send: (Intent) -> Void

    @State private var availability: QRScannerAvailability = .checking
    private let fixedInk = Palette.sovereign.ink  // the scanner is always dark (round 12 `.scanner`)
    private let gold = Color(hex: 0xC2A35C)

    var body: some View {
        ZStack {
            Color(hex: 0x060A12).ignoresSafeArea()
            if pretendScene {
                PretendMacScene().ignoresSafeArea()
            } else {
                QRScannerCameraView(availability: $availability) { text in send(.scanned(text)) }
                    .ignoresSafeArea()
            }
            GeometryReader { proxy in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.45)
                if pretendScene || availability == .ready {
                    Viewfinder(found: state == .found, gold: gold).position(center)
                }
                VStack(spacing: 6) {
                    Text(state == .found ? "Found it." : "Point the camera at the code on your Mac.")
                        .type(Typography.body)
                        .foregroundStyle(fixedInk)
                    Text(state == .found ? "Pairing with your Mac…" : "It is on the screen of the Mac you want to reach.")
                        .type(Typography.read)
                        .foregroundStyle(fixedInk.opacity(0.78))
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: proxy.size.width - 48)
                .position(x: center.x, y: center.y + 150 + 30)
                .accessibilityElement(children: .combine)
                .opacity(pretendScene || availability == .ready ? 1 : 0)
            }
            if !pretendScene, availability != .ready { unavailable }
            VStack(spacing: 0) {
                HStack {
                    Button { send(.closeScanner) } label: {
                        IconView(.close, size: 22).foregroundStyle(fixedInk)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color(hex: 0x141E34).opacity(0.85)))
                            .overlay(Circle().strokeBorder(fixedInk.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Close the scanner")
                    .accessibilityIdentifier("scanner.close")
                    Spacer()
                    Text("Scan the code").type(Typography.body.weight(600)).foregroundStyle(fixedInk)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Color.clear.frame(width: 52, height: 52)
                }
                .padding(.horizontal, 14).padding(.top, 8)
                Spacer()
                Button { send(.usePairingLink) } label: {
                    IconLabel(icon: .link, text: "Use a pairing link instead")
                        .type(Typography.read.weight(600))
                        .foregroundStyle(fixedInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Color(hex: 0x141E34).opacity(0.85)))
                        .overlay(Capsule().strokeBorder(fixedInk.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(PressScale(scale: 0.97))
                .padding(.horizontal, 24).padding(.bottom, 18)
                .accessibilityIdentifier("scanner.link")
            }
        }
        .environment(\.palette, .sovereign)
        .accessibilityIdentifier("scanner")
        .onChange(of: availability) { _, value in
            if value == .denied { send(.cameraDenied) }
        }
    }

    @ViewBuilder private var unavailable: some View {
        VStack(spacing: 14) {
            switch availability {
            case .checking:
                Spinner(size: 28)
            case .unavailable:
                IconView(.camera, size: 34).foregroundStyle(fixedInk)
                Text("The camera is not available").type(Typography.answer.weight(600)).foregroundStyle(fixedInk)
                Text("Use a pairing link instead.").type(Typography.read).foregroundStyle(fixedInk.opacity(0.78))
            case .denied, .ready:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
    }
}

/// Four gold corners 250 pt apart, a beam sweeping between them (2.2 s), and one closing flash when
/// the code is found (500 ms).
private struct Viewfinder: View {
    let found: Bool
    let gold: Color
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Corner().stroke(gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(Double(i) * 90))
                    .offset(x: (i == 1 || i == 2) ? 108 : -108, y: i >= 2 ? 108 : -108)
            }
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                let k = 0.5 - 0.5 * cos(t * 2 * .pi)
                LinearGradient(colors: [gold.opacity(0), gold, gold.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 238, height: 2)
                    .opacity(0.9)
                    .offset(y: -125 + 250 * (0.08 + 0.8 * k))
            }
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(gold, lineWidth: 3)
                .frame(width: 250, height: 250)
                .scaleEffect(flash ? 1 : 1.06)
                .opacity(flash ? 0 : (found ? 1 : 0))
        }
        .frame(width: 250, height: 250)
        .accessibilityHidden(true)
        .onAppear { if found { withAnimation(Motion.outQuint(500)) { flash = true } } }
    }

    private struct Corner: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 12))
            p.addQuadCurve(to: CGPoint(x: rect.minX + 12, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return p
        }
    }
}

/// Round 12's pretend camera view (a Mac showing a code), for Debug screenshots only.
private struct PretendMacScene: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(colors: [Color(hex: 0x2A2F38), Color(hex: 0x14181F), Color(hex: 0x07090D)],
                               center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: proxy.size.height * 0.6)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: 0x0C1322))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x2B2F36), lineWidth: 6))
                    .overlay(PretendQR().frame(width: proxy.size.width * 0.78 * 0.38).offset(y: -12))
                    .frame(width: proxy.size.width * 0.78, height: proxy.size.width * 0.78 / 1.6)
                    .rotation3DEffect(.degrees(6), axis: (x: 1, y: 0, z: 0))
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.43)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The mockup's deterministic 21 × 21 code (`screens.js` `qrHTML`).
private struct PretendQR: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let pad = size.width * 0.05
            let cell = (size.width - 2 * pad) / 21
            var x = 12345
            for r in 0..<21 {
                for c in 0..<21 {
                    let finder = (r < 7 && c < 7) || (r < 7 && c > 13) || (r > 13 && c < 7)
                    var on: Bool
                    if finder {
                        let rr = r > 13 ? r - 14 : r, cc = c > 13 ? c - 14 : c
                        on = rr == 0 || rr == 6 || cc == 0 || cc == 6 || (rr >= 2 && rr <= 4 && cc >= 2 && cc <= 4)
                    } else {
                        x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
                        on = ((x >> 12) & 1) == 1
                    }
                    if on {
                        context.fill(Path(CGRect(x: pad + CGFloat(c) * cell, y: pad + CGFloat(r) * cell, width: cell, height: cell)),
                                     with: .color(Color(hex: 0x0C1322)))
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - T3's camera (adopted as-is)

enum QRScannerAvailability: Equatable {
    case checking
    case ready
    case denied
    case unavailable
}

private struct QRScannerCameraView: UIViewControllerRepresentable {
    @Binding var availability: QRScannerAvailability
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(availability: $availability, onScan: onScan)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {}

    static func dismantleUIViewController(
        _ controller: QRScannerViewController,
        coordinator: Coordinator
    ) {
        controller.stop()
    }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private var availability: Binding<QRScannerAvailability>
        private let onScan: (String) -> Void
        private weak var controller: QRScannerViewController?
        private var didScan = false

        init(
            availability: Binding<QRScannerAvailability>,
            onScan: @escaping (String) -> Void
        ) {
            self.availability = availability
            self.onScan = onScan
        }

        func attach(to controller: QRScannerViewController) {
            self.controller = controller
            controller.prepare(delegate: self) { [weak self] nextAvailability in
                self?.availability.wrappedValue = nextAvailability
            }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?
                .stringValue
            else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, !didScan else { return }
                didScan = true
                controller?.stop()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onScan(value)
            }
        }
    }
}

@MainActor
private final class QRScannerViewController: UIViewController {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.richos.native.qr-scanner")  // RichOS: T3's label renamed.
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataDelegate: AVCaptureMetadataOutputObjectsDelegate?
    private var availabilityChanged: (@MainActor (QRScannerAvailability) -> Void)?
    private var isConfiguring = false
    private var isRequestingAuthorization = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    // SwiftUI does not reliably dismantle a representable the moment its
    // fullScreenCover dismisses, and backgrounding never dismantles it, so
    // stop the camera on disappear and resume it when the view returns.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard previewLayer != nil else {
            refreshAuthorization()
            return
        }
        let session = captureSession
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func prepare(
        delegate: AVCaptureMetadataOutputObjectsDelegate,
        availabilityChanged: @escaping @MainActor (QRScannerAvailability) -> Void
    ) {
        metadataDelegate = delegate
        self.availabilityChanged = availabilityChanged
        refreshAuthorization()
    }

    private func refreshAuthorization() {
        guard let metadataDelegate, let availabilityChanged else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(delegate: metadataDelegate, availabilityChanged: availabilityChanged)
        case .notDetermined:
            guard !isRequestingAuthorization else { return }
            isRequestingAuthorization = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRequestingAuthorization = false
                    guard granted else {
                        self.availabilityChanged?(.denied)
                        return
                    }
                    self.refreshAuthorization()
                }
            }
        case .denied, .restricted:
            availabilityChanged(.denied)
        @unknown default:
            availabilityChanged(.unavailable)
        }
    }

    func stop() {
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configure(
        delegate: AVCaptureMetadataOutputObjectsDelegate,
        availabilityChanged: @escaping @MainActor (QRScannerAvailability) -> Void
    ) {
        guard previewLayer == nil, !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input)
        else {
            availabilityChanged(.unavailable)
            return
        }

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            availabilityChanged(.unavailable)
            return
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        captureSession.addInput(input)
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        captureSession.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        availabilityChanged(.ready)

        let session = captureSession
        sessionQueue.async {
            session.startRunning()
        }
    }
}
