import SwiftUI
import Foundation
import AppKit

/// The dropdown that opens from the menu-bar icon: a list of sessions, attention
/// first. No masthead — identity, count, and actions live in the footer toolbar.
/// Status is the four-dot logo, alive: pulsing amber (needs you), steady green
/// (your turn), a gray highlight going around (working), or dim (idle).
struct MenuContent: View {
    @ObservedObject var store: SessionStore
    /// Mirror the footer so the mark sits on the right (orb mode, right edge).
    var markTrailing: Bool = false
    /// Shared with the orb so the footer mark and the orb's dot are one view
    /// that travels between them, rather than two marks swapping places.
    var markNamespace: Namespace.ID? = nil
    var onSettings: () -> Void = {}

    /// The row expanded into a full-height peek (takes over the menu).
    @State private var expandedID: String?

    /// Which row the pointer is over, and where across it. Held here (not in the
    /// row) so it survives the rebuild when a row expands.
    @State private var hoverRowID: String?
    @State private var hoverX: CGFloat = 0

    private func toggle(_ id: String) { expandedID = (expandedID == id) ? nil : id }

    /// One builder for both the list and the expanded takeover, so a row behaves
    /// identically either way.
    private func row(for session: Session, expanded: Bool) -> some View {
        SessionRow(
            session: session,
            commandOverride: store.pendingApproval(for: session)?.preview,
            isExpanded: expanded,
            hoverFraction: hoverRowID == session.id ? hoverX : nil,
            onHover: { fraction in
                if let fraction {
                    hoverRowID = session.id
                    hoverX = fraction
                } else if hoverRowID == session.id {
                    hoverRowID = nil
                }
            },
            onOpen: { FocusEngine.focus(session) },
            onToggle: { toggle(session.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 14)
            } else if let id = expandedID, let session = store.sessions.first(where: { $0.id == id }) {
                // Peek takeover: just this session, given the whole panel.
                row(for: session, expanded: true)
                if let pa = store.pendingApproval(for: session) {
                    ApprovalButtons(canAnswer: pa.canAnswer,
                                    onAllow: { answer(pa, .allow) },
                                    onDeny:  { answer(pa, .deny) },
                                    onJump:  { FocusEngine.focus(session) })
                }
                Divider().opacity(0.35)
                PeekView(session: session, onJump: { FocusEngine.focus(session) })
            } else {
                ForEach(store.sessions) { session in
                    VStack(alignment: .leading, spacing: 0) {
                        row(for: session, expanded: false)
                        if let pa = store.pendingApproval(for: session) {
                            ApprovalButtons(canAnswer: pa.canAnswer,
                                            onAllow: { answer(pa, .allow) },
                                            onDeny:  { answer(pa, .deny) },
                                            onJump:  { FocusEngine.focus(session) })
                        }
                    }
                    Divider().opacity(0.35)
                }
            }

            MenuFooter(attentionCount: store.attentionCount, totalCount: store.sessions.count,
                       markTrailing: markTrailing, markNamespace: markNamespace,
                       onSettings: onSettings)
        }
        .frame(width: 340)
        .padding(.top, 6)
    }

    private func answer(_ pa: PendingApproval, _ decision: ApprovalDecision) {
        AnswerInjector.answer(cwd: pa.cwd, harness: pa.harness, decision: decision)
        store.clearApproval(pa)
    }
}

// MARK: - Session row

/// One row, one click — what the click does follows the pointer. Out in the
/// body of the row it opens the session; as you reach the last quarter the row
/// hands over: the content recedes (dim + soft blur) and the chevron takes
/// focus, so the peek is clearly what you're about to hit. No visible split,
/// no small target. Right-click offers both actions outright.
struct SessionRow: View {
    let session: Session
    var commandOverride: String? = nil
    var isExpanded: Bool = false

