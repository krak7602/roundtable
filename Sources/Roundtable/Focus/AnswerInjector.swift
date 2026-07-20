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

    /// What to press for each harness's prompt.
    /// - Claude: menu with "Yes" as option 1, Esc cancels — both confirmed live.
    /// - Codex / Pi / Oh My Pi: `y`/`n` then Enter. These are best-effort until
    ///   confirmed against a live prompt in each; adjust here if a harness selects
    ///   differently (e.g. a number menu or a bare keypress).
    private static func keystrokes(harness: Harness, decision: ApprovalDecision) -> [KeyOp] {
        switch (harness, decision) {
        case (.claudeCode, .allow): return [.text("1"), .key("enter")]
        case (.claudeCode, .deny):  return [.key("escape")]
        case (.codex, .allow), (.pi, .allow), (.ohMyPi, .allow):
            return [.text("y"), .key("enter")]
        case (.codex, .deny), (.pi, .deny), (.ohMyPi, .deny):
            return [.text("n"), .key("enter")]
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
        for op in ops {
            switch op {
            case .text(let t): MuxyControl.send("send|\(pane)|\(t)")
            case .key(let k):  MuxyControl.send("send-keys|\(pane)|\(k)")
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
