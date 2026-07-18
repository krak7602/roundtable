import Foundation

/// A permission prompt a harness is currently blocked on, surfaced from its hook.
/// Held alongside the session so the menu can offer Allow / Deny / Jump. It is
/// deliberately ephemeral: cleared when answered, when the session goes away, or
/// after it ages out.
struct PendingApproval: Identifiable, Sendable {
    let id: String            // dedupe key (prompt id, or synthesized)
    let sessionId: String     // harness session id, the robust match to a Session
    let cwd: String           // join key to the pane; also matches a Session by cwd
    let harness: Harness
    let tool: String          // e.g. "Bash", "Edit" — what's being requested
    var command: String?      // the actual command/argument; enriched from the transcript
    let createdAt: Date       // first seen (for display)
    var lastSeen: Date        // refreshed on each re-nudge; expiry measures from here

    /// Whether we can type the answer into this session's terminal. False means
    /// the UI shows the command + Jump only (no Allow/Deny buttons).
    var canAnswer: Bool = false

    /// Does this prompt belong to the given session? Prefer the session id
    /// (survives a cwd that differs between hook payload and transcript).
    func matches(_ session: Session, canonical: (String) -> String) -> Bool {
        if !sessionId.isEmpty, sessionId == session.id { return true }
        return !cwd.isEmpty && canonical(cwd) == canonical(session.cwd)
    }

    /// One-line preview: the command if we have it, else the tool being requested.
    var preview: String {
        if let c = command, !c.isEmpty { return c }
        return tool.isEmpty ? "a command" : tool
    }
}
