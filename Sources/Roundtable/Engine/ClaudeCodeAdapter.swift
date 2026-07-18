import Foundation

/// Reads Claude Code's per-project transcripts at
/// ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
///
/// State is inferred from the tail of the transcript (zero-config Tier 1a):
///   - last assistant message, stop_reason == "end_turn"  → waitingInput
///   - last assistant message, stop_reason == "tool_use", no following result → working
///   - last entry is a real user prompt (not a tool_result): working
final class ClaudeCodeAdapter: HarnessAdapter, @unchecked Sendable {
    let harness: Harness = .claudeCode
    private let cache = TranscriptCache()

    /// Efficiency bound only: skip parsing transcripts older than this. Liveness
    /// (a matching live process) is the real filter, applied in the store.
    private let maxAge: TimeInterval = 48 * 60 * 60

    private var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func scan() -> [Session] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [Session] = []
        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(mtime) <= maxAge else { continue }
                if let s = cache.resolve(path: file.path, mtime: mtime, parse: { parse(transcript: file, mtime: mtime) }) {
                    sessions.append(s)
                }
            }
        }
        cache.endScan()
        return sessions
    }

    private func parse(transcript url: URL, mtime: Date) -> Session? {
        // Use a wider tail (256KB) so a recent rename or aiTitle survives some
        // activity after it was written. It stays bounded and never reads the
        // whole (multi-MB) file.
        guard let chunk = TailReader.lastChunk(of: url.path, maxBytes: 256 * 1024) else { return nil }
        let entries = TailReader.jsonLines(from: chunk)
        guard !entries.isEmpty else { return nil }

        // Metadata (cwd/slug/sessionId) rides on message lines but not on every
        // record type. The final line is often a snapshot or queue entry with
        // none of it, so search backwards for the newest entry that carries
        // each field.
        func metaValue(_ key: String) -> String? {
            for entry in entries.reversed() {
                if let v = entry[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        // The user's rename is a lone `custom-title` record. Find the newest one
        // in the tail by iterating rather than doing a single byte-match, so a
        // message body that happens to mention "custom-title" can't mask it.
        func customTitle() -> String? {
            for entry in entries.reversed() where entry["type"] as? String == "custom-title" {
                if let t = entry["customTitle"] as? String, !t.isEmpty { return t }
            }
            return nil
        }
        let sessionId = metaValue("sessionId") ?? url.deletingPathExtension().lastPathComponent
        let cwd = metaValue("cwd") ?? ""
        // Name priority: the user's rename, then the AI title, then the random slug.
        let name = customTitle()
            ?? metaValue("aiTitle")
            ?? metaValue("slug")
            ?? url.deletingPathExtension().lastPathComponent

        let (state, lastLine) = inferState(from: entries)

        return Session(
            id: sessionId,
            harness: .claudeCode,
            name: name,
            project: cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent,
            cwd: cwd,
            state: state,
            lastLine: lastLine,
            updatedAt: mtime
        )
    }

    /// Walk the tail backwards to the last message-bearing entry and classify it.
    /// Only live sessions reach the UI, so state is always either working or
    /// waitingInput, never a staleness-based "done".
    private func inferState(from entries: [[String: Any]]) -> (SessionState, String) {
        for entry in entries.reversed() {
            guard let type = entry["type"] as? String else { continue }
            // Skip sub-agent (Task) messages. They share the transcript, and a
            // finished sub-agent must not read as the main session waiting.
            if entry["isSidechain"] as? Bool == true { continue }

            if type == "assistant", let message = entry["message"] as? [String: Any] {
                let stop = message["stop_reason"] as? String
                let text = lastText(in: message) ?? ""
                switch stop {
                case "end_turn", "stop_sequence":
                    return (.waitingInput, text)
                case "tool_use":
                    // Turn still in flight (executing / awaiting a tool result).
                    return (.working, text.isEmpty ? "running a tool…" : text)
                default:
                    return (.working, text)
                }
            }

            if type == "user", let message = entry["message"] as? [String: Any] {
                // A tool_result carries array content; a real prompt is a string.
                if message["content"] is String {
                    return (.working, "…thinking")
                }
                return (.working, "running a tool…")  // tool_result → mid-turn
            }
        }
        return (.working, "")
    }

    /// Newest text block in an assistant message, collapsed to one line.
    private func lastText(in message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content.reversed() where block["type"] as? String == "text" {
            if let t = block["text"] as? String {
                return oneLine(t)
            }
        }
        return nil
    }

    private func oneLine(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
    }
}