    /// Pointer position across the row (0…1), or nil when it's elsewhere. Owned
    /// by the parent: expanding rebuilds this row, and local @State would reset
    /// to "not hovering" — so a second click without moving would open the
    /// session instead of collapsing the peek.
    var hoverFraction: CGFloat?
    var onHover: (CGFloat?) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onToggle: () -> Void = {}

    @State private var rowWidth: CGFloat = 0

    /// Past this fraction of the row, a click means "peek" rather than "open".
    private let handover: CGFloat = 0.75
    /// The blur is a gradient in space: none at `fadeStart`, ramping to full by
    /// `fadeFull` and staying there to the right edge. Reaching full well before
    /// the edge matters — ramping all the way to 100% would put peak blur on the
    /// trailing padding, where there's nothing to see.
    private let fadeStart: CGFloat = 0.45
    private let fadeFull: CGFloat = 0.70

    private var hovering: Bool { hoverFraction != nil }
    private var overExpand: Bool { (hoverFraction ?? -1) > handover }

    /// How far into the handover zone the pointer is, 0 at the 75% line rising
    /// to 1 at the right edge, eased so it's felt early rather than only at the
    /// very edge.
    private var progress: CGFloat {
        guard let x = hoverFraction else { return 0 }
        let raw = min(max((x - handover) / (1 - handover), 0), 1)
        return sqrt(raw)
    }

    var body: some View {
        recedingContent
            .overlay(alignment: .trailing) { chevron.padding(.trailing, 5) }
            .background(Color.primary.opacity(hovering && !overExpand ? 0.055 : 0))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { rowWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in rowWidth = w }
            })
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): onHover(rowWidth > 0 ? p.x / rowWidth : 0)
                case .ended:         onHover(nil)
                }
            }
            .onTapGesture { overExpand ? onToggle() : onOpen() }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contextMenu {
                Button("Open Session", action: onOpen)
                Button(isExpanded ? "Hide Recent Activity" : "Peek at Recent Activity", action: onToggle)
            }
    }

    /// The row, with its right end blurring out under the pointer. Two copies
    /// with complementary masks — sharp on the left, blurred on the right — so
    /// every pixel is one or the other. (Layering a blurred copy *over* the sharp
    /// one instead would just ghost it, which reads as muddy rather than blurred.)
    /// No dimming: this is a blur, and a scrim would only make it look faded.
    private var recedingContent: some View {
        ZStack(alignment: .leading) {
            content.mask(mask(sharp: true))
            content
                .blur(radius: 9 * progress)
                .mask(mask(sharp: false))
        }
    }

    /// Complementary left-to-right gradients: the sharp copy fades out across
    /// the transition, the blurred copy fades in over exactly the same span, and
    /// past `fadeFull` the blurred copy is all that remains.
    private func mask(sharp: Bool) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: sharp ? .black : .clear, location: fadeStart),
                .init(color: sharp ? .clear : .black, location: fadeFull),
                .init(color: sharp ? .clear : .black, location: 1.0),
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 11) {
            StatusDots(state: session.state)
                .frame(width: 15, height: 15)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.project)
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    lineTwo.lineLimit(1)
                    Spacer(minLength: 6)
                    Text(RelativeTime.short(session.updatedAt))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                    HarnessIcon(harness: session.harness)
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 34)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Comes forward as the row recedes, in step with the same progress value.
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10 + 2 * progress, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.3 + 0.65 * progress))
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(0.13 * progress)))
            .animation(.easeOut(duration: 0.18), value: isExpanded)
            .allowsHitTesting(false)   // the row owns the click; position decides
    }

    @ViewBuilder private var lineTwo: some View {
        if let cmd = commandOverride, !cmd.isEmpty {
            Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        } else {
            Text(session.lastLine.isEmpty ? session.state.label : session.lastLine)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status dots (the logo, alive)

struct StatusDots: View {
    let state: SessionState
    var body: some View {
        switch state {
        case .waitingPermission, .error: PulsingDots(color: RTColor.attention)
        case .waitingInput, .done:       DotGrid(color: RTColor.ready, opacities: [1, 1, 1, 1])
        case .working:                   TravelingDots()
        case .idle:                      DotGrid(color: RTColor.idle, opacities: [0.4, 0.4, 0.4, 0.4])
        }
    }
}

/// Four dots in a 2×2, each with its own opacity — the shared geometry.
private struct DotGrid: View {
    let color: Color
    let opacities: [Double]
    private let box: CGFloat = 12
    private let dot: CGFloat = 3.3

    var body: some View {
        let a = box * 0.28, b = box * 0.72
        let c = [CGPoint(x: a, y: a), CGPoint(x: b, y: a), CGPoint(x: a, y: b), CGPoint(x: b, y: b)]
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(color).frame(width: dot, height: dot)
                    .opacity(opacities[i]).position(c[i])
            }
        }
        .frame(width: box, height: box)
    }
}

