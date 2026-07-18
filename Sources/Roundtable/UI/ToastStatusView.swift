import AppKit

/// The menu-bar item itself, custom-drawn. It has two looks. When idle it shows
/// the grid glyph, plus a small amber badge when sessions need you. As a toast it
/// expands, fills with a state-colored gradient, shows one line of text for a few
/// seconds, then collapses back to idle.
///
/// The toast lives in the menu-bar item rather than a floating window: a
/// peripheral cue in place, so the user is nudged and never interrupted.
final class ToastStatusView: NSView {
    var onClick: (() -> Void)?

    enum Accent {
        case amber, red
        var gradient: NSGradient? {
            switch self {
            case .amber: return NSGradient(
                starting: NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.30, alpha: 1),
                ending:   NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.11, alpha: 1))
            case .red: return NSGradient(
                starting: NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.35, alpha: 1),
                ending:   NSColor(calibratedRed: 0.90, green: 0.23, blue: 0.19, alpha: 1))
            }
        }
    }

    struct Toast { let text: String; let accent: Accent }

    private(set) var attentionCount = 0
    private var toast: Toast?

    func setAttentionCount(_ n: Int) {
        guard n != attentionCount else { return }
        attentionCount = n
        needsDisplay = true
    }

    func setToast(_ t: Toast?) {
        toast = t
        needsDisplay = true
    }

    /// Width the toast wants for its text (the controller animates the item to this).
    func toastWidth(for text: String) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: Self.textFont]).width
        return min(320, 30 + ceil(w) + 16)
    }

    private static let textFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let iconInset: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        if let toast {
            // Gradient pill, kept tall with a small vertical inset so it matches
            // the height of the neighboring menu-bar icons rather than sitting short.
            let pillRect = b.insetBy(dx: 2, dy: 1)
            let radius = pillRect.height / 2
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
            toast.accent.gradient?.draw(in: pill, angle: -90)
            drawIcon(in: b, tint: NSColor.black.withAlphaComponent(0.82))
            drawText(toast.text, in: b, color: NSColor.black.withAlphaComponent(0.9))
        } else {
            drawIcon(in: b, tint: .labelColor)
            if attentionCount > 0 { drawBadge(count: attentionCount, in: b) }
        }
    }

    private func drawIcon(in b: NSRect, tint: NSColor) {
        let name = attentionCount > 0 || toast != nil ? "circle.grid.2x2.fill" : "circle.grid.2x2"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Roundtable") else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let img = base.withSymbolConfiguration(cfg) ?? base
        let size = img.size
        let rect = NSRect(x: iconInset, y: (b.height - size.height) / 2, width: size.width, height: size.height)

        // Standard template-tint: draw the glyph into an offscreen image, then
        // composite the tint over it with sourceAtop.
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size))
        tint.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: rect)
    }

    private func drawText(_ text: String, in b: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.textFont,
            .foregroundColor: color,
        ]
        let textX = iconInset + 20
        let maxW = b.width - textX - 8
        guard maxW > 10 else { return }
        let str = NSAttributedString(string: text, attributes: attrs)
        let h = str.size().height
        let rect = NSRect(x: textX, y: (b.height - h) / 2, width: maxW, height: h)
        str.draw(with: rect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    private func drawBadge(count: Int, in b: NSRect) {
        let d: CGFloat = 13
        let rect = NSRect(x: iconInset + 12, y: b.height - d - 2, width: d, height: d)
        NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.11, alpha: 1).set()
        NSBezierPath(ovalIn: rect).fill()
        let s = "\(min(count, 9))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
