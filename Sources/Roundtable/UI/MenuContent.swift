import SwiftUI

/// The dropdown that opens from the menu-bar icon: a list of sessions, attention
/// first, each row a single glanceable line. Clicking a row focuses its pane.
struct MenuContent: View {
    @ObservedObject var store: SessionStore
    var onSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(store.sessions) { session in
                    VStack(alignment: .leading, spacing: 0) {
                        SessionRow(session: session)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
