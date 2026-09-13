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
        "EDITOR", "VISUAL", "PAGER", "TMPDIR", "HOME",
        // 【独立审计第二轮】same class, missed the first time: config files, askpass helpers and shell
        // hooks run code just as surely as GIT_SSH_COMMAND does.
        "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_ASKPASS", "SSH_ASKPASS", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR", "GIT_PROXY_COMMAND",
        "ZDOTDIR", "LESSOPEN", "LESSCLOSE", "PROMPT_COMMAND", "SHELLOPTS", "BASHOPTS", "PS4", "BROWSER",
        "PYTHONBREAKPOINT", "PYTHONINSPECT", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH",
        "PERL5DB", "PERLLIB", "RUSTC_WRAPPER", "GEM_HOME", "GEM_PATH", "LUA_INIT", "XDG_CONFIG_HOME",
        // Not USER or LOGNAME: they name someone, they do not decide what runs. And a credential
        // on the maintainer's own Mac has a field called `User` — refusing it at injection would
        // make that credential unusable for no gain.
    ]

    static let reservedPrefixes = ["DYLD_", "LD_", "GIT_CONFIG_", "BASH_FUNC_", "NPM_CONFIG_"]

    public static func isReserved(fieldName: String, prefix: String = "") -> Bool {
        isReservedVariable(from(fieldName: fieldName, prefix: prefix))
    }

    /// For a finished variable name — what `run` is about to set.
    public static func isReservedVariable(_ name: String) -> Bool {
        reservedNames.contains(name) || reservedPrefixes.contains { name.hasPrefix($0) }
    }

    public static func refusalMessage(_ name: String) -> String {
        "'\(name)' is an environment variable that decides how programs run (like PATH), so KeyKeeper will not set it. Rename the field in KeyKeeper, or use a different --prefix."
    }
}
