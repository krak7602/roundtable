import AppKit
import SwiftUI
import Combine

/// The floating orb: a draggable glass dot that lives on the desktop instead of
/// in the menu bar. It rests dim and half-tucked against a screen edge, comes
/// forward on hover, grows sideways into a pill when a session needs you, and
/// opens into the full session list in place. Alternative to MenuBarController,
/// chosen in Settings.
///
/// It accepts mouse events (drag, click) while still drawing over another app's
/// full-screen space — verified on-device, and the thing the whole design rests
/// on. One fixed-size panel holds every state: the dot sits in the bottom corner
/// on its own side and the list grows upward out of it, so the orb *becomes* the
/// panel rather than spawning a detached popover that points back at itself.
/// Fixed size also keeps us clear of the re-entrant AppKit crashes that resizing
/// a hosting view caused in the toast panel.
@MainActor
final class OrbController {
    private let store: SessionStore
    private let panel: NSPanel
    private let model = OrbModel()
    private let drag = OrbDragView()
    private var cancellables: Set<AnyCancellable> = []
    private var collapseTimer: Timer?
    private var moveTimer: Timer?
    private var outsideClickMonitor: Any?
    private var hoverMonitor: Any?
    /// Where to put the panel back after it stepped down to fit the list.
    private var restoreY: CGFloat?

    private let panelSize = NSSize(width: 432, height: 590)
    private let dotSize: CGFloat = 34
    /// The gap the shell keeps from the screen edge it is snapped to.
    private let edgeInset: CGFloat = 6
    /// Transparent room reserved on every side purely so shadows can finish
    /// falling off. A transparent panel clips just as hard as an opaque one, so
    /// anything drawn past its bounds is sliced mid-gradient — which is exactly
    /// what a dragged orb showed on whichever side happened to be over open
    /// desktop. Sized for the widest shadow any state casts: the open list at
    /// radius 22 offset 8, and a lifted orb at radius 20 offset 10.
    ///
    /// The panel is hung this far *past* the screen edge to pay for it, so the
    /// margin costs nothing on screen and the tuck geometry is untouched.
    private let shadowMargin: CGFloat = 30
    /// Panel edge to shell edge. Both axes, since a dragged orb is nowhere near
    /// a screen edge and clips the same way in every direction.
    private var dotInset: CGFloat { edgeInset + shadowMargin }
    private var dotBottomInset: CGFloat { edgeInset + shadowMargin }

    /// Opening Settings is the app's job, not the orb's.
    var onSettings: (() -> Void)?
    /// How long an attention pill stays out before it tucks back.
    private let pillDuration: TimeInterval = 4.5

    init(store: SessionStore) {
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        // Starts click-through and is armed only while the cursor is actually
        // over the orb — see armForCursor(). The panel is far bigger than what
        // it draws, so anything else swallows clicks meant for the app beneath.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Pin to dark: the orb floats over whatever the user is doing, so its
        // material must not follow the system theme (light mode would render the
        // list's text dark on a dark HUD) and SwiftUI's semantic colours inside
        // it need to resolve for a dark surface.
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = FirstMouseHostingView(rootView: OrbView(model: model, store: store, onSettings: { [weak self] in
            self?.closeList()
            self?.onSettings?()
        }))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        drag.frame = NSRect(origin: .zero, size: panelSize)
        drag.addSubview(host)
        panel.contentView = drag

        drag.onClick = { [weak self] in self?.toggleList() }
        drag.onDragChanged = { [weak self] dragging in self?.model.dragging = dragging }
        drag.onDragEnded = { [weak self] in self?.snapToEdge(animated: true) }

        // Steady state (the count, the amber tint) follows the list.
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.apply(sessions) }
            .store(in: &cancellables)

        // News (the pill, the sound) comes from the store's attention ledger.
        store.announcements
            .receive(on: RunLoop.main)
            .sink { [weak self] announcement in self?.announce(announcement) }
            .store(in: &cancellables)

