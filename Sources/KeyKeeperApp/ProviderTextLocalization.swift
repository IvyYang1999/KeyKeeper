import Foundation
import KeyKeeperCore

/// Provider guidance (when a key expires, the least permission to grant) in the interface's
/// language. The catalog was written partly in English and partly in Chinese, so either
/// language showed the other one somewhere.
///
/// 【曾经的 bug】2026-11-08 主力 Mac 验收 follow-up：英文界面里 Novita 的有效期说明是中文；中文界面里
/// OpenAI、GitHub、Stripe 的说明是英文。
enum ProviderText {
    static func localized(_ text: String, language: String = AppL10n.language) -> String {
        let isChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if language == "zh-Hans", !isChinese { return providerTextChinese[text] ?? text }
        if language != "zh-Hans", isChinese { return providerTextEnglish[text] ?? text }
        return text
    }
}

// The tables are in ProviderTextTranslations.swift; a test fails when a catalog text has none.
