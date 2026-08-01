import Foundation
import SwiftUI
import Combine

/// One user-facing alert: the sessions that newly need attention this pass.
///
/// Batched per poll, so three agents finishing together is one announcement
/// rather than three sounds. `isBaseline` marks the first look after launch or
/// wake — everything that changed while nobody was watching arrives as a single
/// summary instead of a burst of stale, individually-narrated events.
struct AttentionAnnouncement: Sendable {
    let sessions: [Session]
    let isBaseline: Bool

    /// Drives the accent and the sound: a blocking prompt outranks a wait.
    var isPermission: Bool {
        sessions.contains { $0.state == .waitingPermission || $0.state == .error }
    }

    var message: String {
        if sessions.count == 1, let s = sessions.first {
            let name = s.name.count > 26 ? s.name.prefix(26) + "…" : s.name[...]
            return "\(name) — \(s.state.label)"
        }
        return "\(sessions.count) sessions need you"
    }
}

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

    /// Everything worth telling the user, decided in one place. The orb and the
    /// menu bar both subscribe and only render; neither keeps its own idea of
    /// what is new — two competing dedupe maps is exactly how the same prompt
    /// used to alert twice.
    let announcements = PassthroughSubject<AttentionAnnouncement, Never>()

    /// The attention episodes already told to the user: session id → the state
    /// announced. An episode spans one continuous stretch of `needsAttention`;
    /// within it a session is announced once, plus once more if a wait escalates
    /// into a permission prompt. De-escalation keeps the recorded state, so the
    /// prompt-TTL-expires / re-nudge-restores cycle can never read as news again.
    /// The episode ends only when the session stops needing attention.
    private var announced: [String: SessionState] = [:]

    /// Set at launch and on wake: the next pass is a resync of what happened
    /// while nobody was watching, so it coalesces into one summary.
    private var baselinePending = true
    private var lastApplyAt: Date?

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

        // Fold the prompt into the session list right away: the hook no longer
        // fires a toast of its own (the ledger in apply() owns that call), so
        // without this poke the alert would wait out the rest of the poll tick.
        refresh()

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
        // Wake = the user was away. The gap heuristic in announce() catches this
        // too (the timer doesn't tick through sleep), but the explicit signal is
        // free and covers short naps the threshold would miss.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.baselinePending = true }
            }
        }
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

        // Drop resolved/dead prompts, then overlay the survivors so the row goes
        // red and carries the Allow/Deny bar. Announcements are computed from
        // the *overlaid* state: a prompt arriving through a hook and the same
        // session's transcript state flow through one ledger, so they can never
        // produce two separate alerts for one event.
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

        announce(overlaid)
    }

    /// Decide what, if anything, this pass is worth telling the user — the one
    /// place that decision is made. Fires per attention *episode*, so neither
    /// list reordering nor a prompt overlay flickering under a still-waiting
    /// session can re-announce something the user has already been told.
    private func announce(_ sessions: [Session]) {
        // The poll timer doesn't tick through sleep, so a long gap between
        // passes means the machine was away: what changed meanwhile is pent-up
        // news, not breaking news.
        if let last = lastApplyAt, Date().timeIntervalSince(last) > 30 { baselinePending = true }
        lastApplyAt = Date()

        var fresh: [Session] = []
        for s in sessions where s.needsAttention {
            switch announced[s.id] {
            case nil:
                fresh.append(s)                          // a new episode
                announced[s.id] = s.state
            case .waitingInput where s.state == .waitingPermission:
                fresh.append(s)                          // escalation is news
                announced[s.id] = .waitingPermission
            default:
                break                                    // already told; stay quiet
            }
        }
        // Episodes end when the session stops needing attention (or goes away).
        // The next time it needs the user is genuinely new, and announces.
        let inAttention = Set(sessions.filter(\.needsAttention).map(\.id))
        announced = announced.filter { inAttention.contains($0.key) }

        let isBaseline = baselinePending
        baselinePending = false
        guard !fresh.isEmpty else { return }
        deliver(AttentionAnnouncement(sessions: fresh, isBaseline: isBaseline))
    }

    /// Emit, minus anything the user asked their terminal to announce instead.
    /// The ledger has already recorded these as announced either way — muxy
    /// telling the user still counts as the user being told.
    private func deliver(_ announcement: AttentionAnnouncement) {
        guard AppSettings.shared.deferTerminalNotifications else {
            announcements.send(announcement)
            return
        }
        // Off-main: locating the pane shells out.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Only permission prompts are covered by muxy's own hook
            // notification; plain turn-ends still come from us.
            let kept = announcement.sessions.filter {
                !($0.state == .waitingPermission && ProcessCorrelator.terminalSelfNotifies(cwd: $0.cwd))
            }
            guard !kept.isEmpty else { return }
            Task { @MainActor in
                self?.announcements.send(
                    AttentionAnnouncement(sessions: kept, isBaseline: announcement.isBaseline))
            }
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
