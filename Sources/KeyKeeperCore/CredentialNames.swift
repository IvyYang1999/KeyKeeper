import Foundation

/// The two kinds of names a credential has.
///
/// People write titles, notes and field display names however they like; agents may rewrite
/// them too. Machines use the group ID (`keykeeper run -c <group ID>`) and field names (which
/// become environment variables). Those follow strict rules, and every earlier one stays an
/// alias so scripts written against it keep working.
public enum CredentialNames {
    public static let maximumLength = 64

    /// Lowercase ASCII letters, digits, `-`, `_`, `.`; starts with a letter or digit.
    public static func isValidGroupId(_ name: String) -> Bool {
        name.wholeMatch(of: #/[a-z0-9][a-z0-9._\-]{0,63}/#) != nil
    }

    /// ASCII letters, digits, `-`, `_`, `.`; starts with a letter or digit. No spaces, and no
    /// `:` or `=`, which separate parts of `--file id:field=VAR`.
    public static func isValidFieldName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._\-]{0,63}/#) != nil
    }

    /// A machine name from whatever a person typed: Chinese and accented text become plain
    /// Latin ("百度千帆" → "bai-du-qian-fan"), everything else that isn't a letter, digit or
    /// underscore becomes a dash. Empty when nothing usable is left.
    public static func slug(_ text: String) -> String {
        let latin = NSMutableString(string: text)
        CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)
        let mapped = (latin as String).lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_") ? character : "-"
        }
        let collapsed = String(mapped).replacing(#/-{2,}/#, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return String(collapsed.prefix(maximumLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }
}

extension MetaFile {
    /// The current group ID for a name: the name itself, or the credential that used to be called that.
    public func resolveGroupId(_ name: String) -> String? {
        if credentials[name] != nil { return name }
        return credentials.first { $0.value.aliases?.contains(name) == true }?.key
    }

    /// Whether any credential other than `owner` uses `name` as its group ID or an old one.
    func groupIdIsTaken(_ name: String, except owner: String) -> Bool {
        credentials.contains { id, credential in
            id != owner && (id == name || credential.aliases?.contains(name) == true)
        }
    }
}

extension Credential {
    /// The current field name for a name: the name itself, or the field that used to be called that.
    public func resolveFieldName(_ name: String) -> String? {
        if fields[name] != nil { return name }
        return fields.first { $0.value.aliases?.contains(name) == true }?.key
    }

    /// Environment variable names `run` injects for a field: the current one first, then those
    /// of earlier names, without duplicates.
    public func environmentNames(forField field: String, prefix: String = "") -> [String] {
        var names = [EnvironmentVariableName.from(fieldName: field, prefix: prefix)]
        for alias in fields[field]?.aliases ?? [] {
            let name = EnvironmentVariableName.from(fieldName: alias, prefix: prefix)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }
}
