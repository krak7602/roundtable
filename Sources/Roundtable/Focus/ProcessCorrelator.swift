import Foundation
import Darwin

/// Bridges the DISK view (a `Session` from a transcript) to the PROCESS view
/// (a live PID, its owning terminal app, and the per-pane env var the terminal
/// injected). The join key is the working directory.
///
/// This is the deliberately-risky part of the architecture, so it lives behind
/// a small, testable surface.
struct ProcessLocation {
    let pid: Int32
    let terminalAppPID: Int32?
    let terminalApp: String?       // e.g. "iTerm2", "ghostty", "muxy", "tmux host"
    let paneEnv: [String: String]  // ITERM_SESSION_ID / TMUX_PANE / MUXY_PANE_ID / …
}

enum ProcessCorrelator {

    /// Exact process (comm) leaf names we recognize as harness CLIs. We match on
    /// `comm` rather than the full command, which avoids false positives like
    /// Serena MCP servers launched with `--context claude-code`.
    private static let harnessComms: Set<String> = ["claude", "codex", "pi", "omp"]

    /// Every live harness process, as (harness comm, cwd). This is the liveness
    /// gate: a session is "ongoing" only if a matching process is running. The
    /// duplicates matter — two agents of the same harness in one directory are
    /// two sessions, so the caller counts these rather than collapsing them.
    static func liveHarnessProcesses() -> [(comm: String, cwd: String)] {
        harnessProcesses().compactMap { p in processCWD(p.pid).map { (p.comm, $0) } }
    }

    /// Terminal / multiplexer process names we know how to focus.
    private static let terminalComms = [
        "iTerm2", "Terminal", "ghostty", "muxy", "cmux", "tmux", "WezTerm", "kitty", "Alacritty"
    ]

    /// Whether the session's terminal posts its own notifications for agent
    /// events (so ours would be a duplicate). muxy does, via its bundled hook.
    static func terminalSelfNotifies(cwd: String) -> Bool {
        guard let loc = locate(cwd: cwd) else { return false }
        return (loc.terminalApp ?? "").lowercased().contains("muxy") || loc.paneEnv["MUXY_PANE_ID"] != nil
    }

    /// Find the harness process running in `cwd` and resolve its terminal.
    static func locate(cwd: String) -> ProcessLocation? {
        guard !cwd.isEmpty else { return nil }
        for pid in harnessPIDs() where processCWD(pid) == cwd {
            let env = environment(of: pid)
            let (termPID, termName) = owningTerminal(of: pid)
            return ProcessLocation(
                pid: pid,
                terminalAppPID: termPID,
                terminalApp: termName,
                paneEnv: env.filter { isPaneKey($0.key) }
            )
        }
        return nil
    }

    // MARK: - Process table

    private static func harnessPIDs() -> [Int32] { harnessProcesses().map(\.pid) }

    private static func harnessProcesses() -> [(pid: Int32, comm: String)] {
        let out = shell("/bin/ps", ["-axo", "pid=,comm="])
        var found: [(Int32, String)] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<sp]) else { continue }
            let comm = String(trimmed[sp...]).trimmingCharacters(in: .whitespaces)
            let leaf = (comm as NSString).lastPathComponent
            if harnessComms.contains(leaf) {
                found.append((pid, leaf))
            }
        }
        return found
    }

    /// A process's cwd via a direct libproc syscall, with no `lsof` subprocess
    /// spawn. This runs per harness PID on every 2s poll, so the spawn cost
    /// mattered.
    private static func processCWD(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            raw.baseAddress.flatMap { String(validatingCString: $0.assumingMemoryBound(to: CChar.self)) }
        }
    }

    /// Another process's environment, same user only, via `ps eww`.
    private static func environment(of pid: Int32) -> [String: String] {
        let out = shell("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"])
        var env: [String: String] = [:]
        // ps appends `KEY=value KEY=value …` after the command line.
        for token in out.split(separator: " ") {
            if let eq = token.firstIndex(of: "="), token[..<eq].allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                env[String(token[..<eq])] = String(token[token.index(after: eq)...])
            }
        }
        return env
    }

    /// Walk parent PIDs until we hit a known terminal/multiplexer.
    private static func owningTerminal(of pid: Int32) -> (Int32?, String?) {
        var current = pid
        for _ in 0..<12 {
            let out = shell("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sp = out.firstIndex(of: " "),
                  let ppid = Int32(out[..<sp].trimmingCharacters(in: .whitespaces)) else { break }
            let comm = String(out[sp...]).trimmingCharacters(in: .whitespaces)
            let leaf = (comm as NSString).lastPathComponent
            if let match = terminalComms.first(where: { leaf.localizedCaseInsensitiveContains($0) }) {
                return (current, match)
            }
            if ppid <= 1 { break }
            current = ppid
        }
        return (nil, nil)
    }

    private static func isPaneKey(_ key: String) -> Bool {
        // Real per-pane identifiers as observed on-machine. muxy DOES inject a
        // MUXY_PANE_ID (the send-keys target); it also exposes project/worktree.
        ["ITERM_SESSION_ID", "TMUX_PANE", "TMUX",
         "MUXY_PANE_ID", "MUXY_PROJECT_ID", "MUXY_WORKTREE_ID", "MUXY_SOCKET_PATH",
         "CMUX_PANE_ID", "KITTY_WINDOW_ID"].contains(key)
    }

    // MARK: - Shell helper

    private static func shell(_ launch: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
