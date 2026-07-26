import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar presence: a custom status item that both shows the session
/// list (clicking it opens a popover) and surfaces transient, in-place attention toasts
/// (the item expands with a gradient + one line + a soft sound). Toasts queue so
/// a burst is shown one at a time rather than colliding.
@MainActor
final class MenuBarController: NSObject {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let toastView: ToastStatusView
    private let popover = NSPopover()
    private let toastPanel = ToastPanelController()
    private var cancellables: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?

    private var queue: [ToastStatusView.Toast] = []
    private var currentToast: ToastStatusView.Toast?
    private var showingToast = false
    private var hideTimer: Timer?
    private var gapTimer: Timer?
    private var hoverOpenTimer: Timer?
    private var hoverCloseTimer: Timer?
    /// Only a hover-opened menu closes itself on hover-out; a clicked one stays
    /// until you dismiss it, as before.
    private var openedByHover = false
    private var lengthTimer: Timer?
    private var lengthAnimStep = 0

    private let idleLength: CGFloat = 34
    private let toastDuration: TimeInterval = 3.5

    init(store: SessionStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: idleLength)
        toastView = ToastStatusView(frame: NSRect(x: 0, y: 0, width: idleLength, height: 22))
        super.init()
        configure()
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = nil
            toastView.frame = button.bounds
            toastView.autoresizingMask = [.width, .height]
            button.addSubview(toastView)
        }
        toastView.onClick = { [weak self] in self?.handleStatusClick() }
        toastView.onHover = { [weak self] inside in self?.handleHover(inside) }

        // Clicking a floating (over-full-screen) toast jumps to that session too.
        toastPanel.onFocus = { [weak self] cwd, name in
            FocusEngine.focus(cwd: cwd, name: name)
            self?.dismissToast()
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuContent(store: store, onSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            }))

        store.onAttentionEdge = { [weak self] session in self?.enqueue(session) }

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.toastView.setAttentionCount(sessions.filter(\.needsAttention).count)
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleTestToast(_:)),
            name: Self.testToastName, object: nil)

        // Claude Code hook events (permission prompts / turn end) forwarded by
        // `Roundtable --hook`. Catches what transcript-tailing can't see.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleHook(_:)),
            name: Self.hookEventName, object: nil)
    }

    /// In orb mode the status item disappears and alerts come from the orb, so
    /// this controller stops presenting entirely.
    func setActive(_ active: Bool) {
        statusItem.isVisible = active
        if !active {
            popover.performClose(nil)
            dismissToast()
            queue.removeAll()
        }
    }

    private var isActive: Bool { AppSettings.shared.presentation == .menuBar }

    // MARK: - Popover

    /// A click on the menu-bar item: while an attention toast is up, it's a call
    /// to action, so jump to that session; otherwise just open the list.
    private func handleStatusClick() {
        if showingToast, let cwd = currentToast?.focusCWD, !cwd.isEmpty {
            FocusEngine.focus(cwd: cwd, name: currentToast?.focusName ?? "")
            dismissToast()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            openedByHover = false
            popover.performClose(nil)
        } else {
            showPopover(takeKey: true)
        }
    }

    /// `takeKey` is false for hover-opened menus: grabbing key focus while the
    /// user is typing in their terminal would be hostile. A click still takes it.
    private func showPopover(takeKey: Bool) {
        guard let button = statusItem.button, !popover.isShown else { return }
        dismissToast()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if takeKey { popover.contentViewController?.view.window?.makeKey() }
    }

    // MARK: - Open on hover

    private func handleHover(_ inside: Bool) {
        guard AppSettings.shared.openOnHover else { return }
        if inside {
            hoverCloseTimer?.invalidate()
            guard !popover.isShown, !showingToast else { return }
            // Small delay so sweeping the pointer across the menu bar on the way
            // somewhere else doesn't pop the menu open.
            hoverOpenTimer?.invalidate()
            hoverOpenTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.popover.isShown, !self.showingToast else { return }
                    self.openedByHover = true
                    self.showPopover(takeKey: false)
                }
            }
        } else {
            hoverOpenTimer?.invalidate()
            scheduleHoverClose()
        }
    }

    /// Poll after hover-out: the pointer has to travel off the item and across
    /// the popover's arrow to reach the menu, so closing on the exit event alone
    /// would snap it shut mid-reach. Keep it open while the pointer is over
    /// either the item or the menu.
    private func scheduleHoverClose() {
        guard openedByHover else { return }
        hoverCloseTimer?.invalidate()
        hoverCloseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.openedByHover, self.popover.isShown else {
                    self.hoverCloseTimer?.invalidate(); return
                }
                guard !self.pointerIsOverMenuOrItem() else { return }
                self.hoverCloseTimer?.invalidate()
                self.openedByHover = false
                self.popover.performClose(nil)
            }
        }
    }

    private func pointerIsOverMenuOrItem() -> Bool {
        let p = NSEvent.mouseLocation
        // Pad the rects so the gap between the item and the popover arrow reads
        // as "still hovering" rather than an exit.
        if let window = popover.contentViewController?.view.window,
           window.frame.insetBy(dx: -8, dy: -8).contains(p) { return true }
        if let button = statusItem.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.insetBy(dx: -8, dy: -12).contains(p) { return true }
        }
        return false
    }

    // MARK: - Test hook

    nonisolated static let testToastName = Notification.Name("dev.rahulkrishna.roundtable.testToast")

    @objc private nonisolated func handleTestToast(_ note: Notification) {
        let raw = (note.object as? String) ?? "3"
        let forcePanel = raw.hasPrefix("panel:")
        let n = Int(raw.replacingOccurrences(of: "panel:", with: "")) ?? 3
        Task { @MainActor in self.fireTestToasts(n, forcePanel: forcePanel) }
    }

    /// When `forcePanel` is set, bypass detection and always use the floating
    /// panel, so over-full-screen behavior can be verified directly.
    private var debugForcePanel = false

    private func fireTestToasts(_ n: Int, forcePanel: Bool = false) {
        debugForcePanel = forcePanel
        let count = max(1, min(n, 8))
        for i in 1...count {
            queue.append(.init(text: "Test toast \(i) of \(count)", accent: i.isMultiple(of: 2) ? .attention : .ready))
        }
        if !showingToast { showNext() }
    }

    // MARK: - Hook events (Claude Code)

    nonisolated static let hookEventName = Notification.Name("dev.rahulkrishna.roundtable.hook")

    @objc private nonisolated func handleHook(_ note: Notification) {
        guard let json = note.object as? String, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let event = obj["hook_event_name"] as? String ?? ""
        let cwd = obj["cwd"] as? String ?? ""
        let message = obj["message"] as? String ?? ""
        let sessionId = obj["session_id"] as? String ?? ""
        let toolName = obj["tool_name"] as? String ?? ""
        // The actual command/argument, when the hook carries it (shape varies by
        // harness). Used as the prompt preview so you see what you're approving.
        let toolInput = obj["tool_input"] as? [String: Any]
        let command = (obj["command"] as? String)
            ?? (toolInput?["command"] as? String)
            ?? (toolInput?["file_path"] as? String)
            ?? ((obj["input"] as? [String: Any])?["command"] as? String)
        // Stable id for the specific prompt, so a re-notified pending prompt
        // (Claude re-fires every ~30-60s) doesn't re-toast on every nudge.
        let dedupeId = (obj["prompt_id"] as? String)
            ?? (obj["tool_call_id"] as? String) ?? (obj["toolCallId"] as? String)
            ?? (obj["turn_id"] as? String) ?? ""
        Task { @MainActor in
            self.handleHookEvent(event: event, cwd: cwd, message: message,
                                 sessionId: sessionId, toolName: toolName,
                                 command: command, dedupeId: dedupeId)
        }
    }

    /// Surface permission prompts from either harness. Turn-end/idle is already
    /// caught by polling, so we only act on permission events here (no dupes).
    /// Claude Code sends a `Notification` whose message mentions permission. Codex
    /// sends `PermissionRequest`, which fires only when an approval is needed.
    private func handleHookEvent(event: String, cwd: String, message: String,
                                 sessionId: String, toolName: String, command: String?,
                                 dedupeId: String) {
        let session = store.sessions.first { $0.id == sessionId || $0.cwd == cwd }
        let name = session?.name ?? (cwd.isEmpty ? "session" : (cwd as NSString).lastPathComponent)
        let harness = session?.harness ?? .claudeCode   // Notification is Claude; PermissionRequest usually resolves via cwd
        let key = dedupeId.isEmpty ? "\(sessionId)|\(toolName)|\(message)" : dedupeId

        let isPermission = (event == "Notification" && message.range(of: "permission", options: .caseInsensitive) != nil)
            || event == "PermissionRequest"
        guard isPermission else { return }

        // Record the actionable prompt (drives the Allow/Deny/Jump row) even when
        // the toast is suppressed as a repeat, so the buttons persist in the menu.
        store.recordApproval(id: key, sessionId: sessionId, cwd: cwd, harness: harness, tool: toolName, command: command)

        guard !suppressRepeat(key) else { return }
        let tool = toolName.isEmpty ? "a command" : toolName
        let text = event == "PermissionRequest" ? "\(name) — approve \(tool)?" : "\(name) — needs permission"
        firePermissionToast(text: text, cwd: cwd, name: name)
    }

    /// Fire the permission toast, unless the user asked us to defer to a terminal
    /// that notifies on its own (muxy) — checked off-main since it locates the pane.
    private func firePermissionToast(text: String, cwd: String, name: String) {
        guard AppSettings.shared.deferTerminalNotifications, !cwd.isEmpty else {
            enqueueRaw(text: text, accent: .attention, cwd: cwd, name: name)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selfNotifies = ProcessCorrelator.terminalSelfNotifies(cwd: cwd)
            Task { @MainActor in
                guard let self, !selfNotifies else { return }
                self.enqueueRaw(text: text, accent: .attention, cwd: cwd, name: name)
            }
        }
    }

    /// Toast a given prompt once, then allow a re-nudge only after the window has
    /// passed, so an unanswered prompt reminds you periodically without spamming.
    private var lastToasted: [String: Date] = [:]
    private let renudgeWindow: TimeInterval = 120

    private func suppressRepeat(_ key: String) -> Bool {
        let now = Date()
        lastToasted = lastToasted.filter { now.timeIntervalSince($0.value) < renudgeWindow }
        if let last = lastToasted[key], now.timeIntervalSince(last) < renudgeWindow { return true }
        lastToasted[key] = now
        return false
    }

    private func enqueueRaw(text: String, accent: ToastStatusView.Accent, cwd: String = "", name: String = "") {
        if queue.contains(where: { $0.text == text }) { return }
        queue.append(.init(text: text, accent: accent,
                           focusCWD: cwd.isEmpty ? nil : cwd, focusName: name))
        if !showingToast { showNext() }
    }

    // MARK: - Toast queue

    private func enqueue(_ session: Session) {
        let accent: ToastStatusView.Accent = (session.state == .waitingPermission || session.state == .error) ? .attention : .ready
        let toast = ToastStatusView.Toast(
            text: "\(session.name) — \(session.state.label)", accent: accent,
            focusCWD: session.cwd, focusName: session.name)
        if queue.contains(where: { $0.text == toast.text }) { return }   // coalesce dupes
        queue.append(toast)
        if !showingToast { showNext() }
    }

    private func showNext() {
        guard isActive else { queue.removeAll(); return }
        guard !popover.isShown, !queue.isEmpty else { return }
        let toast = queue.removeFirst()
        showingToast = true
        currentToast = toast

        routeToast(toast)
        playSound(toast.accent)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: toastDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishToast() }
        }
    }

    /// Decide where a toast shows:
    /// In all-screens mode a floating pill shows on every screen, each positioned
    /// for that screen's own full-screen state. Otherwise it shows only on the
    /// focused screen: a panel if that screen is full-screen, else the menu-bar-item
    /// toast.
    private func routeToast(_ toast: ToastStatusView.Toast) {
        let accent: ToastAccent = toast.accent == .attention ? .attention : .ready

        if AppSettings.shared.fireOnAllScreens {
            toastPanel.show(text: toast.text, accent: accent,
                            focusCWD: toast.focusCWD, focusName: toast.focusName, on: NSScreen.screens)
            return
        }
        let screen = NSScreen.focused
        if debugForcePanel || FullScreenDetector.isFullScreen(screen) {
            toastPanel.show(text: toast.text, accent: accent,
                            focusCWD: toast.focusCWD, focusName: toast.focusName, on: [screen])
        } else {
            toastView.setToast(toast)
            animateLength(to: toastView.toastWidth(for: toast.text))
        }
    }

    private func finishToast() {
        if queue.isEmpty {
            // Last one: fully exit and remove.
            toastPanel.close()
            collapseItemToast()
            showingToast = false
            currentToast = nil
            debugForcePanel = false   // don't let a --test-toast-fs latch real toasts to the panel
        } else {
            // Retract the current one, then let the next enter once it's fully
            // out. That's a clean exit-then-enter rather than a mid-animation swap.
            toastPanel.retract()
            collapseItemToast()
            gapTimer?.invalidate()
            gapTimer = Timer.scheduledTimer(withTimeInterval: ToastPanelController.exitDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showNext() }
            }
        }
    }

    private func dismissToast() {
        hideTimer?.invalidate()
        gapTimer?.invalidate()
        toastPanel.close()
        collapseItemToast()
        showingToast = false
        currentToast = nil
    }

    private func collapseItemToast() {
        toastView.setToast(nil)
        animateLength(to: idleLength)
    }

    // Full-screen routing uses FullScreenDetector (private Spaces API). The old
    // NSScreen.visibleFrame heuristic was removed because it can't see another
    // app's full-screen space from a background app.

    private func playSound(_ accent: ToastStatusView.Accent) {
        guard AppSettings.shared.soundEnabled else { return }
        let name = accent == .attention ? AppSettings.shared.permissionSound : AppSettings.shared.waitingSound
        NSSound(named: name)?.play()
    }

    // MARK: - Settings window

    func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Roundtable Settings"
        w.contentViewController = NSHostingController(rootView: SettingsView())
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Width animation

    private func animateLength(to target: CGFloat) {
        lengthTimer?.invalidate()
        let start = statusItem.length
        guard abs(target - start) > 0.5 else { statusItem.length = target; return }
        let steps = 12
        lengthAnimStep = 0
        lengthTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lengthAnimStep += 1
                let p = min(1.0, Double(self.lengthAnimStep) / Double(steps))
                let eased = 1 - pow(1 - p, 3)   // easeOutCubic
                self.statusItem.length = start + (target - start) * CGFloat(eased)
                if p >= 1 { self.lengthTimer?.invalidate() }
            }
        }
    }

    deinit {
        // Defensive only, since this controller lives for the whole app session.
        // Timers use [weak self], so they no-op after dealloc.
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

extension MenuBarController: NSPopoverDelegate {
    /// Drain any toasts that arrived while the popover was open (showNext
    /// early-returns while it's shown, so they'd otherwise be stranded).
    func popoverDidClose(_ notification: Notification) {
        openedByHover = false
        hoverCloseTimer?.invalidate()
        if !showingToast, !queue.isEmpty { showNext() }
    }
}
