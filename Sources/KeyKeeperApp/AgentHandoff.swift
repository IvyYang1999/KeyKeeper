import AppKit
import KeyKeeperCore

/// The last step of the loop: the user has stored a key and now tells their agent about it.
///
/// Users kept asking what `keykeeper run -c openai -- <command>` was for. They are not meant
/// to type it — their agent is. So instead of a bare ID or command, KeyKeeper hands them a
/// short paragraph to paste into the agent: which ID to use, how it arrives, and the rule
/// that the value never enters the conversation. It contains names only, never a value.
enum AgentPromptCopy {
    /// `includeNote: false` is only for the on-screen preview, which shows the note separately.
    static func prompt(credentialId: String, credential: Credential, language: String = AppL10n.language,
                       includeNote: Bool = true) -> String {
        let chinese = language == "zh-Hans"
        let command = CredentialUsageCopy.runCommand(credentialId: credentialId, credential: credential)
            .replacingOccurrences(of: "<your command>", with: chinese ? "<命令>" : "<command>")

        let textFields = credential.fields
            .filter { $0.value.secret && $0.value.fileFormat == nil }
            .keys.sorted()
        let fileFields = credential.fields
            .filter { $0.value.fileFormat != nil }
            .keys.sorted()

        var arrivals: [String] = textFields.map { name in
            let variable = EnvironmentVariableName.from(fieldName: name)
            return chinese ? "`\(name)` 会变成环境变量 `\(variable)`" : "`\(name)` arrives as the environment variable `\(variable)`"
        }
        if !fileFields.isEmpty {
            arrivals.append(chinese
                ? "服务账号文件会以临时文件路径的形式注入（见命令里的 --file）"
                : "the service-account file arrives as a temporary file path (see --file in the command)")
        }
        let arrivalText = arrivals.joined(separator: chinese ? "，" : ", ")

        // The note is the user's "visible to AI" description: purpose, limits, renewal links.
        let note = includeNote ? credential.notes.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        if chinese {
            return "我在 KeyKeeper 里存了一把 key，ID 是 `\(credentialId)`（\(arrivalText)）。"
                + "需要用它时，请通过 `\(command)` 运行，让 key 只注入到那个进程里。"
                + "不要向我索要这个值，也不要把它打印出来、写进文件或对话。"
                + "如果组 ID 或字段名不够规范，可以用 `keykeeper edit` 改（旧名会一直可用），改完告诉我。"
                + (note.isEmpty ? "" : "\n备注：\(note)")
        }
        return "I keep an API key in KeyKeeper under the ID `\(credentialId)` (\(arrivalText)). "
            + "When you need it, run the command through `\(command)` so the key is injected only into that process. "
            + "Never ask me for the value, print it, or write it into files or the chat. "
            + "If the group ID or field names are unclear, you may rename them with `keykeeper edit` (old names keep working); tell me what you changed."
            + (note.isEmpty ? "" : "\nNote: \(note)")
    }
}

/// Newest credentials first, for the menu bar's "Just saved" list.
enum RecentCredentials {
    /// `created` is either a day (`2026-09-01`, written by the Add form) or a full ISO 8601
    /// timestamp (written by clipboard/file imports).
    static func date(from stamp: String) -> Date? {
        if let full = ISO8601DateFormatter().date(from: stamp) { return full }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: stamp)
    }

    static func newest(_ entries: [(id: String, credential: Credential)], limit: Int = 3) -> [(id: String, credential: Credential)] {
        entries
            .map { ($0, date(from: $0.credential.created) ?? .distantPast) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .prefix(limit)
            .map(\.0)
    }

    /// "Today", "Yesterday", or a short date in the interface language.
    static func dayLabel(for stamp: String, now: Date = Date(), calendar: Calendar = .current,
                         language: String = AppL10n.language) -> String {
        guard let date = date(from: stamp) else { return stamp }
        if calendar.isDate(date, inSameDayAs: now) { return AppL10n.render("Today", language: language) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return AppL10n.render("Yesterday", language: language)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}

/// Copies non-secret text such as the agent prompt. Secrets go through `SecretPasteboard`.
enum PlainPasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
