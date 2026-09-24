import SwiftUI

// Round 12's attachment screens (`round-12/attachments-NOTES.md`, `attach/attach.css`): the menu that
// springs out of the +, the tray in the capsule, album and file bubbles, Rich's reference chip, the
// upload disc, the viewer and the refusal cards. Numbers are the NOTES' motion table.

/// A photo drawn from its source: a Debug scene, or a staged file on this phone.
struct PhotoView: View {
    let photo: ScreenModel.AttachPhoto
    var body: some View {
        switch photo.source {
        case .scene(let key):
            PhotoScene(key: key)
        case .file(let url):
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(hex: 0x141E34)
            }
        case .unavailable:
            Color(hex: 0x141E34)
        }
    }
}

// MARK: - The + menu

/// Three rows spring out of the +: Photos, Camera, Files (`att-menu`). The conversation dims; the
/// composer stays lit.
struct AttachMenu: View {
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(.image, "Photos", .photos, index: 0)
            row(.camera, "Camera", .camera, index: 1)
            row(.folder, "Files", .files, index: 2)
        }
        .padding(6)
        .frame(width: 232)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(palette.surface)
            .floatShadow(palette)
            .shadow(color: .black.opacity(palette.appearance == .dark ? 0.45 : 0.2), radius: 30, y: 24))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.lineFaint, lineWidth: 1))
        .scaleEffect(shown ? 1 : 0.5, anchor: UnitPoint(x: 26 / 232, y: 1.15))
        .offset(y: shown ? 0 : 10)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(Motion.spring(320)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attach.menu")
    }

    private func row(_ icon: Icon, _ title: String, _ picker: ScreenModel.Picker, index: Int) -> some View {
        Button { send(.openPicker(picker)) } label: {
            HStack(spacing: 14) {
                IconView(icon, size: 21)
                    .foregroundStyle(palette.accentGlyph)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(palette.ground))
                    .overlay(Circle().strokeBorder(palette.lineFaint, lineWidth: 1))
                Text(title).type(Typography.body.weight(600)).foregroundStyle(palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 6)
        .animation(Motion.outQuint(280).delay(Double(index) * 0.024), value: shown)
        .accessibilityIdentifier("attach.\(title.lowercased())")
    }
}

private struct MenuRowStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(configuration.isPressed ? palette.signalWash : Color.clear))
    }
}

// MARK: - The tray in the capsule

/// Waiting to be sent: photos 68 × 68, files as 232 × 68 chips, each with its own ×; the tray scrolls
/// sideways (`att-pending-*`).
struct AttachTray: View {
    let items: [ScreenModel.PendingItem]
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    TrayItem(item: item, index: index, send: send)
                        .transition(.asymmetric(insertion: .identity,
                                                removal: .scale(scale: 0.6).combined(with: .opacity)))
                }
            }
            .padding(.horizontal, 12).padding(.top, 12)
            .animation(Motion.outQuint(240), value: items)
        }
        .frame(height: 80)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting to send")
        .accessibilityIdentifier("attach.tray")
    }
}

private struct TrayItem: View {
    let item: ScreenModel.PendingItem
    let index: Int
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette
    @State private var popped = false

    var body: some View {
        Group {
            switch item {
            case .photo(let photo):
                PhotoView(photo: photo)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.lineFaint, lineWidth: 1))
                    .overlay(alignment: .topTrailing) { remove(onPhoto: true).padding(4) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(photo.label)
            case .file(let file):
                HStack(spacing: 10) {
                    FileGlyph(ext: file.ext, small: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).type(Typography.read.weight(600).lineHeight(1.2)).foregroundStyle(palette.ink)
                            .lineLimit(2).truncationMode(.middle)
                        Text("\(file.ext) · \(ScreenModel.AttachFile.size(file.bytes))")
                            .type(Typography.read.lineHeight(1.2)).foregroundStyle(palette.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    remove(onPhoto: false)
                }
                .padding(.leading, 10).padding(.trailing, 6)
                .frame(width: 232, height: 68)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.ground))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.lineFaint, lineWidth: 1))
                .accessibilityElement(children: .contain)
            }
        }
        .scaleEffect(popped ? 1 : 0.6)
        .opacity(popped ? 1 : 0)
        .onAppear {
            withAnimation(Motion.spring(340).delay(min(0.2, Double(index) * 0.04))) { popped = true }
        }
    }

    /// × is a 24 pt disc inside the corner with a 44 pt target.
    private func remove(onPhoto: Bool) -> some View {
        Button { send(.removePending(id: item.id)) } label: {
            IconView(.close, size: 13, weight: 2.8)
                .foregroundStyle(onPhoto ? Color(hex: 0xDFE4EE) : palette.ink)
                .frame(width: 24, height: 24)
                .background(Circle().fill(onPhoto ? Color(red: 8 / 255, green: 12 / 255, blue: 22 / 255).opacity(0.8) : palette.surface))
                .overlay(Circle().strokeBorder(onPhoto ? Color(hex: 0xDFE4EE).opacity(0.22) : palette.lineFaint, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.9))
        .frame(width: 24, height: 24)
        .accessibilityLabel("Remove")
        .accessibilityIdentifier("attach.remove.\(item.id)")
    }
}

