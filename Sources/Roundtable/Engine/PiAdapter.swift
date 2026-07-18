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
}
