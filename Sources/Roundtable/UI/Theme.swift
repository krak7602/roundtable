import SwiftUI
import AppKit

/// One source of truth for state color, shared by the menu dots and the toast so
/// a state looks the same everywhere. Only two colors carry meaning — amber says
/// "needs me", green says "ready for me". Working and idle are gray: nothing to
/// act on, told apart by motion, not hue.
enum RTColor {
    static let attention = Color(red: 0.98, green: 0.69, blue: 0.13)   // amber — needs permission
    static let ready     = Color(red: 0.25, green: 0.82, blue: 0.41)   // green — waiting for you
    static let busy      = Color(white: 0.82)                          // gray — working (shown dim/animated)
    static let idle      = Color(white: 0.60)                          // gray — idle (shown faint)

    static func accent(for state: SessionState) -> Color {
        switch state {
        case .waitingPermission, .error: return attention
        case .waitingInput, .done:       return ready
        case .working, .idle:            return busy
        }
    }
}

/// The real native material. SwiftUI's own materials render flat grey inside a
/// transparent floating panel (no window backdrop to sample), so anything that
/// floats over other apps has to blend behind the window like this.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

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

/// Compact "time since" for the row's trailing meta ("now", "4m", "3h", "2d").
enum RelativeTime {
    static func short(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}
