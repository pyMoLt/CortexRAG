import SwiftUI
import AppKit
import PDFKit
import CortexCore
import CortexVision

// MARK: - Tokens

enum Theme {
    /// Debug snapshots (`CORTEXRAG_DEBUG_DIR`) cannot capture Liquid Glass layers, so use the material fallback there.
    nonisolated static let glassAvailable: Bool = {
        guard ProcessInfo.processInfo.environment["CORTEXRAG_DEBUG_DIR"] == nil else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    /// Accent colours follow the user's choice (Settings → General → Appearance).
    /// Cached choice (updated by AppViewModel when the setting changes) – avoids copying all settings per draw.
    nonisolated(unsafe) static var accentChoice: AccentChoice = CortexSettingsManager.shared.settings.accentChoice
    nonisolated static var accent: Color {
        let c = accentChoice.rgb.primary
        return Color(red: c.0, green: c.1, blue: c.2)
    }
    nonisolated static var accent2: Color {
        let c = accentChoice.rgb.secondary
        return Color(red: c.0, green: c.1, blue: c.2)
    }
    static let figure = Color(red: 0.10, green: 0.68, blue: 0.70)
    static let thinking = Color(red: 0.62, green: 0.42, blue: 0.95)
    static let success = Color(red: 0.20, green: 0.72, blue: 0.45)
    static let warning = Color.orange

    static var accentGradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing) }

    static let radiusLarge: CGFloat = 22
    static let radius: CGFloat = 16
    static let radiusSmall: CGFloat = 11

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let quick = Animation.snappy(duration: 0.22)
}

// MARK: - Glass surfaces

extension View {
    /// Liquid-Glass surface on macOS 26+, material card with hairline border on earlier systems.
    func glassSurface(cornerRadius: CGFloat = Theme.radius, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), Theme.glassAvailable {
            var glass: Glass = .regular
            if let tint { glass = glass.tint(tint.opacity(0.18)) }
            if interactive { glass = glass.interactive() }
            return AnyView(self.glassEffect(glass, in: shape))
        } else {
            return AnyView(
                self
                    .background(.regularMaterial, in: shape)
                    .background((tint ?? .clear).opacity(0.08), in: shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            )
        }
    }

    /// Quiet content card (used for lists of results so that not everything is glass).
    func contentCard(cornerRadius: CGFloat = Theme.radius, highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: shape)
            .overlay(
                shape.strokeBorder(highlighted ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: highlighted ? 1.4 : 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    /// Glass-style container that lets nearby glass shapes blend on macOS 26+.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *), Theme.glassAvailable {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

// MARK: - Buttons

struct GlassButtonStyleCompat: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.regularMaterial))
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.25 : 0.0), lineWidth: 0.5))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.08), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

extension View {
    /// Glass button on macOS 26+, capsule material button before.
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color = Theme.accent) -> some View {
        if #available(macOS 26.0, *), Theme.glassAvailable {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(GlassButtonStyleCompat(prominent: prominent, tint: tint))
        }
    }
}

// MARK: - Chips

/// Toggle chip ("KI-Antwort", "Denken", …).
struct ToggleChip: View {
    let title: LocalizedStringKey
    let icon: String
    let isOn: Bool
    var tint: Color = Theme.accent
    var help: LocalizedStringKey = ""
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(Theme.quick) { action() } }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.bounce, value: isOn)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .fixedSize()
            .foregroundStyle(isOn ? tint : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                Capsule().fill(isOn ? tint.opacity(0.16) : Color.primary.opacity(0.05))
            }
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(height: 28)
        .help(help)
    }
}

/// Small, non-interactive information pill.
struct InfoPill: View {
    let text: LocalizedStringKey
    var icon: String? = nil
    var tint: Color = .secondary
    var monospaced = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
    }
}

/// Rounded icon tile used in headers.
struct IconTile: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: tint.opacity(0.35), radius: 6, y: 2)
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var icon: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 10) {
            if let icon { IconTile(systemName: icon, tint: tint, size: 26) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Background

/// Soft, static colour field behind the content so that glass surfaces have something to refract.
/// Deliberately not animated: the app is designed to idle at ~0 W.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.45], [0.45, 0.55], [1, 0.4],
                [0, 1], [0.6, 1], [1, 1]
            ],
            colors: colors
        )
        .ignoresSafeArea()
    }

    private var colors: [Color] {
        let base = Color(nsColor: .windowBackgroundColor)
        let o = scheme == .dark ? 0.22 : 0.16
        return [
            base, Theme.accent.opacity(o), base,
            Theme.accent2.opacity(o * 0.8), base, Theme.thinking.opacity(o * 0.7),
            base, Theme.figure.opacity(o * 0.6), base
        ]
    }
}

// MARK: - Helpers

extension NSPasteboard {
    static func copy(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}

/// Image loader with an in-memory cache so that scrolling result lists does not hit the disk repeatedly.
/// When full-page or figure PNGs are not stored on disk, renders/crops the requested PDF page or figure on demand.
@MainActor
enum ThumbnailCache {
    /// Bounded: decoded page renders take ~6 MB, figure crops 1–3 MB. Without limits NSCache only gives memory back
    /// under system memory pressure, so scrolling through many hits kept hundreds of MB.
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()

    private static func store(_ img: NSImage, _ key: NSString) {
        let px = img.representations.first.map { Double($0.pixelsWide * $0.pixelsHigh) } ?? 0
        let cost = px > 0 ? px * 4 : Double(img.size.width * img.size.height) * 4
        cache.setObject(img, forKey: key, cost: Int(cost))
    }

    static func image(at path: String, documentPath: String = "", pageNumber: Int = 0, figure: FigureResultItem? = nil) -> NSImage? {
        if !path.isEmpty {
            if let hit = cache.object(forKey: path as NSString) { return hit }
            if let img = NSImage(contentsOfFile: path) {
                store(img, path as NSString)
                return img
            }
        }
        if let figure {
            let ensured = PDFVisionPipeline.ensureCroppedFigureExists(figure)
            if !ensured.isEmpty, let img = NSImage(contentsOfFile: ensured) {
                store(img, ensured as NSString)
                return img
            }
        }
        guard !documentPath.isEmpty, pageNumber >= 1 else { return nil }
        let cacheKey = "\(documentPath)#page\(pageNumber)" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        let pdfPath = DocumentFormats.readablePDFPath(for: documentPath)
        guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let page = doc.page(at: max(0, min(doc.pageCount - 1, pageNumber - 1))) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 1.75
        let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            return true
        }
        store(img, cacheKey)
        return img
    }
}

struct AssetImage: View {
    let path: String
    var maxHeight: CGFloat? = nil
    var cornerRadius: CGFloat = 10
    var documentPath: String = ""
    var pageNumber: Int = 0
    var figure: FigureResultItem? = nil

    var body: some View {
        if let img = ThumbnailCache.image(at: path, documentPath: documentPath, pageNumber: pageNumber, figure: figure) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxHeight: maxHeight)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(height: maxHeight ?? 120)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }
}