        // Keep the clickable area in step with what's actually drawn.
        model.$pillWidth
            .combineLatest(model.$expanded, model.$edge, model.$listOpen)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateHitArea() }
            .store(in: &cancellables)
        model.$listSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHitArea() }
            .store(in: &cancellables)
    }

    func show() {
        restorePosition()
        panel.orderFrontRegardless()
        watchForCursor()
    }

    func hide() {
        closeList()
        stopWatchingCursor()
        disarm()
        panel.orderOut(nil)
    }

    // MARK: - Click-through
    //
    // The panel is a fixed 432×590 sheet holding a 34pt dot, so almost all of it
    // is empty. `ignoresMouseEvents` is the only thing the window server checks
    // when deciding whether a click belongs to us, and it is all-or-nothing for
    // the whole window — a view returning nil from hitTest is far too late, the
    // event has already been routed here and dies rather than falling through.
    //
    // So the window is click-through by default and armed only while the cursor
    // is genuinely over the orb, decided by a global mouse-moved monitor. That
    // monitor sees the cursor whether or not the panel is armed — verified on
    // device — so it drives both arming and the hover ring, and there is no
    // second mechanism to disagree with it. Mouse monitors need no Accessibility
    // permission; only keyboard ones do.

    private func watchForCursor() {
        stopWatchingCursor()
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.armForCursor() }
        }
        armForCursor()
    }

    private func stopWatchingCursor() {
        if let monitor = hoverMonitor { NSEvent.removeMonitor(monitor) }
        hoverMonitor = nil
    }

    /// How far the orb notices the cursor, as a share of the screen's width.
    /// Expressed as a fraction rather than points because it is meant to feel the
    /// same on a laptop and a 27-inch display — a fixed reach that is inviting on
    /// one is a bullseye on the other.
    private let hoverReachFraction: CGFloat = 0.12

    private var hoverRadius: CGFloat {
        let width = screenFor(panel.frame.origin)?.frame.width ?? 1440
        return width * hoverReachFraction
    }

    /// Runs on every cursor movement and decides two separate things.
    ///
    /// Hover is a *ring*: the orb comes forward once the cursor is within reach
    /// from any direction, which is why this is a distance test and not a
    /// tracking area — those are rectangular, and a rectangle large enough to
    /// feel right at the sides reaches absurdly far diagonally.
    ///
    /// Arming is a rect, and stays tight to what is drawn. The two must not be
    /// conflated: the ring is only a lighting cue, while arming decides whether
    /// this window swallows a click that belonged to the app underneath.
    private func armForCursor() {
        guard panel.isVisible, !model.dragging, !model.listOpen else { return }
        let mouse = NSEvent.mouseLocation

        let clickable = interactiveScreenRect
        let onOrb = clickable?.contains(mouse) ?? false
        panel.ignoresMouseEvents = !onOrb

        var near = false
        if !drag.hitRect.isEmpty {
            let centre = NSPoint(x: panel.frame.minX + drag.hitRect.midX,
                                 y: panel.frame.minY + drag.hitRect.midY)
            near = hypot(mouse.x - centre.x, mouse.y - centre.y) <= hoverRadius
        }

        if model.hovering != near {
            model.hovering = near
            if near { model.pulsing = false }
        }
    }

    /// Back to click-through. Never while the list is open or a drag is running:
    /// both need to keep receiving events wherever the cursor wanders.
    private func disarm() {
        guard !model.dragging, !model.listOpen else { return }
        panel.ignoresMouseEvents = true
    }

    /// What the orb currently occupies, in screen coordinates.
    private var interactiveScreenRect: NSRect? {
        let local: NSRect
        if !drag.listRect.isEmpty {
            local = drag.listRect
        } else if !drag.hitRect.isEmpty {
            // At rest the dot is drawn shifted out past the screen edge, and it
            // slides back in on hover. Cover both positions, or the cursor lands
            // on a dot that is 11.5pt from where we think it is.
            local = drag.hitRect
                .union(drag.hitRect.offsetBy(dx: model.edge == .right ? orbTuck : -orbTuck, dy: 0))
                .insetBy(dx: -2, dy: -2)
        } else {
            return nil
        }
        return local.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    var isVisible: Bool { panel.isVisible }
    var isListOpen: Bool { model.listOpen }

    // MARK: - The list

    /// The orb opens into the list in place. The dot settles into the footer
    /// corner on its own side, so it reads as the same object unfolding.
    func toggleList() {
        guard panel.isVisible else { return }
        model.pulsing = false
        model.listOpen ? closeList() : openList()
    }

    private func openList() {
        model.expanded = false          // a pill and the list shouldn't overlap
        model.listOpen = true
        panel.ignoresMouseEvents = false   // the whole list has to stay clickable
        keepListOnScreen()
        watchForOutsideClick()
    }

    private func closeList() {
        guard model.listOpen else { return }
        model.listOpen = false
        stopWatchingOutsideClick()
        // Back to a dot: click-through again unless the cursor is still on it.
        disarm()
        armForCursor()
        if let y = restoreY {
            restoreY = nil
            glide(to: NSPoint(x: panel.frame.origin.x, y: y), save: false)
        }
    }

    /// The list grows upward from the dot, so an orb parked near the top of the
    /// screen would run off it. Step the panel down just enough to fit, and
    /// remember where it was so closing puts it back.
    private func keepListOnScreen() {
        guard let screen = screenFor(panel.frame.origin) else { return }
        let overflow = panel.frame.maxY - screen.visibleFrame.maxY
        guard overflow > 0 else { return }
        restoreY = panel.frame.origin.y
        glide(to: NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y - overflow), save: false)
    }

    /// Click anywhere else and the list closes, the way a menu would. The panel
    /// is click-through outside its content, so the click itself still lands on
    /// whatever is underneath.
    private func watchForOutsideClick() {
        stopWatchingOutsideClick()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard !self.listContains(p) else { return }
                self.closeList()
            }
        }
    }

    /// A global monitor is meant to skip our own clicks, but this panel is
    /// non-activating inside an accessory app: clicking it never makes us the
    /// active app, so the monitor sees those clicks too. Without this check,
    /// every click *inside* the list read as a click away from it — collapsing
    /// the whole orb when you were only toggling a row.
    private func listContains(_ point: NSPoint) -> Bool {
        guard model.listOpen, !drag.listRect.isEmpty else { return false }
        let onScreen = NSRect(x: panel.frame.minX + drag.listRect.minX,
                              y: panel.frame.minY + drag.listRect.minY,
                              width: drag.listRect.width,
                              height: drag.listRect.height)
        return onScreen.contains(point)
    }

    private func stopWatchingOutsideClick() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Attention

    /// Keeps the steady indicators (count, amber) in step with the list. What
    /// deserves a pill and a sound is not decided here — the store's attention
    /// ledger does that, so a reorder of the waiting list or a prompt overlay
    /// flickering underneath can never re-alert on its own.
    private func apply(_ sessions: [Session]) {
        model.attention = sessions.filter(\.needsAttention).count
        if model.attention == 0 { model.pulsing = false }
    }

    /// Something genuinely new. One pill, one sound, however many sessions it
    /// covers.
    private func announce(_ announcement: AttentionAnnouncement) {
        DebugLog.log("orb", "got \(announcement.sessions.count); mode=\(AppSettings.shared.presentation.rawValue) listOpen=\(model.listOpen) visible=\(panel.isVisible)")
        guard AppSettings.shared.presentation == .orb else { return }
        guard !model.listOpen else { return }   // already looking at it
        playSound(permission: announcement.isPermission)
        guard panel.isVisible else { return }   // hidden orb still gets the sound
        expand(message: announcement.message)
    }

    /// The orb owns its own alert sound: in orb mode the menu-bar toast path is
    /// switched off, and the sound used to live there.
    private func playSound(permission: Bool) {
        guard AppSettings.shared.soundEnabled else { return }
        let name = permission ? AppSettings.shared.permissionSound
                              : AppSettings.shared.waitingSound
        NSSound(named: name)?.play()
    }

    /// Grow out of the dot into a pill, then tuck back on a timer. The pulse is
    /// for *news*: it stops when the pill tucks back (or the moment the user
    /// looks at the orb), leaving a steady amber mark to say something is still
    /// waiting. Blinking until the user acts would just be nagging.
    private func expand(message: String, sticky: Bool = false) {
        model.message = message
        model.expanded = true
        model.pulsing = true
        collapseTimer?.invalidate()
        guard !sticky else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: pillDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.expanded = false
                self?.model.pulsing = false
            }
        }
    }

    /// Only what's actually drawn takes clicks; everything else in the panel
    /// stays click-through so the app underneath keeps working.
    private func updateHitArea() {
        if model.listOpen, model.listSize.width > 1 {
            let size = model.listSize
            let x = model.edge == .right ? panelSize.width - size.width - dotInset : dotInset
            drag.listRect = NSRect(x: x, y: dotBottomInset, width: size.width, height: size.height)
            drag.hitRect = .zero
        } else {
            drag.listRect = .zero
            let width = model.expanded ? max(model.pillWidth, dotSize) : dotSize
            let x = model.edge == .right ? panelSize.width - width - dotInset : dotInset
            drag.hitRect = NSRect(x: x, y: dotBottomInset, width: width, height: dotSize)
        }
    }


    // MARK: - Position
    //
    // The panel is much taller than the dot (it has to hold the list), and the
    // dot lives in the bottom corner. So everything positional is expressed in
    // terms of where the *dot* ends up, not the panel.

    private var dotCenterX: CGFloat {
        model.edge == .right ? panel.frame.maxX - dotInset - dotSize / 2
                             : panel.frame.minX + dotInset + dotSize / 2
    }

    private func restorePosition() {
        let d = UserDefaults.standard
        // Keys are versioned: the panel's geometry has changed twice (the dot
        // moving to the bottom corner, then the bottom gaining room for the
        // shadow), and an old saved origin would land the dot somewhere odd.
        if let x = d.object(forKey: "orbX4") as? Double, let y = d.object(forKey: "orbY4") as? Double {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panelSize.width + shadowMargin,
                                         y: f.midY - panelSize.height / 2))
        }
        snapToEdge(animated: false)
    }

    private func savePosition() {
        let o = panel.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "orbX4")
        UserDefaults.standard.set(Double(o.y), forKey: "orbY4")
    }

    /// Drop it and it plops back against whichever side of the screen it's on,
    /// so the dot stops floating in the middle of the user's work.
    private func snapToEdge(animated: Bool) {
        guard let screen = screenFor(panel.frame.origin) else { return }
        let f = screen.visibleFrame
        let toLeft = dotCenterX < f.midX
        let newEdge: OrbEdge = toLeft ? .left : .right

        // Changing sides moves the dot to the other end of the panel. Shift the
        // panel by the same distance first, so the dot doesn't visibly jump the
        // width of the panel before the snap animation even starts.
        if newEdge != model.edge {
            let shift = panelSize.width - dotSize - 2 * dotInset
            var origin = panel.frame.origin
            origin.x += (newEdge == .left) ? shift : -shift
            panel.setFrameOrigin(origin)
            model.edge = newEdge
        }

        let x = toLeft ? f.minX - shadowMargin : f.maxX - panelSize.width + shadowMargin
        // Clamp on the dot, not the panel: the panel towers above the dot and
        // forcing all of it on screen would drag the orb down to the bottom.
        let minY = f.minY - dotBottomInset
        let maxY = f.maxY - dotBottomInset - dotSize
        let y = min(max(panel.frame.origin.y, minY), maxY)
        let target = NSPoint(x: x, y: y)

        if animated {
            glide(to: target)
        } else {
            panel.setFrameOrigin(target)
            savePosition()
        }
    }

    /// Move the panel over time by stepping the frame ourselves.
    ///
    /// `panel.animator().setFrameOrigin(_:)` silently does nothing for this
    /// window (borderless, non-activating, screen-saver level) — verified: the
    /// same target applied instantly via `setFrameOrigin` moves it, while the
    /// animator leaves it untouched.
    private func glide(to target: NSPoint, save: Bool = true) {
        moveTimer?.invalidate()
        let start = panel.frame.origin
        guard hypot(target.x - start.x, target.y - start.y) > 0.5 else {
            panel.setFrameOrigin(target)
            if save { savePosition() }
            return
        }
        let steps = 15
        var step = 0
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                step += 1
                let p = min(1.0, Double(step) / Double(steps))
                let eased = 1 - pow(1 - p, 3)          // easeOutCubic
                self.panel.setFrameOrigin(NSPoint(
                    x: start.x + (target.x - start.x) * eased,
                    y: start.y + (target.y - start.y) * eased))
                if p >= 1 {
                    self.moveTimer?.invalidate()
                    if save { self.savePosition() }
                }
            }
        }
    }

    private func screenFor(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: point.x + panelSize.width / 2,
                                                           y: point.y + dotBottomInset + dotSize / 2)) }
            ?? NSScreen.main
    }

    deinit { }
}

