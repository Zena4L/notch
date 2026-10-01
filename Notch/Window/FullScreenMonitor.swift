import AppKit

/// Works out whether a full-screen app covers a display.
///
/// macOS has no "is full screen" API for other apps, so we look for a normal-level window
/// of the frontmost app that exactly covers the display. Window bounds don't need Screen
/// Recording permission. We only re-check when the Space or the active app changes.
final class FullScreenMonitor {
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
    }

    func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let displayBounds = CGDisplayBounds(screen.displayID)
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return false }
            return bounds == displayBounds
        }
    }

    private func changed() {
        onChange?()
        // Space switches animate; check once more after the animation settles.
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            onChange?()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
