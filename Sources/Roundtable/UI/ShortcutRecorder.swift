import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click it, press the combination you want, and that becomes the shortcut —
/// the pattern every Mac app uses for this. Escape cancels, Delete clears.
///
/// It has to be AppKit: while recording we need the raw key event *before* the
/// system turns it into a menu command, which means a local event monitor.
struct ShortcutRecorder: NSViewRepresentable {
    let action: HotkeyAction
    var onChange: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.hotkeyAction = action
        button.onChange = onChange
        return button
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.refresh()
    }
}

final class RecorderButton: NSButton {
    /// Named to avoid NSButton's own `action` (a Selector).
    var hotkeyAction: HotkeyAction = .toggleList { didSet { refresh() } }
    var onChange: (() -> Void)?

    private var recording = false { didSet { refresh() } }
    private var monitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    func refresh() {
        if recording {
            title = "Press keys…"
        } else if let shortcut = HotkeyManager.shared.shortcut(for: hotkeyAction) {
            title = shortcut.display
        } else {
            title = "Not set"
        }
    }

    @objc private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            guard event.type == .keyDown else { return nil }   // swallow modifier-only events

            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete) {
                HotkeyManager.shared.setShortcut(nil, for: self.hotkeyAction)
                self.stop(); self.onChange?(); return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            // Require a modifier: a bare letter would fire while the user types
            // anywhere on the system.
            guard !flags.isEmpty else { NSSound.beep(); return nil }

            HotkeyManager.shared.setShortcut(
                Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue), for: self.hotkeyAction)
            self.stop()
            self.onChange?()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // The monitor is torn down in stop(), which runs whenever recording ends;
    // a deinit hook can't touch it under strict concurrency.
}