/// A page with a gold fold and its extension (`.fi`); the extension repeats at 16 pt beside it, so the
/// 14 pt label on the glyph is declared skippable (attachments NOTES "Type").
struct FileGlyph: View {
    let ext: String
    var small = false
    @Environment(\.palette) private var palette

    var body: some View {
        let w: CGFloat = small ? 30 : 40, h: CGFloat = small ? 36 : 48
        ZStack(alignment: .bottom) {
            FilePage().fill(palette.surface)
            FilePage().stroke(palette.lineFaint, lineWidth: 1)
            FileFold().fill(palette.signal)
            if !small {
                Text(ext)
                    .type(Typography.skippable.weight(700))
                    .tracking(-0.4)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.bottom, 7)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }

    private struct FilePage: Shape {
        func path(in r: CGRect) -> Path {
            let fold = r.width * 0.3
            var p = Path()
            p.move(to: CGPoint(x: r.minX + 3, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 3))
            p.addQuadCurve(to: CGPoint(x: r.maxX - 3, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + 3, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 3), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + 3))
            p.addQuadCurve(to: CGPoint(x: r.minX + 3, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }

    private struct FileFold: Shape {
        func path(in r: CGRect) -> Path {
            let fold = r.width * 0.3
            var p = Path()
            p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - In the conversation

/// Your photos as one album: inner corner 17, gap 3; one photo keeps its own aspect (3:4 … 4:3); two
/// side by side; three as one tall and two stacked; four 2 × 2; five 2 over 3; six to ten in rows of
/// two (`.alb`). With no caption, the time sits on the photo.
struct AlbumView: View {
    let photos: [ScreenModel.AttachPhoto]
    let width: CGFloat
    let onTap: (Int) -> Void

    var body: some View {
        let gap: CGFloat = 3
        Group {
            switch photos.count {
            case 1:
                let aspect = min(max(photos[0].aspect, 3.0 / 4.0), 4.0 / 3.0)
                cell(0).frame(width: width, height: width / aspect)
            case 2:
                HStack(spacing: gap) { cell(0); cell(1) }.frame(width: width, height: width / 1.5)
            case 3:
                HStack(spacing: gap) {
                    cell(0).frame(width: (width - gap) * 1.4 / 2.4)
                    VStack(spacing: gap) { cell(1); cell(2) }
                }
                .frame(width: width, height: width * 3 / 4)
            case 4:
                VStack(spacing: gap) {
                    HStack(spacing: gap) { cell(0); cell(1) }
                    HStack(spacing: gap) { cell(2); cell(3) }
                }
                .frame(width: width, height: width)
            case 5:
                VStack(spacing: gap) {
                    HStack(spacing: gap) { cell(0); cell(1) }
                    HStack(spacing: gap) { cell(2); cell(3); cell(4) }
                }
                .frame(width: width, height: width * 0.9)
            default:
                let rows = (photos.count + 1) / 2
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: gap) {
                            cell(r * 2)
                            if r * 2 + 1 < photos.count { cell(r * 2 + 1) }
                        }
                        .frame(height: 96)
                    }
                }
                .frame(width: width)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func cell(_ i: Int) -> some View {
        Button { onTap(i) } label: {
            PhotoView(photo: photos[i])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photos[i].label), \(i + 1) of \(photos.count)")
        .accessibilityHint("Opens it full screen")
    }
}

/// The dark veil and disc over a photo that is uploading, waiting or not sent (attachments NOTES A5:
/// the same dark in both themes, because a photo is not themed).
struct UploadDisc: View {
    let delivery: ScreenModel.Row.Delivery
    let progress: Double
    let onTap: () -> Void
    private let disc = Color(red: 8 / 255, green: 12 / 255, blue: 22 / 255).opacity(0.8)
    private let ink = Color(hex: 0xDFE4EE)
    private let gold = Color(hex: 0xC2A35C)

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle().fill(disc)
                if delivery == .sending {
                    Circle().stroke(ink.opacity(0.26), lineWidth: 3).padding(4)
                    Circle().trim(from: 0, to: 1 - pow(1 - progress, 1.6))
                        .stroke(gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                        .animation(.linear(duration: 0.15), value: progress)
                }
                IconView(delivery == .sending ? .close : (delivery == .waiting ? .clock : .refresh), size: 18, weight: 2.6)
                    .foregroundStyle(ink)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(PressScale(scale: 0.94))
        .accessibilityLabel(delivery == .sending ? "Stop sending" : (delivery == .waiting ? "Waiting to send" : "Try again"))
    }
}

/// Rich's answer quoting what you sent (`.att-ref`): a gold bar, the thumbnail or file, "Your 3 photos"
/// and "Sent at 8:41 AM". Tapping it goes back to what you sent, which glows once.
struct ReferenceChip: View {
    let reference: ScreenModel.Reference
    let calendar: Calendar
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button { send(.jumpTo(id: reference.messageID)) } label: {
            HStack(spacing: 10) {
                switch reference.kind {
                case .photos(let photos):
                    PhotoView(photo: photos[0])
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.leading, 6)
                case .file(let file):
                    FileGlyph(ext: file.ext, small: true).padding(.leading, 8)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).type(Typography.read.weight(600).lineHeight(1.3)).foregroundStyle(palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text("Sent at \(DayLabel.time(reference.sentAt, calendar: calendar))")
                        .type(Typography.read.lineHeight(1.3)).foregroundStyle(palette.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.trailing, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.ground))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2)
                    .fill(palette.signal).frame(width: 3).padding(.vertical, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityLabel("Show what you sent: \(title)")
        .accessibilityIdentifier("attach.reference")
    }

    private var title: String {
        switch reference.kind {
        case .photos(let p): return p.count > 1 ? "Your \(p.count) photos" : "Your photo"
        case .file(let f): return f.name
        }
    }
}

/// A file you sent: page, name, type, size, pages (`att-conv-file`).
struct FileCard: View {
    let file: ScreenModel.AttachFile
    let onTap: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                FileGlyph(ext: file.ext)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).type(Typography.body.weight(600).lineHeight(1.25)).foregroundStyle(palette.ink)
                        .lineLimit(2).truncationMode(.middle)
                    Text(file.summary).type(Typography.read).foregroundStyle(palette.inkSoft)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.name), \(file.summary)")
        .accessibilityHint("Opens it")
    }
}

// MARK: - The viewer

/// A photo grows out of its bubble to full screen; swipe down to send it back (follows the finger 1:1,
/// scales to 0.85 at 300 pt, and a release past 110 pt closes it). Tap the sides for the album.
struct AttachViewer: View {
    let photos: [ScreenModel.AttachPhoto]
    let file: ScreenModel.AttachFile?
    let index: Int
    let caption: String?
    let sentAt: Int64
    let calendar: Calendar
    let send: (Intent) -> Void
    @State private var drag: CGFloat = 0
    @State private var shown = false
    private let ink = Color(hex: 0xDFE4EE)

    var body: some View {
        let k: Double = min(1, Double(abs(drag)) / 300)
        ZStack {
            Color.black.opacity(shown ? 1 - 0.8 * k : 0).ignoresSafeArea()
            Group {
                if let file {
                    VStack(spacing: 16) {
                        FileGlyph(ext: file.ext).scaleEffect(2.2).padding(.bottom, 40)
                        Text(file.name).type(Typography.body.weight(600)).foregroundStyle(ink).multilineTextAlignment(.center)
                        Text(file.pages.map { "Page 1 of \($0)" } ?? file.summary).type(Typography.read).foregroundStyle(ink.opacity(0.78))
                    }
                    .padding(24)
                    .environment(\.palette, .sovereign)
                } else if photos.indices.contains(index) {
                    PhotoView(photo: photos[index])
                        .aspectRatio(photos[index].aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .scaleEffect(1 - 0.15 * k)
            .offset(y: drag)
            .opacity(shown ? 1 : 0)
            .gesture(DragGesture()
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if abs(value.translation.height) > 110 { send(.closeViewer) }
                    else { withAnimation(Motion.spring(300)) { drag = 0 } }
                })
            VStack {
                HStack {
                    Button { send(.closeViewer) } label: {
                        IconView(.close, size: 22).foregroundStyle(ink)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("viewer.close")
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 8)
                Spacer()
                VStack(spacing: 4) {
                    if let caption, !caption.isEmpty {
                        Text(caption).type(Typography.body).foregroundStyle(ink).multilineTextAlignment(.center)
                    }
                    Text("You, \(DayLabel.time(sentAt, calendar: calendar))").type(Typography.read).foregroundStyle(ink.opacity(0.78))
                    if photos.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(photos.indices, id: \.self) { i in
                                Circle().fill(ink.opacity(i == index ? 1 : 0.4)).frame(width: 7, height: 7)
                            }
                        }
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .opacity(1 - k)
            }
            .opacity(shown ? 1 : 0)
            if photos.count > 1 {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { if index > 0 { send(.viewerShow(index: index - 1)) } }
                        .accessibilityLabel("Previous photo").accessibilityAddTraits(.isButton)
                    Spacer()
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { if index + 1 < photos.count { send(.viewerShow(index: index + 1)) } }
                        .accessibilityLabel("Next photo").accessibilityAddTraits(.isButton)
                }
                .frame(maxHeight: 400)
                .allowsHitTesting(true)
                .padding(.horizontal, 0)
                .frame(maxWidth: .infinity)
                .overlay { Color.clear.frame(width: 160).allowsHitTesting(false) }
            }
        }
        .onAppear {
            withAnimation(Motion.outQuint(360)) { shown = true }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { send(.closeViewer) }
        .accessibilityIdentifier("viewer")
    }
}

// MARK: - Cards

struct AttachCards {
    @ViewBuilder static func card(_ card: ScreenModel.Card, send: @escaping (Intent) -> Void) -> some View {
        switch card {
        case .attachRefused(let name, let detail, let tooLarge):
            AttachRefusedCard(name: name, detail: detail, tooLarge: tooLarge, send: send)
        case .attachCameraDenied:
            CardView {
                CardText(title: "The camera is off for RichConnect",
                         detail: "Turn it on in iPhone Settings to take a photo for Rich, or choose one you already have.")
                FlowButtons {
                    Button { send(.openSystemSettings) } label: { Text("Open Settings") }
                        .buttonStyle(RButtonStyle(kind: .primary))
                    Button { send(.openPicker(.photos)) } label: { IconLabel(icon: .image, text: "Choose from Photos") }
                        .buttonStyle(RButtonStyle(kind: .ghost))
                }
                .padding(.top, 10)
            }
        case .attachPhotosDenied:
            CardView {
                CardText(title: "RichConnect can’t see your photos",
                         detail: "Allow access in iPhone Settings, or send a file from Files instead.")
                FlowButtons {
                    Button { send(.openSystemSettings) } label: { Text("Open Settings") }
                        .buttonStyle(RButtonStyle(kind: .primary))
                    Button { send(.openPicker(.files)) } label: { IconLabel(icon: .folder, text: "Use Files") }
                        .buttonStyle(RButtonStyle(kind: .ghost))
                }
                .padding(.top, 10)
            }
        case .attachMacUnsupported:
            CardView {
                CardText(title: "Your Mac can’t take photos and files yet",
                         detail: "Update RichOS on your Mac, then send them from here. Text and voice work now.")
                HStack {
                    Button { send(.dismissCard(id: card.id)) } label: { QuietLabel(text: "Got it") }
                        .buttonStyle(RButtonStyle(kind: .quiet))
                }
                .padding(.top, 10)
            }
        default:
            EmptyView()
        }
    }
}

private struct AttachRefusedCard: View {
    let name: String
    let detail: String
    let tooLarge: Bool
    let send: (Intent) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CardView {
            HStack(spacing: 8) {
                IconView(.alert, size: 20).foregroundStyle(palette.danger)
                Text(tooLarge ? "Too large to send" : "Rich can’t open this type yet")
                    .type(Typography.body.weight(600)).foregroundStyle(palette.ink)
            }
            (Text(name).run(Typography.read.weight(600), dynamicTypeSize).foregroundColor(palette.ink)
             + Text(" " + detail).foregroundColor(palette.inkSoft))
                .type(Typography.read)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            FlowButtons {
                Button { send(.openPicker(.files)) } label: { IconLabel(icon: .folder, text: "Choose another file") }
                    .buttonStyle(RButtonStyle(kind: .primary))
                Button { send(.dismissCard(id: "attach-refused")) } label: { QuietLabel(text: "Not now") }
                    .buttonStyle(RButtonStyle(kind: .quiet))
            }
            .padding(.top, 10)
        }
        .accessibilityIdentifier("attach.refused")
    }
}