/// SwiftUI in a panel that never becomes key.
///
/// This panel is borderless and non-activating, so it is never the key window
/// and every click into it counts as a "first mouse" click. `NSHostingView`
/// declines those by default, so taps never reached SwiftUI at all: hover worked
/// (tracking areas don't need key status), but buttons and tap gestures were
/// dead, and the clicks fell through to the drag view underneath instead.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Drag / hit handling

/// Accepts hits only where the orb is actually drawn, so the rest of the panel
/// stays click-through and never takes a click from the app underneath. The dot
/// is ours (drag and click); the list is SwiftUI's, so hits there are passed to
/// the hosting view instead of swallowed here.
final class OrbDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onClick: (() -> Void)?
    /// Fires once when a press turns into a real drag, and again on release.
    var onDragChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?

    /// The dot/pill, in panel coordinates. Handled by this view.
    var hitRect: NSRect = .zero
    /// The open list, in panel coordinates. Handed to SwiftUI.
    var listRect: NSRect = .zero

    /// True while a click that belongs to the list is in flight. SwiftUI doesn't
    /// consume clicks it handles, so AppKit walks them up the responder chain to
    /// this view — without this, every click in the list also read as a click on
    /// the orb and collapsed the whole thing.
    private var ignoringClick = false
    private var grabOffset: NSPoint?
    /// Where the window started, so movement is measured across the whole
    /// gesture. Comparing against the window's *current* origin never works: the
    /// window is moved to follow the mouse on every event, so each step's
    /// difference is ~0 and a slow drag would read as a click.
    private var startOrigin: NSPoint?
    private var didMove = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !listRect.isEmpty, listRect.contains(point) { return super.hitTest(point) }
        return hitRect.insetBy(dx: -2, dy: -2).contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if !listRect.isEmpty, listRect.contains(event.locationInWindow) {
            ignoringClick = true       // the list's click, not the orb's
            return
        }
        ignoringClick = false
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: mouse.x - window.frame.origin.x, y: mouse.y - window.frame.origin.y)
        startOrigin = window.frame.origin
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoringClick, let window, let offset = grabOffset else { return }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)
        if let start = startOrigin, hypot(origin.x - start.x, origin.y - start.y) > 3, !didMove {
            didMove = true
            onDragChanged?(true)       // it's a drag, not a click: let it lift
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { ignoringClick = false }
        guard !ignoringClick else { return }
        grabOffset = nil
        startOrigin = nil
        if didMove { onDragChanged?(false) }
        didMove ? onDragEnded?() : onClick?()
    }

}

