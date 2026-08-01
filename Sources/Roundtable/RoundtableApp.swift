import SwiftUI

struct RoundtableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is menu-bar driven from the AppDelegate (AppKit NSStatusItem),
        // so we need no real scene. Settings is an inert placeholder.
        Settings { EmptyView() }
    }
}

/// Menu-bar-only agent app: no dock icon, no main window. Boots the AppKit
/// status-item controller and the polling engine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var orb: OrbController?

    nonisolated static let orbToggleName = Notification.Name("dev.rahulkrishna.roundtable.orbToggle")
    nonisolated static let testUpdateName = Notification.Name("dev.rahulkrishna.roundtable.testUpdate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(store: SessionStore.shared)
        SessionStore.shared.start()
        applyPresentation()

        NotificationCenter.default.addObserver(
            forName: AppSettings.presentationChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPresentation() }
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(toggleOrb), name: Self.orbToggleName, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(testUpdate), name: Self.testUpdateName, object: nil)

        UpdateController.shared.start()

        HotkeyManager.shared.handler = { [weak self] action in self?.perform(action) }
        HotkeyManager.shared.numberHandler = { [weak self] index in self?.jump(to: index) }
        HotkeyManager.shared.start()
    }

    /// One of the two presentations is live at a time; the other steps aside.
    private func applyPresentation() {
        let mode = AppSettings.shared.presentation
        menuBar?.setActive(mode == .menuBar)

        switch mode {
        case .menuBar:
            orb?.hide()
        case .orb:
            if orb == nil {
                orb = OrbController(store: SessionStore.shared)
                orb?.onSettings = { [weak self] in self?.menuBar?.openSettings() }
            }
            orb?.show()
        }
    }

    /// `--test-update`: force the update button on so its look can be checked
    /// without waiting for a real release to exist.
    @objc private func testUpdate() {
        MainActor.assumeIsolated { UpdateController.shared.showFakeUpdate() }
    }

    // MARK: - Hotkeys

    /// The whole point of the shortcuts: act on a session without leaving what
    /// you're doing, so each of these has to work with the orb closed.
    private func perform(_ action: HotkeyAction) {
        let store = SessionStore.shared
        switch action {
        case .toggleList:
            orb?.toggleList()
        case .jumpToAttention:
            guard let session = store.sessions.first(where: \.needsAttention) ?? store.sessions.first else { return }
            FocusEngine.focus(session)
        case .approve, .deny:
            answerPending(action == .approve ? .allow : .deny)
        case .toggleOrb:
            orb?.isVisible == true ? orb?.hide() : orb?.show()
        }
    }

    /// Answer whichever prompt is waiting. With more than one pending we take
    /// the top of the list, which is the one the orb is showing.
    private func answerPending(_ decision: ApprovalDecision) {
        let store = SessionStore.shared
        guard let session = store.sessions.first(where: { store.pendingApproval(for: $0) != nil }),
              let approval = store.pendingApproval(for: session), approval.canAnswer else { return }
        AnswerInjector.answer(cwd: approval.cwd, harness: approval.harness, decision: decision)
        store.clearApproval(approval)
    }

    private func jump(to index: Int) {
        let sessions = SessionStore.shared.sessions
        guard index < sessions.count else { return }
        FocusEngine.focus(sessions[index])
    }

    @objc private nonisolated func toggleOrb() {
        Task { @MainActor in self.performOrbToggle() }
    }

    /// Debug entry point (`--test-orb`): flip the mode, which shows or hides the
    /// orb through the normal path.
    private func performOrbToggle() {
        AppSettings.shared.presentation = AppSettings.shared.presentation == .orb ? .menuBar : .orb
    }
}
