import AppKit
import SwiftUI

struct HoverBackground: NSViewRepresentable {
    var isSelected = false

    func makeNSView(context: Context) -> HoverNSView {
        let view = HoverNSView()
        view.isSelected = isSelected
        return view
    }

    func updateNSView(_ view: HoverNSView, context: Context) {
        view.isSelected = isSelected
    }
}

final class HoverNSView: NSView {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha = isSelected ? 0.07 : (isHovering ? 0.045 : 0)
        guard alpha > 0 else { return }
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
