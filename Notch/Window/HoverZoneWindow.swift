import AppKit

/// An invisible window exactly over the collapsed island that tells us when the cursor
/// arrives — so Notch gets no mouse events at all while you're working elsewhere.
///
/// It sits just below the island panel and is filled with an almost-transparent colour:
/// macOS skips windows whose pixels are fully transparent when deciding where the mouse
/// is, so it needs a whisper of alpha. It only ever covers the island itself, which is
/// black anyway, so it's invisible and blocks nothing the island doesn't already cover.
final class HoverZoneWindow: NSWindow {
    var onEnter: (() -> Void)?
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor(white: 0, alpha: 0.008)
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = ZoneView()
        view.onEnter = { [weak self] in self?.onEnter?() }
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class ZoneView: NSView {
    var onEnter: (() -> Void)?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
