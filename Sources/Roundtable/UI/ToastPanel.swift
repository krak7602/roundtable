import AppKit
import SwiftUI

/// One floating toast window bound to a single screen. Fixed-size, transparent,
/// click-through; the pill centers and springs inside it. (Fixed size matters:
/// resizing the hosting view per toast triggers a re-entrant AppKit constraint
/// crash when a second toast lands mid-animation.)
@MainActor
final class ToastPanelWindow {
    static let exitDuration: TimeInterval = 0.42

    private let panel: NSPanel
    private let model = ToastPillModel()
    private let host: NSHostingView<ToastPill>
    private var showGeneration = 0
    private let panelSize = NSSize(width: 520, height: 120)

    init() {
        host = NSHostingView(rootView: ToastPill(model: model))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func show(text: String, accent: ToastAccent, on screen: NSScreen) {
        showGeneration += 1
        let gen = showGeneration
        model.text = text
        model.accent = accent
        reposition(on: screen)
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.shown = false
        // Guard by generation: a retract/close before this runs must win, or the
        // pill would spring back visible after the user dismissed it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showGeneration == gen else { return }
            self.model.shown = true
        }
    }

    func retract() {
        showGeneration += 1   // cancel any pending show that would set shown=true
        model.shown = false
    }

    func close() {
        showGeneration += 1
        model.shown = false
        guard panel.isVisible else { return }
        let gen = showGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration) { [weak self] in
            guard let self, self.showGeneration == gen else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reposition(on screen: NSScreen) {
        let f = screen.frame
        // Clear the top inset: the menu bar when it's visible, and always the
        // notch (safeAreaInsets.top) so the pill isn't clipped on notched
        // displays even in full-screen, where the menu bar is hidden but the
        // notch remains.
        let topInset = max(max(0, f.maxY - screen.visibleFrame.maxY), screen.safeAreaInsets.top)
        let x = f.midX - panelSize.width / 2
        let y = f.maxY - topInset - panelSize.height
        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: false)
    }
}

/// Manages one ToastPanelWindow per screen, so a toast can appear on the focused
/// screen or on every screen at once. Windows are reused across toasts.
@MainActor
final class ToastPanelController {
    static let exitDuration = ToastPanelWindow.exitDuration

    private var windows: [CGDirectDisplayID: ToastPanelWindow] = [:]

    init() {
        // Drop panels for displays that get unplugged, so they don't leak.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneDisconnected() }
        }
    }

    private func pruneDisconnected() {
        let live = Set(NSScreen.screens.map(\.displayID))
        for (id, window) in windows where !live.contains(id) {
            window.close()
            windows[id] = nil
        }
    }

    func show(text: String, accent: ToastAccent, on screens: [NSScreen]) {
        let targets = Set(screens.map(\.displayID))
        for (id, window) in windows where !targets.contains(id) { window.close() }
        for screen in screens {
            let window = windows[screen.displayID] ?? {
                let w = ToastPanelWindow(); windows[screen.displayID] = w; return w
            }()
            window.show(text: text, accent: accent, on: screen)
        }
    }

    func retract() { windows.values.forEach { $0.retract() } }
    func close() { windows.values.forEach { $0.close() } }
}

enum ToastAccent {
    case amber, red
    /// Accent color for the icon + faint state wash over the native material.
    var color: Color {
        switch self {
        case .amber: return Color(red: 1.0, green: 0.60, blue: 0.05)
        case .red:   return Color(red: 0.93, green: 0.24, blue: 0.20)
        }
    }
}

final class ToastPillModel: ObservableObject {
    @Published var text = ""
    @Published var accent: ToastAccent = .amber
    @Published var shown = false
}

struct ToastPill: View {
    @ObservedObject var model: ToastPillModel

    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(model.accent.color)
            Text(model.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 20)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .modifier(GlassPill(accent: model.accent))
        .scaleEffect(model.shown ? 1 : 0.8, anchor: .top)
        .offset(y: model.shown ? 0 : -14)
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: model.shown)
    }

    var body: some View {
        VStack {
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
    }
}

/// The real native material: NSVisualEffectView (behind-window blending) that
/// blurs whatever is behind the panel, including a full-screen app.
private struct GlassPill: ViewModifier {
    let accent: ToastAccent
    private let radius: CGFloat = 19

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBackground(material: .hudWindow)
                    accent.color.opacity(0.16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
