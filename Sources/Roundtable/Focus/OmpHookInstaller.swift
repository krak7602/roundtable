import Foundation

/// Installs the Oh My Pi permission relay: a TypeScript hook dropped at omp's
/// global user hooks dir (~/.omp/agent/hooks/pre/), which auto-loads for every
/// session. It registers `tool_approval_requested`, the event omp fires exactly
/// when it blocks waiting for the user to approve a tool, and spawns
/// `Roundtable --hook` with a JSON payload our app already understands.
///
/// omp extensions run in a full Bun runtime, so `Bun.spawn` is available. Unlike
/// Claude (settings.json) and Codex (config.toml), omp has no external-command
/// hook config, so a JS module is the only route.
enum OmpHookInstaller {
    private static var hookURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/hooks/pre/roundtable-notify.ts")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: hookURL.path)
    }

    static func install(binaryPath: String) -> String {
        // omp's hooks dir may not exist yet.
        try? FileManager.default.createDirectory(
            at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let escaped = binaryPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = template.replacingOccurrences(of: "__BINARY__", with: escaped)
        do {
            try source.write(to: hookURL, atomically: true, encoding: .utf8)
            return "Installed omp permission relay → \(hookURL.path)"
        } catch {
            return "Failed to write omp hook: \(error.localizedDescription)"
        }
    }

    static func uninstall() -> String {
        do {
            try FileManager.default.removeItem(at: hookURL)
            return "Removed omp permission relay."
        } catch {
            return "No omp relay to remove."
        }
    }

    /// The hook module. Default-exports a factory `(pi) => void` per omp's
    /// contract; fires the instant omp blocks for approval and forwards to us.
    private static let template = """
    // Roundtable permission relay (auto-generated). Notifies Roundtable when
    // omp is waiting for you to approve a tool. Delete to disable, or toggle
    // it off in Roundtable Settings.
    export default function (pi) {
      pi.on("tool_approval_requested", (event, ctx) => {
        try {
          const payload = JSON.stringify({
            hook_event_name: "PermissionRequest",
            tool_name: (event && event.toolName) || "a tool",
            session_id: (event && event.sessionId) || "",
            cwd: (ctx && ctx.cwd) || pi.cwd || "",
          });
          const child = Bun.spawn(["__BINARY__", "--hook"], {
            stdin: "pipe", stdout: "ignore", stderr: "ignore",
          });
          child.stdin.write(payload);
          child.stdin.end();
        } catch (_) { /* never break omp's approval flow */ }
      });
    }
    """
}
