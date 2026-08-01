import Foundation
import AppKit

/// Brings the terminal seat for a session to the front, in tiers of precision.
/// The floor tier just raises the owning terminal app (via NSRunningApplication,
/// no permission needed). The project tier focuses the right project workspace
/// (muxy `muxy <path>`). The exact tier picks the specific pane or split (tmux
/// today; muxy socket later). The floor always runs, and the more precise tiers
/// layer on when the terminal supports them.
enum FocusEngine {

    /// Focus the seat for a session.
    static func focus(_ session: Session) {
        focus(cwd: session.cwd, name: session.name)
    }

    /// Focus by working directory. This is the join key, so a caller that only
    /// has the cwd (a toast fired straight from a hook, before the session is in
    /// the store) can still land the jump.
    ///
    /// Runs the process correlation + shell focus off the main thread (they can
    /// block if a terminal hangs), then hops back to main to raise the app.
    static func focus(cwd: String, name: String) {
        guard !cwd.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let loc = ProcessCorrelator.locate(cwd: cwd) else {
                DebugLog.log("focus", "no live process for \(name) @ \(cwd)")
                NSLog("[Roundtable] focus: no live process for \(name) @ \(cwd)")
                return
            }
            DebugLog.log("focus", "\(name) @ \(cwd) → \(loc.terminalApp ?? "?") pane=\(loc.paneEnv["MUXY_PANE_ID"] ?? loc.paneEnv["ITERM_SESSION_ID"] ?? loc.paneEnv["TMUX_PANE"] ?? "-")")
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

        // muxy: switch to the exact worktree via the command socket. `muxy <path>`
        // only opens the *project*, so with several worktrees per project it lands
        // on the wrong one (or spawns a new one). `switch-worktree|id|project` goes
        // straight to the right worktree; fall back to opening the project only if
        // we somehow lack the worktree id.
        if terminal.contains("muxy") || env["MUXY_PANE_ID"] != nil || env["MUXY_PROJECT_ID"] != nil {
            if let worktree = env["MUXY_WORKTREE_ID"], !worktree.isEmpty {
                let project = env["MUXY_PROJECT_ID"] ?? ""
                MuxyControl.send(project.isEmpty ? "switch-worktree|\(worktree)"
                                                 : "switch-worktree|\(worktree)|\(project)")
            } else if let project = env["MUXY_PROJECT_ID"], !project.isEmpty {
                MuxyControl.send("switch-project|\(project)")
            } else {
                _ = run(muxyPath(), [cwd])
            }
            return
        }

        // tmux: select the inner pane and its window; the app-activate above
        // raises the host GUI.
        if let pane = env["TMUX_PANE"] {
            _ = run("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
            _ = run("/usr/bin/env", ["tmux", "select-window", "-t", pane])
            return
        }

        // iTerm2: select the exact session by its guid (the part of
        // ITERM_SESSION_ID after the colon), so we land in the right split
        // rather than just raising the app. The env var comes from another
        // process and is interpolated into AppleScript, so the guid must match
        // the known UUID shape (hex + dashes) before we trust it, or a crafted
        // value could inject script.
        if let sid = env["ITERM_SESSION_ID"], !sid.isEmpty {
            let guid = sid.split(separator: ":").last.map(String.init) ?? sid
            if !guid.isEmpty, guid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
                selectITerm(guid: guid)
            }
            return
        }

        // kitty: best effort. Needs `allow_remote_control` enabled; fails quietly
        // (into run's error path) when it isn't. The window id is a plain integer;
        // reject anything else rather than pass it to the match expression.
        if let winID = env["KITTY_WINDOW_ID"], !winID.isEmpty,
           winID.allSatisfy(\.isNumber) {
            _ = run("/usr/bin/env", ["kitten", "@", "focus-window", "--match", "id:\(winID)"])
            return
        }
    }

    /// Walk iTerm2's window/tab/session tree and select the split whose id
    /// matches, via AppleScript (its scripting bridge has no direct lookup).
    private static func selectITerm(guid: String) {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is "\(guid)" then
                  select w
                  tell t to select
                  tell s to select
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
        _ = run("/usr/bin/osascript", ["-e", script])
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
