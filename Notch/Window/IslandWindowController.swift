import AppKit
import SwiftUI

/// Owns the panel for one display and keeps it positioned over that display's notch.
final class IslandWindowController {
    /// Big enough for the largest state (Large expanded size) plus its shadow.
    /// The rest is transparent and click-through.
    static let panelSize = CGSize(width: 760, height: 440)

    private(set) var screen: NSScreen
    let panel: NotchPanel
    let coordinator: IslandCoordinator
    let hoverZone = HoverZoneWindow()

    init(screen: NSScreen, coordinator: IslandCoordinator) {
        self.screen = screen
        self.coordinator = coordinator
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))

        let host = NSHostingView(rootView: IslandView().environment(coordinator))
        host.sizingOptions = []  // never let SwiftUI resize the panel
        panel.contentView = host

        reposition()
        hoverZone.orderFrontRegardless()
        panel.orderFrontRegardless()  // above the hover zone
        trackHitRect()
    }

    /// Keeps the hover zone matched to the island as it changes shape.
    private func trackHitRect() {
        let rect = withObservationTracking { hitRect } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.trackHitRect() }
            }
        }
        if rect.isEmpty {
            hoverZone.orderOut(nil)
        } else {
            if hoverZone.frame != rect { hoverZone.setFrame(rect, display: false) }
            if !hoverZone.isVisible {
                hoverZone.orderFrontRegardless()
                panel.orderFrontRegardless()
            }
        }
    }

    /// Screen objects are replaced when displays change; keep ours current.
    func update(screen: NSScreen) {
        self.screen = screen
        reposition()
    }

    private func reposition() {
        coordinator.notchSize = screen.notchSize
        coordinator.hasNotch = screen.hasNotch
        let size = Self.panelSize
        let origin = CGPoint(x: screen.notchCenterX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The island (plus the split bubble, if shown) in global screen coordinates, for hover detection.
    /// It reaches 1 pt above the screen edge so the cursor pinned at the top still counts.
    var hitRect: NSRect {
        guard coordinator.state != .hidden else { return .zero }
        let m = coordinator.metrics
        let width = m.width + 2 * Theme.earRadius
        let island = NSRect(
            x: screen.notchCenterX - width / 2,
            y: screen.frame.maxY - m.height,
            width: width,
            height: m.height + 1
        )
        return bubbleRect.map { island.union($0) } ?? island
    }

    var bubbleRect: NSRect? {
        guard coordinator.state.bubble != nil else { return nil }
        let m = coordinator.metrics
        let size = coordinator.notchSize.height
        return NSRect(
            x: screen.notchCenterX + m.width / 2 + IslandState.bubbleGap,
            y: screen.frame.maxY - size,
            width: size,
            height: size + 1
        )
    }

    func apply(_ settings: SettingsStore) {
        // Full-screen hiding is handled by the island's own `.hidden` state, so the panel
        // always joins full-screen Spaces.
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.collectionBehavior = behavior
        hoverZone.collectionBehavior = behavior
        panel.sharingType = settings.hideWhileSharing ? .none : .readOnly
    }

    /// Give keyboard focus back to whatever app had it before the island was clicked.
    func releaseKeyFocus() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        hoverZone.onEnter = nil
        hoverZone.orderOut(nil)
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
