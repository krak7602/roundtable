import Foundation
import Darwin

enum ApprovalDecision { case allow, deny }

/// Types an Allow/Deny answer into the terminal's own live permission prompt, so
/// the agent resolves exactly as if the user had pressed the keys there. This is
/// the remote-control model: the terminal prompt stays authoritative and fully
/// answerable, we just press the keys for you. Only terminals we know how to
/// drive are supported; the UI falls back to Jump everywhere else.
enum AnswerInjector {

    /// One thing to deliver to the prompt: literal text, or a named key.
    private enum KeyOp {
        case text(String)
        case key(String)   // canonical names, mapped per terminal: "enter", "escape"
    }

    /// Can we drive the terminal this session runs in? Computed once when a
    /// prompt is recorded (it shells out to locate the pane), so the row knows
    /// whether to show buttons or just Jump. Do not call from a render path.
    static func canAnswer(cwd: String) -> Bool {
        guard let loc = ProcessCorrelator.locate(cwd: cwd) else { return false }
        return backend(for: loc) != nil
    }

    /// Deliver the answer off the main thread (locate + shell can block).
    static func answer(cwd: String, harness: Harness, decision: ApprovalDecision) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let loc = ProcessCorrelator.locate(cwd: cwd) else {
                NSLog("[Roundtable] answer: no live process @ \(cwd)")
                return
            }
            deliver(keystrokes(harness: harness, decision: decision), loc: loc)
        }
    }

    // MARK: - Per-harness keystrokes

    /// What to press for each harness's prompt. Claude's menu has "Yes" as
    /// option 1 and Esc cancels, both position-stable. Codex/omp values are
    /// first-pass defaults to confirm against a live prompt.
    private static func keystrokes(harness: Harness, decision: ApprovalDecision) -> [KeyOp] {
        switch (harness, decision) {
        case (.claudeCode, .allow): return [.text("1"), .key("enter")]
        case (.claudeCode, .deny):  return [.key("escape")]
        default:
            return decision == .allow ? [.text("y"), .key("enter")]
                                      : [.text("n"), .key("enter")]
        }
    }

    // MARK: - Terminal backends

    private enum Backend { case muxy(pane: String), tmux(pane: String), iterm(guid: String) }

    private static func backend(for loc: ProcessLocation) -> Backend? {
        let env = loc.paneEnv
        let terminal = (loc.terminalApp ?? "").lowercased()

        if let pane = env["MUXY_PANE_ID"], !pane.isEmpty, terminal.contains("muxy") || env["MUXY_WORKTREE_ID"] != nil {
            return .muxy(pane: pane)
        }
        if let pane = env["TMUX_PANE"], !pane.isEmpty {
            return .tmux(pane: pane)
        }
        if let sid = env["ITERM_SESSION_ID"], !sid.isEmpty {
            let guid = sid.split(separator: ":").last.map(String.init) ?? sid
            if !guid.isEmpty, guid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
                return .iterm(guid: guid)
            }
        }
        return nil
    }

    private static func deliver(_ ops: [KeyOp], loc: ProcessLocation) {
        switch backend(for: loc) {
        case .muxy(let pane): deliverMuxy(ops, pane: pane)
        case .tmux(let pane): deliverTmux(ops, pane: pane)
        case .iterm(let guid): deliverITerm(ops, guid: guid)
        case nil: NSLog("[Roundtable] answer: terminal not drivable")
        }
    }

    // muxy: one command per line over its command socket. `send|pane|text` types
    // literal text, `send-keys|pane|name` presses a named key.
    private static func deliverMuxy(_ ops: [KeyOp], pane: String) {
        let socket = muxyCommandSocket()
        for op in ops {
            switch op {
            case .text(let t): unixSocketSend("send|\(pane)|\(t)", path: socket)
            case .key(let k):  unixSocketSend("send-keys|\(pane)|\(k)", path: socket)
            }
        }
    }

    private static func deliverTmux(_ ops: [KeyOp], pane: String) {
        var args = ["tmux", "send-keys", "-t", pane]
        for op in ops {
            switch op {
            case .text(let t): args.append(t)
            case .key(let k):  args.append(tmuxKey(k))
            }
        }
        _ = run("/usr/bin/env", args)
    }

    private static func tmuxKey(_ name: String) -> String {
        switch name {
        case "enter":  return "Enter"
        case "escape": return "Escape"
        default:       return name
        }
    }

    // iTerm2 has no clean single-key send via AppleScript, so handle the two
    // shapes we actually produce: a bare Escape (deny), or text confirmed with a
    // newline (allow).
    private static func deliverITerm(_ ops: [KeyOp], guid: String) {
        let writeLine: String
        if ops.count == 1, case .key("escape") = ops[0] {
            writeLine = "write text (character id 27) newline no"
        } else {
            let text = ops.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            writeLine = "write text \"\(text)\""   // default newline yes = confirm
        }
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is "\(guid)" then
                  tell s to \(writeLine)
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
        _ = run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Transport helpers

    /// muxy's command socket (distinct from MUXY_SOCKET_PATH, which is the
    /// notification socket). Derived from HOME so the "Application Support" space
    /// never trips the env-var parser.
    private static func muxyCommandSocket() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Muxy/muxy.sock"
    }

    /// Send one newline-terminated message to a Unix domain socket and close.
    private static func unixSocketSend(_ message: String, path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= cap else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return }
        Array((message + "\n").utf8).withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, 0) }
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            NSLog("[Roundtable] answer: failed to run \(launch)")
            return ""
        }
    }
}
