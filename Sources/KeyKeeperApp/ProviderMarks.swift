import AppKit
import SwiftUI
import KeyKeeperCore

/// Brand marks for the provider templates, so a Stripe key looks like Stripe at a glance.
///
/// yyt 2026-09-15: "全都是小字，阅读起来很困难". Monochrome in lists and detail pages (the app
/// carries no colour of its own), the brand colour only in the confirmation windows, where the
/// person has to recognise it in one look. Bundled marks are normalized vector paths whose source
/// is recorded in `ProviderMarks.generated.swift`; the marks remain their owners' trademarks and
/// are used only to identify the service. If there is no suitable provider-sourced vector asset,
/// use a coloured lettermark — never invent a generic product icon or scrape a favicon.
enum ProviderMarks {
    struct Mark {
        let path: String
        let brandHex: String
        let source: String
        let viewBox: String

        init(path: String, brandHex: String, source: String, viewBox: String = "0 0 24 24") {
            self.path = path
            self.brandHex = brandHex
            self.source = source
            self.viewBox = viewBox
        }
    }

    /// Exact single-graphic artwork from the provider's own downloadable brand package. Kept
    /// separate from the generated normalized set so its original geometry stays untouched.
    private static let directOfficialMarks: [String: Mark] = [
        "siliconflow": Mark(
            path: "M161.05,22L99.21,22C95.79,22,93.03,24.77,93.03,28.18L93.03,46.730000000000004C93.03,50.15,90.26,52.91,86.85,52.91L31.18,52.91C27.759999999999998,52.91,25,55.68,25,59.09L25,83.83C25,87.25,27.77,90.01,31.18,90.01L93.02,90.01C96.44,90.01,99.2,87.24,99.2,83.83L99.2,65.28C99.2,61.86,101.97,59.1,105.38,59.1L161.04,59.1C164.46,59.1,167.22,56.33,167.22,52.92L167.22,28.18C167.22,24.759999999999998,164.45,22,161.04,22L161.05,22Z",
            brandHex: "6E29F6",
            source: "https://static02.siliconflow.cn/www/cn/res/20260615/SiliconFlow_LOGO.zip",
            viewBox: "0 0 193 112"),
    ]

    static let marks = bundledOfficialMarks.merging(directOfficialMarks) { _, direct in direct }

    /// The remaining providers deliberately use a lettermark. Colours come from their published
    /// brand pages or the primary accent used by the provider's own console.
    private static let lettermarkBrandHexes: [String: String] = [
        "openai": "000000",
        "groq": "F55036",
        "zhipu": "174AE5",
        "volcengine-ark": "165DFF",
        "aws": "FF9900",
        "azure": "0078D4",
        "twilio": "F22F46",
        "sendgrid": "1A82E2",
        "slack": "611F69",
        "feishu": "3370FF",
    ]

    /// Official pages used to choose the colour and, where relevant, to confirm that a third-party
    /// logo is unavailable or needs separate permission. Kept beside the fallback decision so a
    /// future official asset can replace the letter without guesswork.
    private static let lettermarkSourceURLs: [String: String] = [
        "openai": "https://openai.com/brand/",
        "groq": "https://groq.com/trademark-policy",
        "zhipu": "https://docs.bigmodel.cn/cn/terms/service-agreement",
        "volcengine-ark": "https://www.volcengine.com/",
        "aws": "https://aws.amazon.com/trademark-guidelines/",
        "azure": "https://azure.microsoft.com/",
        "twilio": "https://www.twilio.com/en-us/company/brand",
        "sendgrid": "https://sendgrid.com/",
        "slack": "https://slack.com/media-kit",
        "feishu": "https://www.feishu.cn/",
    ]

    static let brandHexes: [String: String] = {
        var result = marks.mapValues(\.brandHex)
        result.merge(lettermarkBrandHexes) { current, _ in current }
        return result
    }()

    static let sourceURLs: [String: String] = {
        var result = marks.mapValues(\.source)
        result.merge(lettermarkSourceURLs) { current, _ in current }
        return result
    }()

    static func mark(for providerId: String?) -> Mark? { providerId.flatMap { marks[$0] } }

    /// A template NSImage (tints with whatever colour it is drawn in), rendered from the path.
    static func image(for providerId: String, size: CGFloat = 64) -> NSImage? {
        guard let mark = marks[providerId] else { return nil }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(mark.viewBox)" width="\(Int(size))" height="\(Int(size))"><path d="\(mark.path)"/></svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }

    static func brandColor(for providerId: String) -> Color? {
        guard let hex = brandHexes[providerId], let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    /// Preserve the brand hue against a dark surface. Very dark official marks use their white
    /// monochrome counterpart; dark chromatic colours are lifted without changing hue.
    static func visibleBrandColor(for providerId: String, onDarkSurface: Bool) -> Color? {
        guard let hex = brandHexes[providerId], let value = UInt32(hex, radix: 16) else { return nil }
        let color = NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
        guard onDarkSurface else { return Color(nsColor: color) }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if brightness < 0.72 {
            if saturation < 0.08 { return .white }
            return Color(nsColor: NSColor(
                calibratedHue: hue,
                saturation: min(saturation, 0.8),
                brightness: 0.82,
                alpha: alpha))
        }
        return Color(nsColor: color)
    }

    /// The initial for a provider without a usable mark ("O" for OpenAI).
    static func letter(for providerId: String) -> String {
        let name = ProviderCatalog.find(providerId)?.name ?? providerId
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// The mark, or the lettermark, at a size. `colored` draws the brand colour; otherwise it
/// takes the foreground colour of its surroundings.
struct ProviderMark: View {
    @Environment(\.colorScheme) private var colorScheme

    let providerId: String
    var size: CGFloat = 20
    var colored = false
    var onLightSurface = false

    var body: some View {
        if let image = ProviderMarks.image(for: providerId, size: size * 2) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(colored ? displayBrandColor : nil)
        } else {
            Text(ProviderMarks.letter(for: providerId))
                .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .foregroundColor(colored ? displayBrandColor : .primary)
        }
    }

    /// Provider tiles always sit on white; inline marks follow the window appearance.
    private var displayBrandColor: Color {
        ProviderMarks.visibleBrandColor(
            for: providerId,
            onDarkSurface: colorScheme == .dark && !onLightSurface) ?? .primary
    }
}

/// The real icon of the program asking, when the Mac has it: an app caller's own bundle, or the
/// desktop app that belongs to a command-line agent (Claude Code → Claude, Codex CLI → Codex).
/// Nothing is bundled; the icon comes from the user's own installation, or a lettermark.
enum CallerAppIcon {
    /// Command-line agents and the desktop apps whose icon represents them.
    static let desktopApps: [String: [String]] = [
        "com.anthropic.claude-code": ["com.anthropic.claudefordesktop"],
        "com.openai.codex": ["com.openai.codex"],
    ]

    static func desktopBundleIds(for callerId: String) -> [String] {
        (desktopApps[callerId] ?? []) + [callerId]
    }

    static func image(for callerId: String) -> NSImage? {
        for bundleId in desktopBundleIds(for: callerId) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

struct CallerMark: View {
    /// A bundle identifier when the caller has one ("com.openai.codex"), else a display name.
    let callerId: String
    var size: CGFloat = 20

    var body: some View {
        if let image = CallerAppIcon.image(for: callerId) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .cornerRadius(size * 0.2)
        } else {
            Text(callerId.split(separator: ".").last.map { String($0.prefix(1)).uppercased() } ?? "?")
                .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color.secondary.opacity(0.18)))
        }
    }
}