/// Needs-permission: the whole table brightens and dims together, like a heartbeat.
private struct PulsingDots: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let o = 0.32 + 0.68 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.5))
            DotGrid(color: color, opacities: [o, o, o, o])
        }
    }
}

/// Working: a bright highlight travels clockwise around the four seats.
private struct TravelingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.375)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.375) % 4
            TravelFrame(step: step)
        }
    }
}

private struct TravelFrame: View {
    let step: Int
    private let order = [0, 1, 3, 2]   // clockwise: TL, TR, BR, BL
    var body: some View {
        let lit = order[step % 4]
        DotGrid(color: RTColor.busy, opacities: (0..<4).map { $0 == lit ? 1.0 : 0.22 })
            .animation(.easeInOut(duration: 0.28), value: step)
    }
}

// MARK: - Harness icon (right end of line 2)

/// The harness's real mark, identifying which tool the session belongs to. The
/// bundled logo loads in the packaged app; a drawn shape stands in under
/// `swift run` (no bundle) so the row never goes blank.
struct HarnessIcon: View {
    let harness: Harness
    var body: some View {
        Group {
            if let img = Self.logo(for: harness) {
                // Template = ignore the logo's own color, tint it gray to sit
                // quietly as metadata alongside the calm palette.
                Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                fallback.frame(width: 15, height: 15)
            }
        }
        .foregroundStyle(.primary.opacity(0.5))
    }

    private static func assetName(_ h: Harness) -> String {
        switch h {
        case .claudeCode: return "claude"
        case .codex:      return "codex"
        case .pi:         return "pi"
        case .ohMyPi:     return "omp"
        }
    }

    private static func logo(for h: Harness) -> NSImage? {
        guard let url = Bundle.main.url(forResource: assetName(h), withExtension: "png", subdirectory: "HarnessIcons")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    @ViewBuilder private var fallback: some View {
        switch harness {
        case .claudeCode: Sunburst(points: 10).frame(width: 12.5, height: 12.5)
        case .codex:      Image(systemName: "hexagon.fill").font(.system(size: 10.5))
        case .pi:         Text("π").font(.system(size: 12.5, weight: .semibold))
        case .ohMyPi:     Image(systemName: "diamond.fill").font(.system(size: 10.5))
        }
    }
}

/// A radial sunburst — a filled many-pointed star, standing in for Claude's mark.
struct Sunburst: Shape {
    var points: Int = 10
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.44
        let n = points * 2
        for i in 0..<n {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = (Double(i) / Double(n)) * 2 * .pi - .pi / 2
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Approval actions (command shows on the row's line 2)

struct ApprovalButtons: View {
    let canAnswer: Bool
    var onAllow: () -> Void
    var onDeny: () -> Void
    var onJump: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if canAnswer {
                Button("Allow", action: onAllow).buttonStyle(RTButton(kind: .primary))
                Button("Deny", action: onDeny).buttonStyle(RTButton(kind: .neutral))
            } else {
                Text("Answer in the terminal").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Jump", action: onJump).buttonStyle(RTButton(kind: .neutral))
        }
        .padding(.leading, 40).padding(.trailing, 14)
        .padding(.top, 1).padding(.bottom, 10)
    }
}

struct RTButton: ButtonStyle {
    enum Kind { case primary, neutral }
    let kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(bg(configuration.isPressed), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(kind == .primary ? Color(red: 0.02, green: 0.21, blue: 0.07) : .primary)
    }
    private func bg(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return RTColor.ready.opacity(pressed ? 0.82 : 1)
        case .neutral: return Color.white.opacity(pressed ? 0.16 : 0.09)
        }
    }
}

// MARK: - Footer toolbar

struct MenuFooter: View {
    let attentionCount: Int
    let totalCount: Int
    /// Put the mark on the right instead of the left. In orb mode the panel
    /// grows out of the dot, so the mark has to land on the orb's own side —
    /// it's the same object, settling into the corner it came from.
    var markTrailing: Bool = false
    var markNamespace: Namespace.ID? = nil
    var onSettings: () -> Void

