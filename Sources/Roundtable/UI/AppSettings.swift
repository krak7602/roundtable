import Foundation
import AppKit

/// Where Roundtable lives on screen: the menu bar, or a floating orb you can
/// put anywhere. Both show the same session list; they differ in where you
/// reach for it and where alerts come from.
///
/// The orb is the product right now. The menu-bar path is kept whole and still
/// works (`--test-orb` flips between them), it just isn't offered in Settings,
/// so there's a way back without rebuilding it.
enum Presentation: String, CaseIterable, Identifiable {
    case menuBar, orb
    var id: String { rawValue }
    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .orb: return "Floating orb"
        }
    }
}

/// User-facing preferences, persisted in UserDefaults. Drives the Settings panel
/// (sound on/off + which sound, per-harness visibility, integration state).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    @Published var soundEnabled: Bool { didSet { d.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var waitingSound: String { didSet { d.set(waitingSound, forKey: "waitingSound") } }
    @Published var permissionSound: String { didSet { d.set(permissionSound, forKey: "permissionSound") } }

    /// Harness short-names the user has hidden from the menu / toasts.
    @Published var hiddenHarnesses: Set<String> { didSet { d.set(Array(hiddenHarnesses), forKey: "hiddenHarnesses") } }

    /// Off: toast on the focused screen only. On: on every screen.
    @Published var fireOnAllScreens: Bool { didSet { d.set(fireOnAllScreens, forKey: "fireOnAllScreens") } }

    /// On: don't fire our own permission toast for a session whose terminal
    /// already notifies you (muxy), so you aren't double-notified. The menu row
    /// and its Allow/Deny still appear; only our toast is suppressed.
    @Published var deferTerminalNotifications: Bool { didSet { d.set(deferTerminalNotifications, forKey: "deferTerminalNotifications") } }

    /// On: pointing at the menu-bar item opens the session list, no click needed.
    @Published var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "openOnHover") } }

    /// Menu bar or floating orb. Changing it takes effect immediately.
    @Published var presentation: Presentation {
        didSet {
            d.set(presentation.rawValue, forKey: "presentation")
            NotificationCenter.default.post(name: Self.presentationChanged, object: nil)
        }
    }

    nonisolated static let presentationChanged = Notification.Name("dev.rahulkrishna.roundtable.presentationChanged")

    private init() {
        soundEnabled = d.object(forKey: "soundEnabled") as? Bool ?? true
        waitingSound = d.string(forKey: "waitingSound") ?? "Submarine"
        permissionSound = d.string(forKey: "permissionSound") ?? "Hero"
        hiddenHarnesses = Set(d.stringArray(forKey: "hiddenHarnesses") ?? [])
        fireOnAllScreens = d.bool(forKey: "fireOnAllScreens")
        deferTerminalNotifications = d.bool(forKey: "deferTerminalNotifications")
        openOnHover = d.object(forKey: "openOnHover") as? Bool ?? true
        presentation = Presentation(rawValue: d.string(forKey: "presentation") ?? "") ?? .orb
    }

    func isEnabled(_ harness: Harness) -> Bool { !hiddenHarnesses.contains(harness.shortName) }

    func setEnabled(_ harness: Harness, _ on: Bool) {
        if on { hiddenHarnesses.remove(harness.shortName) } else { hiddenHarnesses.insert(harness.shortName) }
    }

    /// System sounds available for the pickers (names under /System/Library/Sounds).
    static let availableSounds: [String] = {
        let dir = "/System/Library/Sounds"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()
}
