import SwiftUI
import RichOSCore

/// The Send to Rich sheet (round-12 `attachments.html`, group 16 `share-compose`, `-many`, `-file`,
/// `share-sent`, `share-saved`; group 17 `share-unpaired`, `share-too-large`). Sizes, radii, type
/// and motion are `round-12/attach/attach.css` `.sx*`, `.fan`, `.filecard`, `.fi`, `.chip`, and
/// `attachments-NOTES.md` "Motion"; colors and type come from the app's own design system
/// (`App/Design`, shared with this extension, never copied).
struct ShareSheetView: View {
    @Bindable var model: ShareModel
    @Environment(\.palette) private var palette
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            GroundBackground()
            VStack(spacing: 0) {
                Capsule().fill(palette.ink.opacity(0.35)).frame(width: 40, height: 5).padding(.bottom, 10)
                    .accessibilityHidden(true)
                switch model.phase {
                case .loading:
                    Color.clear.frame(height: 48)
                case .unpaired:
                    unpaired
                case .failed(let reason):
                    failed(reason)
                case .compose, .sending, .done:
                    compose
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    // MARK: compose (and the confirmation drawn over it)

    private var isSending: Bool {
        if case .compose = model.phase { return false }
        return true
    }

    private var compose: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                preview
                if let large = model.tooLarge {
                    warning(large)
                } else {
                    captionField
                    destination
                }
            }
            // `.sx.sending`: the content fades and scales to 0.96 over 180 ms.
            .opacity(isDone ? 0 : 1)
            .scaleEffect(isDone ? 0.96 : 1)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.18), value: isDone)
            if case .done(let outcome) = model.phase {
                ShareConfirmation(outcome: outcome, macName: model.context.macName)
                    .padding(.top, 56)
                    .padding(.horizontal, 28)
            }
        }
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    private var header: some View {
        ZStack {
            Text("Send to Rich")
                .type(Typography.Role(.serif, 24, style: .title2, tracking: -0.01))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button { model.cancel() } label: { Text("Cancel") }
                    .buttonStyle(RButtonStyle(kind: .quiet))
                    .padding(.leading, -4)
                    .accessibilityIdentifier("share-cancel")
                Spacer()
                Button { model.send() } label: {
                    if model.phase == .sending {
                        ProgressView().tint(palette.onSignal).accessibilityLabel("Sending")
                    } else {
                        Text("Send")
                    }
                }
                .buttonStyle(RButtonStyle(kind: .primary, compact: true))
                .frame(minHeight: 40)
                // `share-too-large`: Send is inactive at 45% (declared exemption, attachments NOTES).
                .opacity(model.tooLarge != nil ? 0.45 : 1)
                .disabled(!model.canSend)
                .accessibilityIdentifier("share-send")
            }
        }
        .frame(minHeight: 48)
    }

    @ViewBuilder private var preview: some View {
        let photos = model.previews.filter(\.isPhoto)
        if photos.isEmpty, let file = model.previews.first {
            FileCard(name: file.name, summary: FileCard.summary(file), bad: model.tooLarge != nil)
                .padding(.vertical, 16)
        } else {
            PhotoFan(photos: photos)
                .frame(height: 212)
                .padding(.top, 14)
                .padding(.bottom, 16)
        }
    }

    private var captionField: some View {
        TextField("", text: $model.caption, prompt: Text("Add a message").foregroundStyle(palette.inkSoft), axis: .vertical)
            .type(Typography.body)
            .foregroundStyle(palette.ink)
            .tint(palette.signal)
            .lineLimit(1...4)
            .focused($captionFocused)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(palette.lineFaint, lineWidth: 1))
            .accessibilityLabel("Add a message")
            .accessibilityIdentifier("share-caption")
            .disabled(model.phase != .compose)
    }

    private var destination: some View {
        HStack(alignment: .center, spacing: 10) {
            IconView(.mac, size: 20).foregroundStyle(palette.ink)
            (Text("Goes to ") + Text("Rich on \(model.context.macName ?? "your Mac")").fontWeight(.semibold).foregroundColor(palette.ink)
                + Text(". The reply comes in RichConnect."))
                .type(Typography.read)
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func warning(_ large: (name: String, bytes: Int)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(.alert, size: 20).foregroundStyle(palette.danger).padding(.top, 1)
            (Text("Too large to send.").fontWeight(.semibold).foregroundColor(palette.danger)
                + Text(" " + Self.tooLargeReason(bytes: large.bytes, limit: model.context.limits.maxFileBytes)))
                .type(Typography.read)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share-too-large")
    }

    /// The reason under a too-large file. When the file rounds to the same size as the limit
    /// ("this one is 25 MB" beside "up to 25 MB") the numbers would contradict each other, so it
    /// says "just over that" instead.
    static func tooLargeReason(bytes: Int, limit: Int) -> String {
        let limitText = FileCard.megabytes(limit)
        let sizeText = FileCard.megabytes(bytes)
        let size = sizeText == limitText ? "just over that" : sizeText
        return "Rich can take files up to \(limitText) each; this one is \(size). Send a smaller part of it, or share it from your Mac."
    }

    // MARK: unpaired and failure

    private var unpaired: some View {
        VStack(spacing: 0) {
            MarkView().frame(width: 56, height: 56).padding(.bottom, 14)
            Text("Pair RichConnect with your Mac first")
                .type(Typography.Role(.serif, 28, style: .title1, lineHeight: 1.15))
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            // round 12 offers "Open RichOS to pair" here. A Share extension cannot open its own app
            // (no public API; UIApplication is unavailable to extensions), so the sheet says where
            // to go instead of offering a button that would do nothing (declared in the handoff).
            Text("Then anything you share here goes straight to Rich. Open RichConnect on this iPhone and scan the code on your Mac.")
                .type(Typography.read.lineHeight(1.45))
                .foregroundStyle(palette.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 32 * 9)
                .padding(.top, 10)
                .padding(.bottom, 18)
            Button { model.cancel() } label: { Text("Close") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("share-close")
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .accessibilityIdentifier("share-unpaired")
    }

    private func failed(_ reason: String) -> some View {
        VStack(spacing: 0) {
            MarkView().frame(width: 56, height: 56).padding(.bottom, 14)
            Text(reason)
                .type(Typography.read.lineHeight(1.45))
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .padding(.bottom, 18)
            Button { model.cancel() } label: { Text("Close") }
                .buttonStyle(RButtonStyle(kind: .primary, tall: true, wide: true))
                .accessibilityIdentifier("share-close")
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .accessibilityIdentifier("share-failed")
    }
}

/// `share-sent` / `share-saved`: the disc, the title and the honest line.
struct ShareConfirmation: View {
    let outcome: ShareOutcome
    let macName: String?
    @Environment(\.palette) private var palette
    @State private var shown = false
    @State private var drawn: CGFloat = 0

    private var sent: Bool { outcome == .sent }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(sent ? palette.signal : palette.surface)
                    .overlay(Circle().strokeBorder(sent ? Color.clear : palette.line, lineWidth: 1))
                    .shadow(color: sent ? palette.orbShadow : palette.floatShadow, radius: 12, x: 0, y: 8)
                if sent {
                    // The check draws over 260 ms, starting 200 ms in (attachments NOTES "Motion").
                    SVGShape(Icon.check.stroke, box: 24)
                        .trim(from: 0, to: drawn)
                        .stroke(palette.onSignal, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 36, height: 36)
                } else {
                    IconView(.clock, size: 36).foregroundStyle(palette.ink)
                }
            }
            .frame(width: 76, height: 76)
            .scaleEffect(shown ? 1 : 0.6)
            Text(sent ? "Sent to Rich" : "Saved for Rich")
                .type(Typography.Role(.serif, 30, style: .title1, tracking: -0.01))
                .foregroundStyle(palette.ink)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .type(Typography.read.lineHeight(1.45))
                .foregroundStyle(palette.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 30 * 9)
                .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(sent ? "share-sent" : "share-saved")
        .onAppear {
            // The disc scales 0.6 → 1 over 420 ms on the spring.
            withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.42).delay(0.04)) { shown = true }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.26).delay(0.2)) { drawn = 1 }
        }
    }

    /// Each line says what is true of THIS build. round 12's offline line promises the item goes
    /// "as soon as this iPhone is back online"; nothing sends it until RichOS opens, so the words say
    /// that instead (declared in the handoff; they change when background sending exists).
    private var line: String {
        switch outcome {
        case .sent: return "Rich will reply in RichConnect."
        case .saved(.offline): return "No connection right now. It goes to your Mac the next time RichConnect is open and online."
        case .saved(.notConfirmed), .saved(.cannotSendHere): return "It goes to your Mac the next time you open RichConnect."
        case .saved(.refused(let reason)):
            return (reason.map { "\($0) " } ?? "Your Mac did not take it. ") + "It is kept in RichConnect."
        }
    }
}

