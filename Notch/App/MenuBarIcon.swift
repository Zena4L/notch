import AppKit
import SwiftUI

/// Notch's own menu bar icons, drawn in code as template images so they follow the
/// menu bar's colour (light, dark, tinted) like system icons.
nonisolated enum MenuBarIcon {
    static func image(_ style: MenuBarIconStyle) -> NSImage {
        switch style {
        case .island, .live: island
        case .pill: pill
        case .waveform: waveform
        }
    }

    /// A little screen with the island hanging from its top edge.
    static let island = template(width: 20) { rect in
        let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 17, height: 12), xRadius: 3, yRadius: 3)
        screen.lineWidth = 1.4
        screen.stroke()
        islandShape(in: NSRect(x: 6, y: 9.6, width: 8, height: 4.9), radius: 2.2).fill()
    }

    /// Just the island.
    static let pill = template(width: 20) { _ in
        islandShape(in: NSRect(x: 2, y: 5, width: 16, height: 8), radius: 4).fill()
    }

    /// The island with a waveform cut out of it, like the app icon.
    static let waveform = template(width: 22) { _ in
        islandShape(in: NSRect(x: 1, y: 3.5, width: 20, height: 10), radius: 5).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let heights: [CGFloat] = [2.5, 5, 3.5, 6, 3]
        var x: CGFloat = 6.2
        for h in heights {
            NSBezierPath(roundedRect: NSRect(x: x, y: 8.5 - h / 2, width: 1.6, height: h), xRadius: 0.8, yRadius: 0.8).fill()
            x += 2.3
        }
    }

    /// A flat top with rounded bottom corners — the island's silhouette.
    private static func islandShape(in r: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: r.maxY))
        path.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        path.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        path.close()
        return path
    }

    private static func template(width: CGFloat, draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            NSColor.black.set()
            draw(rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch"
        return image
    }
}

/// The menu bar label. "Live" switches to what's happening right now.
struct MenuBarLabel: View {
    let settings: SettingsStore
    let nowPlaying: NowPlayingService
    let timers: TimerService
    let downloads: DownloadService

    var body: some View {
        if settings.menuBarIconStyle == .live {
            if downloads.activeItem != nil {
                Image(systemName: "arrow.down.circle")
            } else if timers.countdown != nil || timers.stopwatch != nil {
                Image(systemName: timers.countdown != nil ? "timer" : "stopwatch")
            } else if settings.nowPlayingEnabled, nowPlaying.track?.isPlaying == true {
                Image(nsImage: MenuBarIcon.waveform)
            } else {
                Image(nsImage: MenuBarIcon.pill)
            }
        } else {
            Image(nsImage: MenuBarIcon.image(settings.menuBarIconStyle))
        }
    }
}
