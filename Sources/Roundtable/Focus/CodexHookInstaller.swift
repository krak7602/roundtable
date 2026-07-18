import Foundation

/// Installs a Codex `PermissionRequest` hook. That's the new hooks-engine event
/// that fires (running an external command) exactly when Codex needs the user to
/// approve a command/patch. This is Codex's analog of Claude's Notification hook;
/// the legacy `notify` program only emits turn-complete and can't do this.
///
/// Codex config is TOML, so we append a marker-delimited block at EOF (safe for
/// array-of-tables) and remove it by markers. Requires a Codex build with the
/// hooks crate (~mid-2026 rust-v0.14x+).
enum CodexHookInstaller {
    private static let beginMarker = "# >>> roundtable (managed) >>>"
    private static let endMarker = "# <<< roundtable <<<"

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    static func isInstalled() -> Bool {
        (try? String(contentsOf: configURL, encoding: .utf8))?.contains(beginMarker) ?? false
    }

    static func install(binaryPath: String) -> String {
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard !text.contains(beginMarker) else { return "Codex hook already installed." }
        backup(text)

        // Codex runs `command` via a shell, so a path with spaces must be shell-
        // quoted; the TOML value uses a single-quoted literal so those inner
        // double-quotes need no TOML escaping.
        let shellPath = binaryPath.contains(" ") ? "\"\(binaryPath)\"" : binaryPath
        let command = "\(shellPath) --hook"
        let block = """

        \(beginMarker)
        [[hooks.PermissionRequest]]

        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = '\(command)'
        \(endMarker)

        """
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += block
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
        return "Installed Codex PermissionRequest hook → \(binaryPath) --hook"
    }

    static func uninstall() -> String {
        guard var text = try? String(contentsOf: configURL, encoding: .utf8),
              let start = text.range(of: beginMarker),
              let end = text.range(of: endMarker) else { return "No Codex hook to remove." }
        // Remove from the newline before the begin marker through the end marker.
        let from = text[..<start.lowerBound].lastIndex(of: "\n") ?? start.lowerBound
        text.removeSubrange(from..<end.upperBound)
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
        return "Removed Codex hook from config.toml."
    }

    private static func backup(_ text: String) {
        let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.toml.roundtable-backup")
        // Write-once: don't overwrite the pristine original on a second install.
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? text.write(to: backup, atomically: true, encoding: .utf8)
    }
}
