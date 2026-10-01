import AppKit

extension NSScreen {
    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// The notch's size, or a menu-bar-height stand-in on displays without one.
    var notchSize: CGSize {
        guard hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return CGSize(width: 190, height: max(frame.maxY - visibleFrame.maxY, 24))
        }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    /// Horizontal centre of the notch in global screen coordinates.
    var notchCenterX: CGFloat {
        guard hasNotch, let left = auxiliaryTopLeftArea else { return frame.midX }
        return frame.minX + left.width + notchSize.width / 2
    }

    /// The built-in display with the notch, falling back to the main display (e.g. lid closed).
    static var notchScreen: NSScreen? {
        screens.first(where: \.hasNotch) ?? main
    }
}
