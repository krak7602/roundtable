import Foundation
import AppKit

/// Brings the terminal seat for a session to the front, in tiers of precision.
/// The floor tier just raises the owning terminal app (via NSRunningApplication,
/// no permission needed). The project tier focuses the right project workspace
/// (muxy `muxy <path>`). The exact tier picks the specific pane or split (tmux
/// today; muxy socket later). The floor always runs, and the more precise tiers
/// layer on when the terminal supports them.
enum FocusEngine {

    /// Runs the process correlation + shell focus off the main thread (they can
    /// block if a terminal hangs), then hops back to main to raise the app.
    static func focus(_ session: Session) {
        let cwd = session.cwd
        let name = session.name
        DispatchQueue.global(qos: .userInitiated).async {
            guard let loc = ProcessCorrelator.locate(cwd: cwd) else {
                NSLog("[Roundtable] focus: no live process for \(name) @ \(cwd)")
                return
            }
            // Terminal-specific selection first, so the target pane/workspace is
            // active before the app comes forward.
            select(cwd: cwd, loc: loc)

            if let termPID = loc.terminalAppPID {
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: termPID)?.activate(options: [.activateAllWindows])
                }
            }
        }
    }

    private static func select(cwd: String, loc: ProcessLocation) {
        let env = loc.paneEnv
        let terminal = (loc.terminalApp ?? "").lowercased()

        // muxy: `muxy <path>` focuses the project workspace for that directory.
        if terminal.contains("muxy") || env["MUXY_PROJECT_ID"] != nil {
            _ = run(muxyPath(), [cwd])
            return
        }

        // tmux: select the inner pane; the app-activate above raises the host GUI.
        if let pane = env["TMUX_PANE"] {
            _ = run("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
            _ = run("/usr/bin/env", ["tmux", "select-window", "-t", pane])
            return
        }

        // iTerm2: exact-session activation via its API/AppleScript is a later
        // pass. App-level activate covers the floor until then.
    }

    /// Prefer the CLI on PATH; fall back to the well-known install location.
    private static func muxyPath() -> String {
        let candidates = ["/usr/local/bin/muxy", "/opt/homebrew/bin/muxy"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/usr/bin/env"   // will resolve `muxy` from PATH via args below
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        // If we fell back to env, prepend the command name.
        proc.arguments = (launch == "/usr/bin/env" && args.first != "tmux") ? ["muxy"] + args : args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            NSLog("[Roundtable] focus: failed to run \(launch) \(args)")
            return ""
        }
    }
}