    @ObservedObject private var updater = UpdateController.shared

    var body: some View {
        ZStack {
            count
            HStack {
                // The update button rides beside the mark rather than with the
                // gear and power. Those two are always there and always the
                // same; this appears only when there is something to do, and
                // the mark's side is the side the orb itself came from.
                if markTrailing {
                    tools; Spacer(); updateButton; mark
                } else {
                    mark; updateButton; Spacer(); tools
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: updater.state)
    }

    /// The same mark the orb draws, at the same size, so when the orb opens it
    /// is this exact view arriving in the corner — not a second logo appearing
    /// beside where the first one was.
    private var mark: some View {
        DotMark(color: Color.primary.opacity(0.38), opacities: [1, 1, 1, 1])
            .modifier(MatchedMark(namespace: markNamespace))
            // Nudge to the orb dot's own inset (9 from the side, 17 from the
            // bottom) so the arrival is a settle, not a jump.
            .offset(x: markTrailing ? 4 : -4, y: -1.5)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            toolButton("gearshape", action: onSettings)
            toolButton("power", action: { NSApplication.shared.terminate(nil) })
        }
    }

    /// Present only when there is something to say. An update control that is
    /// always visible and usually greyed out is noise in a footer this small.
    @ViewBuilder private var updateButton: some View {
        switch updater.state {
        case .available(let release):
            pill("arrow.down.circle.fill", "Update", tint: RTColor.attention) {
                updater.install()
            }
            .help("Version \(release.version) is available. You have \(updater.currentVersion).")

        case .downloading(let fraction):
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).frame(height: 20)
            .transition(.opacity)

        case .readyToRelaunch:
            pill("arrow.clockwise", "Restart", tint: RTColor.ready) {
                updater.relaunch()
            }
            .help("The update is installed. Restart to use it.")

        case .failed(let message):
            pill("exclamationmark.triangle.fill", "Retry", tint: .secondary) {
                Task { await updater.check() }
            }
            .help(message)

        case .idle, .checking:
            EmptyView()
        }
    }

    private func pill(_ symbol: String, _ label: String, tint: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    @ViewBuilder private var count: some View {
        if attentionCount > 0 {
            (Text("\(attentionCount)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundColor(.primary)
             + Text(" waiting").font(.system(size: 11.5)).foregroundColor(.secondary))
        } else {
            Text(totalCount == 0 ? "No sessions" : "All clear")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func toolButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Peek (unchanged)

/// Full-height peek: the session's recent activity, shown plainly so you can
/// triage without switching. Sizes to its content up to a cap, pins to newest.
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
                Button("Jump", action: onJump).buttonStyle(RTButton(kind: .neutral))
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

/// Applies `matchedGeometryEffect` only when a namespace is supplied, so the
/// same footer works inside the orb (where the mark travels) and in the menu
/// bar (where there is nothing to travel from).
struct MatchedMark: ViewModifier {
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "rt.mark", in: namespace)
        } else {
            content
        }
    }
}
