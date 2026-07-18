import Foundation
import AppKit

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

    private init() {
        soundEnabled = d.object(forKey: "soundEnabled") as? Bool ?? true
        waitingSound = d.string(forKey: "waitingSound") ?? "Glass"
        permissionSound = d.string(forKey: "permissionSound") ?? "Submarine"
        hiddenHarnesses = Set(d.stringArray(forKey: "hiddenHarnesses") ?? [])
        fireOnAllScreens = d.bool(forKey: "fireOnAllScreens")
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