/// `.fan`: up to three photo cards, fanned like a hand of cards, with the count in a chip.
struct PhotoFan: View {
    let photos: [ShareModel.Preview]
    @Environment(\.palette) private var palette
    @State private var entered = false

    /// round 12's transforms: three cards at −8°/−34, +7°/+34, −1°/0; otherwise −2°/0.
    private static let fanned: [(angle: Double, x: CGFloat)] = [(-8, -34), (7, 34), (-1, 0)]

    var body: some View {
        GeometryReader { proxy in
            let shown = Array(photos.suffix(3).reversed())
            let height = proxy.size.height * 0.88
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, photo in
                    let pose = shown.count == 3 ? Self.fanned[index] : (angle: -2, x: 0)
                    card(photo, height: height)
                        .rotationEffect(.degrees(entered ? pose.angle : 0))
                        .offset(x: entered ? pose.x : 0)
                        .scaleEffect(entered ? 1 : 0.92)
                        .opacity(entered ? 1 : 0)
                        .animation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.5).delay(Double(shown.count - 1 - index) * 0.03), value: entered)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .bottomTrailing) {
                if photos.count > 1 {
                    Text("\(photos.count) photos")
                        .type(Typography.read.weight(600))
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .floatingSurface(palette, radius: 15)
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photos.count == 1 ? "1 photo" : "\(photos.count) photos")
        .onAppear { entered = true }
    }

    private func card(_ photo: ShareModel.Preview, height: CGFloat) -> some View {
        let portrait = (photo.thumbnail.map { $0.size.height > $0.size.width }) ?? false
        return ZStack {
            palette.surface
            if let image = photo.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: height * (portrait ? 3.0 / 4.0 : 4.0 / 3.0), height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.lineFaint, lineWidth: 1))
        .floatShadow(palette)
    }
}

