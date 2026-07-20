import Foundation

/// Reads Pi and Oh My Pi transcripts. They share session format v3, so a single
/// adapter covers both, with two roots:
///   Pi     ~/.pi/agent/sessions/<project>/<ts>_<id>.jsonl
///   Oh My Pi  ~/.omp/agent/sessions/<project>/<ts>_<id>.jsonl
///
/// The primary session file sits directly under the project dir. A same-named
/// sub-directory holds subagent transcripts, which we deliberately skip.
///
/// Header (start of file): a `title` record (live human title, rewritten in
/// place) and a `session` record (`cwd`, `id`, `version`). State comes from the
/// last `message` entry's `stopReason`:
/// stop or length means waiting for input, toolUse means working, and error is error.
final class PiAdapter: HarnessAdapter, @unchecked Sendable {
    let harness: Harness
    private let homeDir: String   // ".pi" or ".omp"
    private let cache = TranscriptCache()

    private let maxAge: TimeInterval = 48 * 60 * 60

    init(harness: Harness, homeDir: String) {
        self.harness = harness
        self.homeDir = homeDir
    }

    private var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(homeDir)/agent/sessions", isDirectory: true)
    }

    func scan() -> [Session] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [Session] = []
        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            // Non-recursive: immediate .jsonl children are the primary sessions;
            // the sibling <ts>_<id>/ directories (subagents) are left untouched.
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(mtime) <= maxAge else { continue }
                if let s = cache.resolve(path: file.path, mtime: mtime, parse: { parse(session: file, mtime: mtime) }) {
                    sessions.append(s)
                }
            }
        }
        cache.endScan()
        return sessions
    }

    private func parse(session url: URL, mtime: Date) -> Session? {
        // Header first (title + session record live at the start of the file).
        let head = TailReader.jsonLines(from: TailReader.headChunk(of: url.path) ?? "")
        var cwd = ""
        var sessionId = ""
        var title = ""
        for entry in head {
            switch entry["type"] as? String {
            case "session":
                cwd = (entry["cwd"] as? String) ?? cwd
                sessionId = (entry["id"] as? String) ?? sessionId
            case "title":
                if let t = entry["title"] as? String, !t.isEmpty { title = t }
            default:
                break
            }
        }
        // A later title_change (near the tail) supersedes the header title.
        let tail = TailReader.jsonLines(from: TailReader.lastChunk(of: url.path) ?? "")
        guard !tail.isEmpty else { return nil }
        for entry in tail.reversed() where entry["type"] as? String == "title_change" {
            if let t = entry["title"] as? String, !t.isEmpty { title = t; break }
        }

        if sessionId.isEmpty {
            // filename is <ts>_<id>.jsonl, so the id is the part after the underscore.
            let base = url.deletingPathExtension().lastPathComponent
            sessionId = base.split(separator: "_").last.map(String.init) ?? base
        }

        let (state, lastLine) = inferState(from: tail)
        let displayName = !title.isEmpty ? title
            : (cwd.isEmpty ? "\(harness.shortName) session" : (cwd as NSString).lastPathComponent)

        return Session(
            id: sessionId,
            harness: harness,
            name: displayName,
            project: cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent,
            cwd: cwd,
            state: state,
            lastLine: lastLine,
            updatedAt: mtime
        )
    }

    private func inferState(from entries: [[String: Any]]) -> (SessionState, String) {
        for entry in entries.reversed() {
            guard entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any] else { continue }
            let role = message["role"] as? String

            if role == "assistant" {
                let text = lastText(in: message)
                switch message["stopReason"] as? String {
                case "stop", "length", "endTurn":
                    return (.waitingInput, text)
                case "toolUse":
                    return (.working, text.isEmpty ? "running a tool…" : text)
                case "error":
                    let err = (message["errorMessage"] as? String).map(oneLine) ?? "error"
                    return (.error, err)
                case "aborted":
                    return (.waitingInput, text.isEmpty ? "aborted" : text)
                default:
                    return (.working, text)
                }
            }
            if role == "user" || role == "tool" {
                return (.working, "…thinking")
            }
        }
        return (.working, "")
    }

    /// Newest text block in a message's content array, collapsed to one line.
    private func lastText(in message: [String: Any]) -> String {
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        for block in content.reversed() where block["type"] as? String == "text" {
            if let t = block["text"] as? String { return oneLine(t) }
        }
        return ""
    }

    private func oneLine(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
    }

    // MARK: - Peek / approval detail (off-main safe; `homeDir` picks .pi vs .omp)

    /// The command a session is blocked on: the newest `toolCall` block in the
    /// last assistant message.
    static func pendingCommand(sessionId: String, homeDir: String) -> String? {
        guard let p = transcriptPath(sessionId: sessionId, homeDir: homeDir),
              let chunk = TailReader.lastChunk(of: p) else { return nil }
        for entry in TailReader.jsonLines(from: chunk).reversed() {
            guard entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content.reversed() where block["type"] as? String == "toolCall" {
                return describeCall(block)
            }
            break
        }
        return nil
    }

    static func recentActivity(sessionId: String, homeDir: String, limit: Int = 16) -> [String] {
        guard let p = transcriptPath(sessionId: sessionId, homeDir: homeDir),
              let chunk = TailReader.lastChunk(of: p) else { return [] }
        var items: [String] = []
        for entry in TailReader.jsonLines(from: chunk) {
            guard entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any] else { continue }
            let role = message["role"] as? String
            if let s = message["content"] as? String {   // plain user text
                let f = flatten(s); if !f.isEmpty { items.append(role == "user" ? "❯ \(f)" : f) }
                continue
            }
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String { let f = flatten(t); if !f.isEmpty { items.append(role == "user" ? "❯ \(f)" : f) } }
                case "toolCall":
                    items.append("→ \(describeCall(block))")
                default:
                    break
                }
            }
        }
        return Array(items.suffix(limit))
    }

    private static func transcriptPath(sessionId: String, homeDir: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(homeDir)/agent/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        // The primary session file is named <ts>_<id>.jsonl; match on the id.
        for case let url as URL in walker where url.pathExtension == "jsonl" && url.lastPathComponent.contains(sessionId) {
            return url.path
        }
        return nil
    }

    private static func describeCall(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let args = block["arguments"] as? [String: Any] ?? [:]
        if let cmd = (args["command"] ?? args["cmd"]) as? String, !cmd.isEmpty { return flatten(cmd) }
        if let fp = (args["file_path"] ?? args["path"]) as? String, !fp.isEmpty {
            return "\(name) \((fp as NSString).lastPathComponent)"
        }
        return name
    }

    private static func flatten(_ s: String) -> String {
        let c = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count > 180 ? String(c.prefix(180)) + "…" : c
    }
}
