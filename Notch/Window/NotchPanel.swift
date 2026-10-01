import AppKit

/// A transparent, borderless panel pinned over the notch, above the menu bar.
/// It never activates the app, so clicking it doesn't steal focus from what you're doing.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // SwiftUI draws the island's shadow
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true  // the display manager turns this off while the cursor is over the island
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally pushes windows below the menu bar; we want to sit on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
