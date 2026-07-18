import Foundation

/// Installs Claude Code hooks that let Roundtable catch what transcript-tailing
/// can't: permission prompts and idle-waiting (the `Notification` event), plus
/// instant turn-completion (`Stop`). The hook command is this same binary run as
/// `Roundtable --hook`, which forwards the event to the running app.
///
/// This edits the user's ~/.claude/settings.json, so it's opt-in (--install-hooks)
/// and always backs the file up first.
enum HookInstaller {
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Events we hook. Notification = needs permission / waiting; Stop = finished.
    private static let events = ["Notification", "Stop"]

    static func install(binaryPath: String) -> String {
        guard var settings = loadSettings() else {
            return "Aborted: ~/.claude/settings.json isn't valid JSON. Fix it first — nothing was changed."
        }
        backup()

        let command = "\(shellQuote(binaryPath)) --hook"
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Idempotent: drop any prior Roundtable entry, then add ours.
            groups = groups.filter { !groupIsRoundtable($0) }
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }

        settings["hooks"] = hooks
        write(settings)
        return "Installed Notification + Stop hooks → \(binaryPath) --hook\nBacked up prior settings to settings.json.roundtable-backup"
    }

    static func uninstall() -> String {
        guard var settings = loadSettings() else { return "settings.json isn't valid JSON — left untouched." }
        guard var hooks = settings["hooks"] as? [String: Any] else { return "No hooks to remove." }
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.filter { !groupIsRoundtable($0) }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        write(settings)
        return "Removed Roundtable hooks from settings.json."
    }

    static func isInstalled() -> Bool {
        guard let settings = loadSettings(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.contains { (hooks[$0] as? [[String: Any]] ?? []).contains(where: groupIsRoundtable) }
    }

    /// A hook group is ours if a command ends with our ` --hook` invocation and
    /// also names the Roundtable binary. That's precise enough to leave a user's
    /// own `mytool --hookup` or an unrelated `foo --hook` alone.
    private static func groupIsRoundtable(_ group: [String: Any]) -> Bool {
        let inner = group["hooks"] as? [[String: Any]] ?? []
        return inner.contains { block in
            guard let cmd = block["command"] as? String else { return false }
            return cmd.hasSuffix(" --hook") && cmd.contains("Roundtable")
        }
    }

    /// Absolute path to this executable, for the hook command.
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Roundtable"
    }

    // MARK: - Helpers

    /// Returns `[:]` when the file is absent, which is fine since we'll create
    /// it. Returns `nil` only when the file exists but is unparseable, so callers
    /// bail instead of clobbering it.
    private static func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Write-once: never overwrite an existing backup, or a second install (which
    /// runs on an already-modified file) would destroy the pristine original.
    private static func backup() {
        let backupURL = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.roundtable-backup")
        guard !FileManager.default.fileExists(atPath: backupURL.path),
              let data = try? Data(contentsOf: settingsURL) else { return }
        try? data.write(to: backupURL, options: .atomic)
    }

    private static func write(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    private static func shellQuote(_ s: String) -> String {
        s.contains(" ") ? "\"\(s)\"" : s
    }
}
