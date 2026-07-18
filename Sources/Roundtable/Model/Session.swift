import Foundation

/// Which agent harness produced a session.
enum Harness: String, Codable, Sendable, CaseIterable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case pi = "Pi"
    case ohMyPi = "Oh My Pi"

    var shortName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .pi: return "pi"
        case .ohMyPi: return "omp"
        }
    }
}

/// The normalized lifecycle state every adapter maps its harness into.
/// `needsAttention` is the whole product in one bit.
enum SessionState: String, Codable, Sendable {
    case working            // actively running / executing a tool
    case waitingInput       // finished a turn, waiting for the human
    case waitingPermission  // blocked on a permission prompt
    case idle               // alive but quiet, nothing pending
    case done               // session ended cleanly
    case error              // session ended in an error

    var needsAttention: Bool {
        switch self {
        case .waitingInput, .waitingPermission, .error: return true
        case .working, .idle, .done: return false
        }
    }

    /// Small colored glyph shown in the menu row.
    var dot: String {
        switch self {
        case .working: return "🟡"
        case .waitingInput: return "🟢"
        case .waitingPermission: return "🔴"
        case .idle: return "⚪️"
        case .done: return "✅"
        case .error: return "❌"
        }
    }

    var label: String {
        switch self {
        case .working: return "working"
        case .waitingInput: return "waiting for you"
        case .waitingPermission: return "needs permission"
        case .idle: return "idle"
        case .done: return "done"
        case .error: return "error"
        }
    }
}

/// The single normalized shape the UI ever talks to. Every adapter fills this;
/// the menu bar never knows which harness it came from.
struct Session: Identifiable, Sendable {
    let id: String              // stable per session (e.g. the harness session UUID)
    let harness: Harness
    var name: String            // human-friendly session name (slug / title)
    var project: String         // last path component of cwd, for display
    var cwd: String             // working directory, the join key to a process
    var state: SessionState
    var lastLine: String        // one-line preview of the latest output
    var updatedAt: Date         // last activity timestamp (drives sorting / staleness)

    /// True only for Tier-2 (owned-PTY) sessions once reply-from-bar lands.
    var canReply: Bool = false

    var needsAttention: Bool { state.needsAttention }
}
