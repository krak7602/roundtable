import Foundation

/// Reads Codex CLI rollout transcripts at
/// ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
///
/// Each line is `{ timestamp, type, payload }`. State comes from the `event_msg`
/// turn markers (zero-config Tier 1a):
///   - most recent event_msg == "task_complete"  → waitingInput
///       (payload.last_agent_message is the last line, for free)
///   - most recent event_msg == "task_started"   → working
struct CodexAdapter: HarnessAdapter {
    let harness: Harness = .codex

    private let maxAge: TimeInterval = 48 * 60 * 60

    private var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private var indexPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    }

    /// Codex keeps a central name index mapping id to thread_name. This is the
    /// authoritative session name (its own UI uses it), so prefer it over cwd.
    /// Read the whole index (one small line per session) so a live session whose
    /// name was set long ago isn't lost to a tail cutoff. Later lines win.
    private func loadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: indexPath) else { return [:] }
        var names: [String: String] = [:]
        for entry in TailReader.jsonLines(from: String(decoding: data, as: UTF8.self)) {
            if let id = entry["id"] as? String, let name = entry["thread_name"] as? String, !name.isEmpty {
                names[id] = name
            }
        }
        return names
    }

    func scan() -> [Session] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }

        let names = loadNames()
        var sessions: [Session] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(mtime) <= maxAge else { continue }
            if let s = parse(rollout: url, mtime: mtime, names: names) { sessions.append(s) }
        }
        return sessions
    }

    private func parse(rollout url: URL, mtime: Date, names: [String: String]) -> Session? {
        guard let chunk = TailReader.lastChunk(of: url.path) else { return nil }
        let entries = TailReader.jsonLines(from: chunk)
        guard !entries.isEmpty else { return nil }

        // session_meta is line 1 (may be outside the tail on big files), so read it
        // directly; fall back to a turn_context cwd from the tail.
        let meta = TailReader.firstLine(of: url.path)
        let metaPayload = meta?["payload"] as? [String: Any]
        let sessionId = (metaPayload?["session_id"] as? String)
            ?? (metaPayload?["id"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let cwd = (metaPayload?["cwd"] as? String) ?? tailCWD(entries) ?? ""

        let (state, lastLine) = inferState(from: entries)
        let name = names[sessionId]
            ?? (cwd.isEmpty ? "codex session" : (cwd as NSString).lastPathComponent)

        return Session(
            id: sessionId,
            harness: .codex,
            name: name,
            project: cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent,
            cwd: cwd,
            state: state,
            lastLine: lastLine,
            updatedAt: mtime
        )
    }

    /// turn_context entries carry cwd and appear every turn, so the tail has one.
    private func tailCWD(_ entries: [[String: Any]]) -> String? {
        for entry in entries.reversed() {
            if let p = entry["payload"] as? [String: Any], let cwd = p["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    private func inferState(from entries: [[String: Any]]) -> (SessionState, String) {
        var lastAgentText = ""
        for entry in entries.reversed() {
            guard let type = entry["type"] as? String,
                  let payload = entry["payload"] as? [String: Any] else { continue }

            if type == "event_msg" {
                switch payload["type"] as? String {
                case "task_complete":
                    let msg = (payload["last_agent_message"] as? String) ?? lastAgentText
                    return (.waitingInput, oneLine(msg))
                case "task_started":
                    return (.working, lastAgentText.isEmpty ? "working…" : oneLine(lastAgentText))
                case "agent_message":
                    if lastAgentText.isEmpty, let m = payload["message"] as? String { lastAgentText = m }
                default:
                    break
                }
            }
        }
        return (.working, oneLine(lastAgentText))
    }

    private func oneLine(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
    }

    // MARK: - Peek / approval detail (off-main safe)

    /// The command a session is blocked on, from the latest tool call in its
    /// rollout. Codex records these as `custom_tool_call` whose `input` is a JS
    /// snippet embedding `{"cmd":"…"}`.
    static func pendingCommand(sessionId: String) -> String? {
        guard let p = transcriptPath(sessionId: sessionId),
              let chunk = TailReader.lastChunk(of: p) else { return nil }
        for entry in TailReader.jsonLines(from: chunk).reversed() {
            guard let payload = entry["payload"] as? [String: Any] else { continue }
            if payload["type"] as? String == "custom_tool_call" {
                return describeCall(name: payload["name"] as? String, input: payload["input"] as? String)
            }
        }
        return nil
    }

    static func recentActivity(sessionId: String, limit: Int = 16) -> [String] {
        guard let p = transcriptPath(sessionId: sessionId),
              let chunk = TailReader.lastChunk(of: p) else { return [] }
        var items: [String] = []
        for entry in TailReader.jsonLines(from: chunk) {
            guard let payload = entry["payload"] as? [String: Any] else { continue }
            switch (entry["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "user_message"):
                if let m = payload["message"] as? String { let f = flatten(m); if !f.isEmpty { items.append("❯ \(f)") } }
            case ("event_msg", "agent_message"):
                if let m = payload["message"] as? String { let f = flatten(m); if !f.isEmpty { items.append(f) } }
            case ("response_item", "custom_tool_call"):
                items.append("→ \(describeCall(name: payload["name"] as? String, input: payload["input"] as? String))")
            default:
                break
            }
        }
        return Array(items.suffix(limit))
    }

    /// The newest rollout file whose name carries this session id, without
    /// walking guessed date paths.
    private static func transcriptPath(sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.pathExtension == "jsonl" && url.lastPathComponent.contains(sessionId) {
            return url.path
        }
        return nil
    }

    private static func describeCall(name: String?, input: String?) -> String {
        let n = name ?? "tool"
        guard let input, !input.isEmpty else { return n }
        if let cmd = jsonStringValue(key: "cmd", in: input) ?? jsonStringValue(key: "command", in: input) {
            return flatten(cmd)
        }
        return flatten("\(n) \(input)")
    }

    /// Pull one JSON string value for `key` out of an arbitrary text blob (the
    /// input is JS, not clean JSON, so a targeted scan beats full parsing).
    private static func jsonStringValue(key: String, in s: String) -> String? {
        guard let k = s.range(of: "\"\(key)\"") else { return nil }
        var rest = s[k.upperBound...].drop { $0 == " " || $0 == ":" }.drop { $0 == " " }
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        var out = ""; var esc = false
        for ch in rest {
            if esc { out.append(ch == "n" ? " " : ch); esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }

    private static func flatten(_ s: String) -> String {
        let c = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count > 180 ? String(c.prefix(180)) + "…" : c
    }
}