/// `.filecard` with its `.fi` page glyph.
struct FileCard: View {
    let name: String
    let summary: String
    let bad: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            FileGlyph(ext: FileCard.ext(name))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).type(Typography.body.weight(600)).foregroundStyle(palette.ink)
                Text(summary).type(Typography.read).foregroundStyle(palette.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(palette.surface).floatShadow(palette))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(bad ? palette.danger : palette.lineFaint, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    static func ext(_ name: String) -> String {
        let value = URL(fileURLWithPath: name).pathExtension.uppercased()
        return value.isEmpty ? "FILE" : String(value.prefix(4))
    }

    static func summary(_ preview: ShareModel.Preview) -> String { "\(ext(preview.name)) · \(megabytes(preview.bytes))" }

    /// Round 12's size wording ("2.4 MB", "25 MB", "180 KB").
    static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 10 { return "\(Int(mb.rounded())) MB" }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }
}

/// `.fi`: a page with a gold folded corner and the extension on it (44 × 52).
struct FileGlyph: View {
    static let page = "M4 4.5A4 4 0 0 1 8 .5h18l13.5 13.5v29.5a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4z"
    static let fold = "M26 .5v9.5a4 4 0 0 0 4 4h9.5z"
    let ext: String
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .bottom) {
            FramedSVG(FileGlyph.page, width: 40, height: 48)
                .fill(palette.surface)
            FramedSVG(FileGlyph.page, width: 40, height: 48)
                .stroke(palette.lineFaint, lineWidth: 1)
            FramedSVG(FileGlyph.fold, width: 40, height: 48).fill(palette.signal)
            // 14 pt, declared skippable (attachments NOTES "Type": the type repeats at 16 pt beside it).
            Text(ext).type(Typography.skippable.weight(700)).foregroundStyle(palette.ink).padding(.bottom, 8)
        }
        .frame(width: 44, height: 52)
        .accessibilityHidden(true)
    }
}

/// An SVG path in a `width` × `height` box, stretched to the frame (`SVGShape` is square-only).
/// `@unchecked Sendable`: a CGPath is immutable once built.
struct FramedSVG: Shape, @unchecked Sendable {
    let cgPath: CGPath
    let width: CGFloat
    let height: CGFloat

    init(_ d: String, width: CGFloat, height: CGFloat) {
        cgPath = SVGPath.parse(d)
        self.width = width
        self.height = height
    }

    func path(in rect: CGRect) -> Path {
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / width, y: rect.height / height)
        return Path(cgPath.copy(using: &transform) ?? cgPath)
    }
}
