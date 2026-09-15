import AppKit
import SwiftUI
import KeyKeeperCore

/// Brand marks for the provider templates, so a Stripe key looks like Stripe at a glance.
///
/// yyt 2026-09-15: "全都是小字，阅读起来很困难". Monochrome in lists and detail pages (the app
/// carries no colour of its own), the brand colour only in the confirmation windows, where the
/// person has to recognise it in one look. Marks are the Simple Icons path data (CC0 code; the
/// marks themselves remain their owners' trademarks and are used only to identify the service).
/// Providers whose brand rules do not allow their logo in third-party UI (OpenAI, Google,
/// Anthropic) and ones with no published mark get a lettermark instead.
enum ProviderMarks {
    struct Mark {
        let path: String   // 24×24 viewBox path data
        let brandHex: String
    }

    static let marks: [String: Mark] = [
        "supabase": Mark(path: "M11.9 1.036c-.015-.986-1.26-1.41-1.874-.637L.764 12.05C-.33 13.427.65 15.455 2.409 15.455h9.579l.113 7.51c.014.985 1.259 1.408 1.873.636l9.262-11.653c1.093-1.375.113-3.403-1.645-3.403h-9.642z", brandHex: "3FCF8E"),
        "vercel": Mark(path: "m12 1.608 12 20.784H0Z", brandHex: "000000"),
        "github": Mark(path: "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12", brandHex: "181717"),
        "cloudflare": Mark(path: "M16.5088 16.8447c.1475-.5068.0908-.9707-.1553-1.3154-.2246-.3164-.6045-.499-1.0615-.5205l-8.6592-.1123a.1559.1559 0 0 1-.1333-.0713c-.0283-.042-.0351-.0986-.021-.1553.0278-.084.1123-.1484.2036-.1562l8.7359-.1123c1.0351-.0489 2.1601-.8868 2.5537-1.9136l.499-1.3013c.0215-.0561.0293-.1128.0147-.168-.5625-2.5463-2.835-4.4453-5.5499-4.4453-2.5039 0-4.6284 1.6177-5.3876 3.8614-.4927-.3658-1.1187-.5625-1.794-.499-1.2026.119-2.1665 1.083-2.2861 2.2856-.0283.31-.0069.6128.0635.894C1.5683 13.171 0 14.7754 0 16.752c0 .1748.0142.3515.0352.5273.0141.083.0844.1475.1689.1475h15.9814c.0909 0 .1758-.0645.2032-.1553l.12-.4268zm2.7568-5.5634c-.0771 0-.1611 0-.2383.0112-.0566 0-.1054.0415-.127.0976l-.3378 1.1744c-.1475.5068-.0918.9707.1543 1.3164.2256.3164.6055.498 1.0625.5195l1.8437.1133c.0557 0 .1055.0263.1329.0703.0283.043.0351.1074.0214.1562-.0283.084-.1132.1485-.204.1553l-1.921.1123c-1.041.0488-2.1582.8867-2.5527 1.914l-.1406.3585c-.0283.0713.0215.1416.0986.1416h6.5977c.0771 0 .1474-.0489.169-.126.1122-.4082.1757-.837.1757-1.2803 0-2.6025-2.125-4.727-4.7344-4.727", brandHex: "F38020"),
        "stripe": Mark(path: "M13.976 9.15c-2.172-.806-3.356-1.426-3.356-2.409 0-.831.683-1.305 1.901-1.305 2.227 0 4.515.858 6.09 1.631l.89-5.494C18.252.975 15.697 0 12.165 0 9.667 0 7.589.654 6.104 1.872 4.56 3.147 3.757 4.992 3.757 7.218c0 4.039 2.467 5.76 6.476 7.219 2.585.92 3.445 1.574 3.445 2.583 0 .98-.84 1.545-2.354 1.545-1.875 0-4.965-.921-6.99-2.109l-.9 5.555C5.175 22.99 8.385 24 11.714 24c2.641 0 4.843-.624 6.328-1.813 1.664-1.305 2.525-3.236 2.525-5.732 0-4.128-2.524-5.851-6.594-7.305h.003z", brandHex: "635BFF"),
        "resend": Mark(path: "M14.679 0c4.648 0 7.413 2.765 7.413 6.434s-2.765 6.434-7.413 6.434H12.33L24 24h-8.245l-8.88-8.44c-.636-.588-.93-1.273-.93-1.86 0-.831.587-1.565 1.713-1.883l4.574-1.224c1.737-.465 2.936-1.81 2.936-3.572 0-2.153-1.761-3.4-3.939-3.4H0V0z", brandHex: "000000"),
    ]

    static func mark(for providerId: String?) -> Mark? { providerId.flatMap { marks[$0] } }

    /// A template NSImage (tints with whatever colour it is drawn in), rendered from the path.
    static func image(for providerId: String, size: CGFloat = 64) -> NSImage? {
        guard let mark = marks[providerId] else { return nil }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="\(Int(size))" height="\(Int(size))"><path d="\(mark.path)"/></svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }

    static func brandColor(for providerId: String) -> Color? {
        guard let mark = marks[providerId], let value = UInt32(mark.brandHex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
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
    let providerId: String
    var size: CGFloat = 20
    var colored = false

    var body: some View {
        if let image = ProviderMarks.image(for: providerId, size: size * 2) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(colored ? (ProviderMarks.brandColor(for: providerId) ?? .primary) : nil)
        } else {
            Text(ProviderMarks.letter(for: providerId))
                .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color.secondary.opacity(0.18)))
        }
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