// MARK: - View

enum OrbEdge { case left, right }

/// How far the dot hides past the screen edge at rest. Bounded by the ring of
/// empty space around the mark inside the circle (a 15pt mark in a 34pt dot
/// leaves ~9.5pt each side): tuck deeper and the screen edge slices through the
/// outer column of dots, which reads as broken, not tucked.
///
/// Shared, because the panel has to know where the dot ended up in order to take
/// clicks there.
let orbTuck: CGFloat = 11.5

@MainActor
final class OrbModel: ObservableObject {
    @Published var hovering = false
    @Published var attention = 0
    @Published var edge: OrbEdge = .right
    @Published var expanded = false          // the attention pill
    @Published var listOpen = false          // the full session list
    /// True while the user is carrying the orb around, so it can lift off the
    /// desktop instead of sliding along it.
    @Published var dragging = false
    /// Blinking is reserved for news. Steady amber means "still waiting".
    @Published var pulsing = false
    @Published var message = ""
    /// Measured sizes of what's drawn, so the clickable area can match.
    @Published var pillWidth: CGFloat = 34
    @Published var listSize: CGSize = .zero
}

/// Everything the orb can be, in one panel: the dot, the pill it grows into
/// when something needs you, and the full list it opens into. All anchored to
/// the bottom corner on the orb's own side, so each state unfolds from the last.
struct OrbView: View {
    @ObservedObject var model: OrbModel
    @ObservedObject var store: SessionStore
    var onSettings: () -> Void

