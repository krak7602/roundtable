import AppKit
import Carbon.HIToolbox

/// A key combination, stored as the raw values macOS gives us so it survives in
/// UserDefaults and can be handed straight back to Carbon.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags rawValue, masked to the device-independent flags.
    var modifiers: UInt

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// How the combination reads in Settings, e.g. "⌘⌥R".
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    /// Readable name for the handful of keys that aren't a plain character.
    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default:
            // Ask the current keyboard layout what this key produces, so the
            // label matches what's printed on the user's keys.
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return "Key \(code)" }
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                      UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                      &deadKeys, chars.count, &length, &chars)
            }
            guard status == noErr, length > 0 else { return "Key \(code)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

/// Everything the user can trigger without reaching for the mouse.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggleList
    case jumpToAttention
    case approve
    case deny
    case toggleOrb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggleList: return "Open / close the list"
        case .jumpToAttention: return "Jump to the session that needs you"
        case .approve: return "Approve the pending prompt"
        case .deny: return "Deny the pending prompt"
        case .toggleOrb: return "Show / hide the orb"
        }
    }

    var detail: String {
        switch self {
        case .toggleList: return "Expand the orb into the session list, and collapse it again."
        case .jumpToAttention: return "Go straight to the terminal of the session at the top of the list."
        case .approve: return "Answer the waiting permission prompt with yes."
        case .deny: return "Answer the waiting permission prompt with no."
        case .toggleOrb: return "Take the orb off screen entirely, and bring it back."
        }
    }

    var `default`: Shortcut? {
        let cmdOpt = NSEvent.ModifierFlags([.command, .option]).rawValue
        switch self {
        case .toggleList: return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: cmdOpt)
        case .jumpToAttention: return Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: cmdOpt)
        case .approve: return Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: cmdOpt)
        case .deny: return Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: cmdOpt)
        case .toggleOrb: return Shortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: cmdOpt)
        }
    }

    var storageKey: String { "hotkey.\(rawValue)" }
}

/// Registers global hotkeys through Carbon.
///
/// Carbon's `RegisterEventHotKey` is the right tool here despite its age: it
/// works system-wide with no Accessibility permission (an `NSEvent` global
/// monitor needs one, and still can't stop the key reaching the focused app),
/// and it keeps the project dependency-free.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// What to run for each action. Set once by the app.
    var handler: ((HotkeyAction) -> Void)?
    /// Jumping to the Nth session, from the number keys.
    var numberHandler: ((Int) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: HotkeyAction] = [:]
    private var numbers: [UInt32: Int] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    // MARK: - Storage

    func shortcut(for action: HotkeyAction) -> Shortcut? {
        let d = UserDefaults.standard
        // An explicitly cleared shortcut is stored as an empty string, so
        // "unset" and "never touched" stay distinguishable.
        if let raw = d.string(forKey: action.storageKey) {
            if raw.isEmpty { return nil }
            if let data = raw.data(using: .utf8),
               let s = try? JSONDecoder().decode(Shortcut.self, from: data) { return s }
        }
        return action.default
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        let d = UserDefaults.standard
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            d.set(String(decoding: data, as: UTF8.self), forKey: action.storageKey)
        } else {
            d.set("", forKey: action.storageKey)
        }
        reload()
    }

    /// ⌘⌥1…9 jump to the first nine sessions. On by default; the toggle lives
    /// in Settings because these are the shortcuts most likely to collide with
    /// something the user already has.
    var numberJumpsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkey.numberJumps") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hotkey.numberJumps"); reload() }
    }

    // MARK: - Registration

    func start() {
        installEventHandler()
        reload()
    }

    func reload() {
        unregisterAll()
        for action in HotkeyAction.allCases {
            guard let shortcut = shortcut(for: action) else { continue }
            register(shortcut) { [weak self] in self?.actions[$0] = action }
        }
        if numberJumpsEnabled {
            let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            let cmdOpt = NSEvent.ModifierFlags([.command, .option]).rawValue
            for (index, key) in keys.enumerated() {
                let shortcut = Shortcut(keyCode: UInt32(key), modifiers: cmdOpt)
                register(shortcut) { [weak self] in self?.numbers[$0] = index }
            }
        }
    }

    private func register(_ shortcut: Shortcut, record: (UInt32) -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x52544B59), id: id)   // 'RTKY'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }   // already taken by another app
        refs[id] = ref
        record(id)
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        numbers.removeAll()
    }

    private func installEventHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyManager.shared.fire(pressed) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        if let action = actions[id] { handler?(action) }
        else if let index = numbers[id] { numberHandler?(index) }
    }
}
