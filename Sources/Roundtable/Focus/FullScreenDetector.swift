import Foundation
import AppKit

/// Detects whether the currently-displayed space is a full-screen space, using
/// the private SkyLight/CoreGraphics spaces API (what yabai / AltTab use). This
/// is the only reliable way to know another app is in full-screen from a
/// background app. The public `NSScreen.visibleFrame` heuristic reports the
/// desktop space's menu bar as visible even while a full-screen app is up front.
///
/// Loaded via dlsym so a missing symbol (future macOS) degrades to "not
/// full-screen" (→ menu-bar-item toast) instead of failing to launch.
enum FullScreenDetector {
    private typealias ConnFn = @convention(c) () -> UInt32
    private typealias SpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?

    /// Space type reported by the window server for a native full-screen space.
    private static let fullScreenSpaceType = 4

    private static let connection: UInt32? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "_CGSDefaultConnection") else { return nil }
        return unsafeBitCast(sym, to: ConnFn.self)()
    }()

    private static let copySpaces: SpacesFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: SpacesFn.self)
    }()

    /// Current-space type for each display (for diagnostics / `--fs-check`).
    static func currentSpaceTypes() -> [Int] {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return displays.compactMap { display in
            (display["Current Space"] as? [String: Any])?["type"] as? Int
        }
    }

    /// True if any display's current space is a native full-screen space.
    static func inFullScreenSpace() -> Bool {
        currentSpaceTypes().contains(fullScreenSpaceType)
    }

    /// Display Identifiers (UUID strings, or "Main") whose current space is full-screen.
    private static func fullScreenDisplayIdentifiers() -> Set<String> {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        var ids: Set<String> = []
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? Int) == fullScreenSpaceType,
                  let id = display["Display Identifier"] as? String else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Whether a specific screen is showing a full-screen space right now.
    static func isFullScreen(_ screen: NSScreen) -> Bool {
        let ids = fullScreenDisplayIdentifiers()
        if ids.isEmpty { return false }
        // CGS identifies the primary display as "Main"; others by UUID string.
        if screen == NSScreen.screens.first, ids.contains("Main") { return true }
        if let uuid = screen.displayUUID, ids.contains(uuid) { return true }
        // Single-display fallback: any full-screen id means this screen.
        return NSScreen.screens.count == 1 && !ids.isEmpty
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var displayUUID: String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// The screen the user is most likely looking at: where the cursor is.
    static var focused: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
