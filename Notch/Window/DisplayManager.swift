import AppKit

/// Runs one island per display (per Settings › General › Show island on), fans service
/// events out to every island, and turns cursor movement into hover enter/exit.
final class DisplayManager {
    private let settings: SettingsStore
    private let battery: BatteryService
    private let timers: TimerService
    private let nowPlaying: NowPlayingService
    private let downloads: DownloadService
    private let calendar: CalendarService
    // Shared by every display's island.
    private let lyrics = LyricsService()
    private let stats: SystemStatsService
    private let weather: WeatherService
    private let clipboard: ClipboardService

    private var controllers: [CGDirectDisplayID: IslandWindowController] = [:]
    private var pointerInside: Set<CGDirectDisplayID> = []
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private let fullScreen = FullScreenMonitor()

    var coordinators: [IslandCoordinator] { controllers.values.map(\.coordinator) }

    /// The island a shortcut or link should act on: the one under the cursor, else the built-in one.
    var activeCoordinator: IslandCoordinator? {
        let mouse = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.screen.frame.contains(mouse) }) { return c.coordinator }
        if let notch = NSScreen.notchScreen, let c = controllers[notch.displayID] { return c.coordinator }
        return controllers.values.first?.coordinator
    }

    init(
        settings: SettingsStore, battery: BatteryService, timers: TimerService,
        nowPlaying: NowPlayingService, downloads: DownloadService, calendar: CalendarService
    ) {
        self.settings = settings
        self.battery = battery
        self.timers = timers
        self.nowPlaying = nowPlaying
        self.downloads = downloads
        self.calendar = calendar
        stats = SystemStatsService(settings: settings)
        weather = WeatherService(settings: settings)
        clipboard = ClipboardService(settings: settings)

        battery.onPluggedIn = { [weak self] level in self?.showEverywhere(.charging(level)) }
        battery.onUnplugged = { [weak self] level in self?.showEverywhere(.unplugged(level)) }
        battery.onLowBattery = { [weak self] level in self?.showEverywhere(.lowBattery(level)) }
        nowPlaying.onTrackChange = { [weak self] in self?.showEverywhere(.trackChange) }
        calendar.onMeetingSoon = { [weak self] in self?.showEverywhere(.meeting) }
        timers.onCountdownFinished = { [weak self] in self?.countdownFinished() }
        downloads.onFinished = { [weak self] _ in self?.showEverywhere(.downloadDone) }
        downloads.onFailed = { [weak self] _ in self?.showEverywhere(.downloadFailed) }
        fullScreen.onChange = { [weak self] in self?.updateFullScreen() }

        rebuild()
        installMonitors()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observers.append(center.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            // Everything else the island reads updates through observation, not a rebuild.
            guard note.affects(["displayMode", "hideWhileSharing"]) else { return }
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observers.append(center.addObserver(forName: .previewPeek, object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String
            MainActor.assumeIsolated {
                guard let name, let peek = Peek(previewName: name) else { return }
                self?.preview(peek)
            }
        })
    }

    // MARK: Displays

    private func targetScreens() -> [NSScreen] {
        switch settings.displayMode {
        case .builtIn:
            return NSScreen.notchScreen.map { [$0] } ?? []
        case .all:
            return NSScreen.screens
        case .withCursor:
            let mouse = NSEvent.mouseLocation
            return (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.notchScreen).map { [$0] } ?? []
        }
    }

    private func rebuild() {
        let screens = targetScreens()
        let ids = Set(screens.map(\.displayID))

        for (id, controller) in controllers where !ids.contains(id) {
            controller.close()
            controllers[id] = nil
            pointerInside.remove(id)
        }
        for screen in screens {
            let id = screen.displayID
            if let controller = controllers[id] {
                controller.update(screen: screen)
            } else {
                let controller = makeController(for: screen)
                controllers[id] = controller
                wireHoverZone(controller)
            }
            controllers[id]?.apply(settings)
        }
        updateFullScreen()
        updateCursorFollowing()
    }

    private func makeController(for screen: NSScreen) -> IslandWindowController {
        let coordinator = IslandCoordinator(
            settings: settings, battery: battery, timers: timers,
            nowPlaying: nowPlaying, downloads: downloads, calendar: calendar, lyrics: lyrics,
            stats: stats, weather: weather, clipboard: clipboard
        )
        let controller = IslandWindowController(screen: screen, coordinator: coordinator)
        coordinator.onFocusRequest = { [weak controller] in controller?.panel.makeKey() }
        coordinator.onCollapse = { [weak controller] in controller?.releaseKeyFocus() }
        // Clicking elsewhere ends typing in the link field, which lets the island collapse.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: controller.panel, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.isTyping = false }
        })
        return controller
    }

    private func updateFullScreen() {
        for controller in controllers.values {
            let isFullScreen = fullScreen.isFullScreen(controller.screen)
            if controller.coordinator.isFullScreen != isFullScreen {
                controller.coordinator.isFullScreen = isFullScreen
            }
        }
    }

    // MARK: Events from services

    /// Volume and brightness from HUDService.
    func showLevel(_ kind: HUDService.Kind, _ level: Double, muted: Bool) {
        showEverywhere(.hud(kind, level: Int((level * 100).rounded()), muted: muted))
    }

    private func showEverywhere(_ peek: Peek) {
        for c in coordinators { c.show(peek) }
    }

    /// Settings › Try it: show on the island the user is most likely looking at.
    private func preview(_ peek: Peek) {
        if peek == .meeting { calendar.prepareSampleMeeting() }
        (activeCoordinator ?? coordinators.first)?.show(peek, force: true)
    }

    private func countdownFinished() {
        // Sound and haptic once, however many displays show the peek.
        if !settings.timerSound.isEmpty { NSSound(named: settings.timerSound)?.play() }
        if settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        showEverywhere(.timerDone)
    }

    // MARK: Hover
    //
    // Far from the island, Notch receives no mouse events: each display's hover zone
    // (an invisible window over the island) reports when the cursor arrives. Only then
    // do we watch individual mouse movements, until the cursor has left and the island
    // has closed again.

    private var mouseMonitors: [Any] = []
    private var isTrackingPointer: Bool { !mouseMonitors.isEmpty }
    private var cursorFollowTask: Task<Void, Never>?

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            // Notch has no Edit menu, so give the link field ⌘V/⌘C/⌘X/⌘A ourselves.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let key = event.charactersIgnoringModifiers?.lowercased(),
               let action = Self.editActions[key],
               controllers.values.contains(where: { $0.panel.isKeyWindow }) {
                NSApp.sendAction(action, to: nil, from: nil)
                return nil
            }
            // Esc collapses the island once a click has given it keyboard focus.
            guard event.keyCode == 53 else { return event }
            let expanded = coordinators.filter(\.isExpanded)
            guard !expanded.isEmpty else { return event }
            expanded.forEach { $0.collapse() }
            return nil
        }) {
            eventMonitors.append(m)
        }
    }

    private func wireHoverZone(_ controller: IslandWindowController) {
        controller.hoverZone.onEnter = { [weak self] in
            self?.startTrackingPointer()
            self?.pointerMoved()
        }
        controller.hoverZone.onClick = { [weak controller] in controller?.coordinator.clicked() }
    }

    private func startTrackingPointer() {
        guard !isTrackingPointer else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.pointerMoved() }) {
            mouseMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) {
            mouseMonitors.append(m)
        }
    }

    private func stopTrackingPointer() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    /// "With cursor" has to notice the pointer moving to another display. macOS has no event
    /// for that, but it does announce switching apps or Spaces — which is what usually happens
    /// on the new display — so we follow those straight away, with a slow check as a fallback.
    private var cursorFollowObservers: [NSObjectProtocol] = []

    private func updateCursorFollowing() {
        guard settings.displayMode == .withCursor else {
            cursorFollowTask?.cancel()
            cursorFollowTask = nil
            cursorFollowObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            cursorFollowObservers.removeAll()
            return
        }
        guard cursorFollowTask == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            cursorFollowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followCursorIfNeeded() }
            })
        }
        cursorFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.followCursorIfNeeded()
            }
        }
    }

    private func followCursorIfNeeded() {
        let location = NSEvent.mouseLocation
        guard controllers.count == 1, let current = controllers.values.first,
              !current.screen.frame.contains(location), !current.coordinator.isExpanded,
              NSScreen.screens.contains(where: { $0.frame.contains(location) })
        else { return }
        rebuild()
    }

    private static let editActions: [String: Selector] = [
        "v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
        "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
    ]

    private func pointerMoved() {
        let location = NSEvent.mouseLocation

        for (id, controller) in controllers {
            let inside = controller.hitRect.contains(location)
            controller.panel.ignoresMouseEvents = !inside
            guard inside != pointerInside.contains(id) else { continue }
            if inside {
                pointerInside.insert(id)
                let onBubble = controller.bubbleRect?.contains(location) == true
                controller.coordinator.pointerEntered(focus: onBubble ? controller.coordinator.state.bubble : nil)
            } else {
                pointerInside.remove(id)
                controller.coordinator.pointerExited()
            }
        }
        // Back to zero mouse events once the cursor has left and every island has closed.
        if pointerInside.isEmpty, !coordinators.contains(where: \.isExpanded) {
            stopTrackingPointer()
        }
    }
}
