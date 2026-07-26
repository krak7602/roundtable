import Foundation
import SwiftUI

/// The spine. Owns the adapters, polls them on a background queue, publishes the
/// normalized session list to the UI, and detects state transitions worth a
/// notification. Everything the menu bar renders flows through here.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [Session] = []

    /// Live permission prompts, keyed by canonical cwd. Populated from harness
    /// hooks; the menu renders Allow / Deny / Jump for the matching session.
    @Published private(set) var pendingApprovals: [String: PendingApproval] = [:]

    /// How long after we last saw a prompt we keep showing it. Claude re-nudges
    /// a still-pending prompt every ~30-60s (which refreshes lastSeen), so a live
    /// prompt stays; once answered the nudges stop and it ages out.
    private let approvalTTL: TimeInterval = 90

    private let adapters: [any HarnessAdapter]
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "roundtable.scan", qos: .utility)

    /// Called on the *edge* into an attention state (not every poll). The
    /// menu-bar controller uses this to enqueue a transient in-place toast,
    /// which is deliberately not a focus-stealing macOS notification.
    var onAttentionEdge: ((Session) -> Void)?

    /// Remember the last state we saw per session, so we only fire on the edge.
    private var lastState: [String: SessionState] = [:]

    init(adapters: [any HarnessAdapter] = [
            ClaudeCodeAdapter(),
            CodexAdapter(),
            PiAdapter(harness: .pi, homeDir: ".pi"),
            PiAdapter(harness: .ohMyPi, homeDir: ".omp"),
         ]) {
        self.adapters = adapters
    }

    var attentionCount: Int {
        sessions.filter(\.needsAttention).count
    }

    // MARK: - Pending approvals

    /// The prompt (if any) blocking a given session.
    func pendingApproval(for session: Session) -> PendingApproval? {
        pendingApprovals.values.first { $0.matches(session, canonical: Self.canonical) }
    }

    /// Record a permission prompt from a hook. Injectability is resolved off the
    /// main thread (it shells out to find the pane) and folded back in.
    func recordApproval(id: String, sessionId: String, cwd: String, harness: Harness, tool: String, command: String?) {
        guard !(sessionId.isEmpty && cwd.isEmpty) else { return }
        let key = sessionId.isEmpty ? Self.canonical(cwd) : sessionId
        let now = Date()
        let existing = pendingApprovals[key]
        pendingApprovals[key] = PendingApproval(
            id: id, sessionId: sessionId, cwd: cwd, harness: harness, tool: tool,
            command: command ?? existing?.command,
            createdAt: existing?.createdAt ?? now, lastSeen: now,
            canAnswer: existing?.canAnswer ?? false)

        let needsCommand = command?.isEmpty ?? true
        // Off a throwaway queue, not the poll queue: the retry below can sleep up
        // to a second and must not stall scanning.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let can = AnswerInjector.canAnswer(cwd: cwd)
            // The hook fires the instant the prompt shows, a beat before the tool
            // call lands in the transcript, so read-with-retry to catch the command.
            var enriched: String?
            if needsCommand {
                for _ in 0..<6 {
                    if let c = HarnessDetail.pendingCommand(harness: harness, sessionId: sessionId), !c.isEmpty {
                        enriched = c; break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            // Baseline the resolution clock now: the pending tool call is on disk,
            // so any later transcript write means the prompt was answered.
            let baseline = Date()
            Task { @MainActor in
                guard var pa = self?.pendingApprovals[key] else { return }
                pa.canAnswer = can
                if pa.command?.isEmpty ?? true, let enriched { pa.command = enriched }
                pa.baseline = baseline
                self?.pendingApprovals[key] = pa
            }
        }
    }

    func clearApproval(_ approval: PendingApproval) {
        pendingApprovals = pendingApprovals.filter { $0.value.id != approval.id }
    }

    func start(interval: TimeInterval = 2.0) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Guards against overlapping scans: if one is still running when the timer
    /// fires (a slow lsof can exceed the 2s interval), skip rather than pile up.
    private var scanning = false

    private func refresh() {
        guard !scanning else { return }
        scanning = true
        let adapters = self.adapters
        scanQueue.async { [weak self] in
            let scanned = adapters.flatMap { $0.scan() }
            let live = ProcessCorrelator.liveHarnessProcesses()
            let filtered = Self.keepLive(scanned, liveProcesses: live)
            Task { @MainActor in
                self?.scanning = false
                self?.apply(filtered)
            }
        }
    }

    /// The DISK+PROC join: keep only sessions whose cwd has a live harness
    /// process, and keep as many transcripts per (harness, cwd) as there are
    /// live processes there. Running two agents of the same harness in one
    /// directory is normal, so collapsing to one row would hide real work; but
    /// old transcripts in that directory still have to be dropped, and the
    /// process count is what tells the two apart.
    ///
    /// Paths are canonicalized (symlinks/firmlinks resolved) because the process
    /// cwd is the resolved path while a harness may record the symlinked one. A
    /// mismatch would silently drop a live session from the UI.
    nonisolated static func keepLive(
        _ sessions: [Session], liveProcesses: [(comm: String, cwd: String)]
    ) -> [Session] {
        // How many live agents of each harness are in each directory.
        var counts: [String: Int] = [:]
        for p in liveProcesses {
            counts["\(p.comm)\u{1}\(canonical(p.cwd))", default: 0] += 1
        }

        var grouped: [String: [Session]] = [:]
        for s in sessions {
            // `shortName` is also the process name we match on (claude, codex, pi, omp).
            let key = "\(s.harness.shortName)\u{1}\(canonical(s.cwd))"
            guard counts[key] != nil else { continue }   // nothing running there
            grouped[key, default: []].append(s)
        }

        return grouped.flatMap { key, group in
            group.sorted { $0.updatedAt > $1.updatedAt }.prefix(counts[key] ?? 1)
        }
    }

    nonisolated private static func canonical(_ path: String) -> String {
        path.isEmpty ? path : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func apply(_ scanned: [Session]) {
        // Respect per-harness visibility from settings.
        let visible = scanned.filter { AppSettings.shared.isEnabled($0.harness) }

        // Edge detection runs on the RAW transcript state, so overlaying a
        // pending prompt below never double-fires the toast the hook already sent.
        var next: [String: SessionState] = [:]
        for s in visible {
            let previous = lastState[s.id]
            if previous != s.state, s.state.needsAttention, previous != nil {
                onAttentionEdge?(s)
            }
            next[s.id] = s.state
        }
        lastState = next   // prune ids that are no longer live

        // Drop resolved/dead prompts, then overlay the survivors so the row goes
        // red and carries the Allow/Deny bar, matching the toast the hook fired.
        pruneApprovals(live: visible)
        let overlaid = visible.map { s -> Session in
            guard pendingApproval(for: s) != nil else { return s }
            var s = s; s.state = .waitingPermission; return s
        }

        // Attention-first, then most-recently-active.
        self.sessions = overlaid.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Drop prompts that were answered (the session's transcript advanced past
    /// the baseline we set when we recorded it), aged out, or whose session is no
    /// longer live, so the menu never shows a stale Allow/Deny.
    private func pruneApprovals(live sessions: [Session]) {
        guard !pendingApprovals.isEmpty else { return }
        let now = Date()
        pendingApprovals = pendingApprovals.filter { _, pa in
            guard let session = sessions.first(where: { pa.matches($0, canonical: Self.canonical) }) else { return false }
            // Answered elsewhere: a transcript write newer than our baseline. Small
            // margin so the tool-call write that created the prompt doesn't count.
            if let baseline = pa.baseline, session.updatedAt.timeIntervalSince(baseline) > 1.0 { return false }
            return now.timeIntervalSince(pa.lastSeen) < approvalTTL
        }
    }
}
