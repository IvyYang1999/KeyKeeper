import Foundation

/// How a field name becomes the environment variable `keykeeper run` injects.
/// Shared by the CLI (which injects) and the GUI (which previews the name).
public enum EnvironmentVariableName {
    /// "api-key" → "API_KEY", "base url" → "BASE_URL", "apiKey" → "APIKEY"
    public static func from(fieldName: String, prefix: String = "") -> String {
        let name = fieldName
            .uppercased()
            .map { $0.isLetter || $0.isNumber ? $0 : Character("_") }
            .map(String.init)
            .joined()
            .replacing(#/_{2,}/#, with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return prefix + name
    }

    /// Variable names that change how a program runs, rather than what it can reach.
    ///
    /// 【安全审计 2026-09-13】Field names become environment variables, and renaming a field or
    /// adding a plain one goes through the promptless metadata path. A local process could name
    /// a field `path` (or set `dyld-insert-libraries`) and the next `keykeeper run` would
    /// override what the child process inherits — that is not a leak, that is execution.
    ///
    /// Matching is on the derived variable name, so `path`, `PATH` and `Path` are the same thing,
    /// and a prefix that recreates a dangerous name is caught too.
    static let reservedNames: Set<String> = [
        "PATH", "SHELL", "IFS", "ENV", "BASH_ENV", "CDPATH", "GLOBIGNORE",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_ROOT_PATH",
        "LD_PRELOAD", "LD_LIBRARY_PATH",
        "GIT_SSH", "GIT_SSH_COMMAND", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EDITOR",
        "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH",
        "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB", "JAVA_TOOL_OPTIONS",
        "EDITOR", "VISUAL", "PAGER", "TMPDIR", "HOME", "USER", "LOGNAME",
    ]

    public static func isReserved(fieldName: String, prefix: String = "") -> Bool {
        reservedNames.contains(from(fieldName: fieldName, prefix: prefix))
    }
}
