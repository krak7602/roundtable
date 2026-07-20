import Foundation

/// Routes transcript reads to the right adapter for a harness. Used for both the
/// peek (recent activity) and the approval command preview.
enum HarnessDetail {
    static func recentActivity(for session: Session) -> [String] {
        switch session.harness {
        case .claudeCode: return ClaudeCodeAdapter.recentActivity(sessionId: session.id)
        case .codex:      return CodexAdapter.recentActivity(sessionId: session.id)
        case .pi:         return PiAdapter.recentActivity(sessionId: session.id, homeDir: ".pi")
        case .ohMyPi:     return PiAdapter.recentActivity(sessionId: session.id, homeDir: ".omp")
        }
    }

    static func pendingCommand(harness: Harness, sessionId: String) -> String? {
        switch harness {
        case .claudeCode: return ClaudeCodeAdapter.pendingCommand(sessionId: sessionId)
        case .codex:      return CodexAdapter.pendingCommand(sessionId: sessionId)
        case .pi:         return PiAdapter.pendingCommand(sessionId: sessionId, homeDir: ".pi")
        case .ohMyPi:     return PiAdapter.pendingCommand(sessionId: sessionId, homeDir: ".omp")
        }
    }
}

/// A short "what's happening here" preview for a session, fetched without
/// switching to it. Reads the harness transcript (clean content, no terminal
/// chrome); falls back to the live muxy screen, then the last line. Off-main.
enum SessionPeek {
    static let lines = 24

    /// Recent activity as discrete items (rendered with a separator between each).
    static func content(for session: Session) -> [String] {
        let activity = HarnessDetail.recentActivity(for: session)
        if !activity.isEmpty { return activity }

        // Fallback: the live muxy screen (de-ruled), for sessions whose transcript
        // we couldn't read.
        if let loc = ProcessCorrelator.locate(cwd: session.cwd),
           let pane = loc.paneEnv["MUXY_PANE_ID"], !pane.isEmpty,
           let screen = MuxyControl.query("read-screen|\(pane)|\(lines)") {
            let tidied = tidy(screen)
            if !tidied.isEmpty { return [tidied] }
        }
        return [session.lastLine.isEmpty ? "No recent output." : session.lastLine]
    }

    /// Horizontal-rule glyphs a TUI draws as separators; whole lines of these are
    /// noise in a text peek.
    private static let ruleChars = Set("─━┄┅┈┉╌╍—―_=")

    /// Drop the TUI's separator rules, collapse blank runs, and trim the edges.
    private static func tidy(_ s: String) -> String {
        let raw = s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        let deruled = raw.map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            return (!t.isEmpty && t.allSatisfy { ruleChars.contains($0) }) ? "" : line
        }
        var out: [String] = []
        for line in deruled {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let prevBlank = out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
            if blank && prevBlank { continue }
            out.append(line)
        }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        while let first = out.first, first.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        return out.joined(separator: "\n")
    }
}