    @State private var wasListOpen = false
    /// Ties the orb's dot to the footer's mark: one view, two positions.
    @Namespace private var markNS

    private var needsYou: Bool { model.attention > 0 }
    private var resting: Bool { !model.hovering && !model.expanded && !model.listOpen }
    private var onRight: Bool { model.edge == .right }
    private var corner: Alignment { onRight ? .bottomTrailing : .bottomLeading }

    private var tuck: CGFloat { orbTuck }

    var body: some View {
        ZStack(alignment: corner) {
            Color.clear
            shell
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
        // Room for the shadow on every side but the top, which has the rest of
        // the panel above it anyway. Must match edgeInset + shadowMargin, or the
        // dot lands somewhere other than where the panel takes clicks.
        .padding(.horizontal, 36)
        .padding(.top, 6)
        .padding(.bottom, 36)
    }

    /// One piece of glass for every state. The shell itself never gets replaced:
    /// it grows from dot to pill to list, with its corner radius easing from a
    /// capsule to a panel, and only the *contents* crossfade inside it. Swapping
    /// whole views instead (the obvious way) reads as the orb being replaced by
    /// something else, rather than the orb opening up.
    private var shell: some View {
        // The ZStack is the shell, and it is always present — that stable
        // identity is the whole point. Hanging these modifiers off the `if/else`
        // instead makes the container itself change identity when the state
        // flips, so SwiftUI rebuilds it rather than resizing it: no from-value,
        // no interpolation, and what you see is one view replaced by another.
        ZStack(alignment: corner) {
            Color.clear
            inner.fixedSize()                               // keep natural size…
        }
            .frame(width: size.width, height: size.height, alignment: corner)
            // Glass alone is not enough: over a bright backdrop the material
            // washes out and white text stops being readable. The scrim gives a
            // floor of contrast while still letting the blur show through.
            .background {
                ZStack {
                    VisualEffectBackground(material: .hudWindow)
                    Color.black.opacity(0.34)
                }
            }
            .overlay(shape.fill(RTColor.attention.opacity(!model.listOpen && needsYou ? 0.16 : 0)))
            .clipShape(shape)                               // …and reveal it as the shell grows
            .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .scaleEffect(model.dragging ? 1.06 : 1)
            .shadow(color: .black.opacity(lift.opacity), radius: lift.radius, y: lift.offset)
            // Half-tucked past the edge at rest; pulls fully into view otherwise.
            .offset(x: resting ? (onRight ? tuck : -tuck) : 0)
            .opacity(resting ? (needsYou ? 0.78 : 0.5) : 1)
            .animation(sizeAnimation, value: size)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: resting)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: model.dragging)
            .onChange(of: model.listOpen) { _, open in
                // Keep the slower curve for the closing animation too.
                wasListOpen = true
                if !open {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { wasListOpen = false }
                }
            }
    }

    /// The list is something you summon to *check* something, so the motion has
    /// to get out of the way: short, decelerating, and quicker to leave than to
    /// arrive (the decision to dismiss is already made).
    ///
    /// Duration-based springs, not `.spring(response:)` — `response` is the
    /// spring's natural period, not its settle time, so a "0.3" spring visibly
    /// runs much longer than 300ms. That mismatch is why this kept feeling slow
    /// however far the number came down. `.smooth` is critically damped, so the
    /// duration given is the duration seen, and being a spring it retargets
    /// cleanly if the orb is toggled again mid-flight.
    private var sizeAnimation: Animation {
        if model.listOpen { return .smooth(duration: 0.20) }   // opening
        if wasListOpen { return .smooth(duration: 0.14) }      // closing, quicker
        return .spring(response: 0.42, dampingFraction: 0.82)  // the pill, unchanged
    }

    /// How high off the desktop the shell is sitting. Picking the orb up throws
    /// the shadow wider and further down, and thins it out: a light source stays
    /// put while the object rises, so its shadow spreads and softens rather than
    /// darkening. Keeping the resting density here would read as the orb being
    /// pressed into the screen instead of lifted off it.
    private var lift: (radius: CGFloat, offset: CGFloat, opacity: Double) {
        if model.dragging { return (20, 10, 0.32) }
        if model.listOpen { return (22, 8, 0.45) }
        return (10, 4, 0.4)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: model.listOpen ? 14 : 17, style: .continuous)
    }

    /// What the shell grows to. The list's height is whatever MenuContent needs,
    /// measured as it renders. Before the first measurement we estimate from the
    /// session count rather than guessing a constant: a wrong guess corrects
    /// itself a frame later, and that second jump is what makes the first open
    /// look abrupt.
    private var size: CGSize {
        if model.listOpen {
            if model.listSize.width > 1 { return model.listSize }
            let rows = max(store.sessions.count, 1)
            return CGSize(width: 340, height: 6 + CGFloat(rows) * 56 + 37)
        }
        return CGSize(width: max(model.pillWidth, 34), height: 34)
    }

    @ViewBuilder private var inner: some View {
        if model.listOpen {
            MenuContent(store: store, markTrailing: onRight, markNamespace: markNS,
                        onSettings: onSettings)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { model.listSize = g.size }
                        .onChange(of: g.size) { _, s in model.listSize = s }
                })
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
        } else {
            pillContent.transition(.opacity.animation(.easeOut(duration: 0.10)))
        }
    }

    private var pillContent: some View {
        HStack(spacing: 9) {
            if !onRight { mark }
            if model.expanded {
                Text(model.message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: onRight ? .trailing : .leading)))
            }
            if onRight { mark }
        }
        .padding(.horizontal, model.expanded ? 14 : 9)
        .frame(height: 34)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.pillWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in model.pillWidth = w }
        })
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.expanded)
    }

    /// Matched with the footer's mark, so opening the list moves *this* mark
    /// into the corner instead of fading it out while another fades in.
    private var mark: some View {
        markGlyph.matchedGeometryEffect(id: "rt.mark", in: markNS)
    }

    @ViewBuilder private var markGlyph: some View {
        if model.pulsing {
            PulsingMark(color: RTColor.attention)                        // news
        } else if needsYou {
            DotMark(color: RTColor.attention, opacities: [1, 1, 1, 1])   // still waiting
        } else {
            DotMark(color: .white.opacity(0.85), opacities: [1, 1, 1, 1])
        }
    }
}

/// The four-dot mark, sized for the orb.
struct DotMark: View {
    let color: Color
    let opacities: [Double]
    private let box: CGFloat = 15
    private let dot: CGFloat = 4.4

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

private struct PulsingMark: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let o = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.5))
            DotMark(color: color, opacities: [o, o, o, o])
        }
    }
}
