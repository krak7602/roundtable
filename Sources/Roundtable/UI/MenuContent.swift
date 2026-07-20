import SwiftUI

/// The dropdown that opens from the menu-bar icon: a list of sessions, attention
/// first, each row a single glanceable line. Clicking a row focuses its pane.
struct MenuContent: View {
    @ObservedObject var store: SessionStore
    var onSettings: () -> Void = {}

    /// The row expanded into a full-height peek (takes over the menu). Only one
    /// at a time, so the peek gets the whole panel.
    @State private var expandedID: String?

    private func toggle(_ id: String) {
        expandedID = (expandedID == id) ? nil : id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if let id = expandedID, let session = store.sessions.first(where: { $0.id == id }) {
                // Peek takeover: just this session, given the whole panel.
                SessionRow(session: session, isExpanded: true, onToggle: { expandedID = nil })
                    .contentShape(Rectangle())
                    .onTapGesture { FocusEngine.focus(session) }
                if let pa = store.pendingApproval(for: session) {
                    ApprovalBar(
                        approval: pa,
                        onAllow: { answer(pa, .allow) },
                        onDeny:  { answer(pa, .deny) },
                        onJump:  { FocusEngine.focus(session) })
                }
                Divider().opacity(0.4)
                PeekView(session: session, onJump: { FocusEngine.focus(session) })
            } else {
                ForEach(store.sessions) { session in
                    VStack(alignment: .leading, spacing: 0) {
                        SessionRow(session: session,
                                   isExpanded: false,
                                   onToggle: { toggle(session.id) })
                            .contentShape(Rectangle())
                            .onTapGesture { FocusEngine.focus(session) }
                        if let pa = store.pendingApproval(for: session) {
                            ApprovalBar(
                                approval: pa,
                                onAllow: { answer(pa, .allow) },
                                onDeny:  { answer(pa, .deny) },
                                onJump:  { FocusEngine.focus(session) })
                        }
                    }
                    Divider().opacity(0.4)
                }
            }

            footer
        }
        .frame(width: 340)
    }

    /// Type the answer into the terminal, then drop the prompt from the menu.
    private func answer(_ pa: PendingApproval, _ decision: ApprovalDecision) {
        AnswerInjector.answer(cwd: pa.cwd, harness: pa.harness, decision: decision)
        store.clearApproval(pa)
    }

    private var header: some View {
        HStack {
            Text("Roundtable").font(.headline)
            Spacer()
            if store.attentionCount > 0 {
                Text("\(store.attentionCount) waiting")
                    .font(.caption).bold()
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: onSettings)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The action row under a session that's blocked on a permission prompt: the
/// command being requested, then Allow / Deny (when we can drive the terminal)
/// and always Jump. No "always allow" by design — that's consequential and rare,
/// so it's a deliberate trip to the terminal via Jump.
struct ApprovalBar: View {
    let approval: PendingApproval
    var onAllow: () -> Void
    var onDeny: () -> Void
    var onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(approval.preview)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                if approval.canAnswer {
                    Button("Allow", action: onAllow).tint(.green)
                    Button("Deny", action: onDeny).tint(.red)
                } else {
                    Text("Answer in the terminal")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Jump", action: onJump)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2).padding(.bottom, 10)
    }
}

struct SessionRow: View {
    let session: Session
    var isExpanded: Bool = false
    var onToggle: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(session.state.dot)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.system(.body, design: .rounded)).bold()
                        .lineLimit(1)
                    Text(session.harness.shortName)
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Text(session.project)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(session.lastLine.isEmpty ? session.state.label : session.lastLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Peek toggle. Its own button so tapping it expands rather than
            // jumping (the rest of the row still jumps).
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Full-height peek: the session's recent activity (Claude transcript, else the
/// live screen), shown plainly so you can triage without switching. Sizes to its
/// content up to a cap, and pins to the newest line at the bottom.
struct PeekView: View {
    let session: Session
    var onJump: () -> Void
    @State private var items: [String]?
    @State private var measured: CGFloat = 0
    private let maxHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let items {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                                Text(item)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .lineSpacing(2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 5)
                                if idx < items.count - 1 { Divider().opacity(0.18) }
                            }
                            Color.clear.frame(height: 0).id("peekEnd")
                        }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: PeekHeightKey.self, value: g.size.height)
                        })
                    }
                    .frame(height: min(max(measured, 40), maxHeight))
                    // Once the async height measurement settles (or the items
                    // change), pin the bottom into view. defaultScrollAnchor
                    // alone doesn't survive the 0→full height jump.
                    .onPreferenceChange(PeekHeightKey.self) { h in
                        measured = h
                        DispatchQueue.main.async { proxy.scrollTo("peekEnd", anchor: .bottom) }
                    }
                    .onChange(of: items) { _, _ in
                        DispatchQueue.main.async { proxy.scrollTo("peekEnd", anchor: .bottom) }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }

            HStack {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                Button("Jump", action: onJump).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10).padding(.bottom, 12)
        .task(id: session.id) { refresh() }
    }

    private func refresh() {
        let s = session
        Task {
            items = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: SessionPeek.content(for: s))
                }
            }
        }
    }
}

private struct PeekHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
