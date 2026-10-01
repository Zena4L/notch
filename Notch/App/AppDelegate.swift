import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore.shared
    let nowPlaying = NowPlayingService()
    let calendar: CalendarService
    let downloads: DownloadService
    let hud: HUDService
    /// Which shortcuts registered successfully, for Settings › Shortcuts.
    let hotkeyStatus = HotkeyStatus()

    private let battery = BatteryService()
    let timers = TimerService()
    private var displayManager: DisplayManager?
    private let hotkeys = HotkeyService()
    private var registeredShortcuts: [KeyShortcut] = []
    private var settingsObserver: NSObjectProtocol?

    override init() {
        calendar = CalendarService(settings: settings)
        downloads = DownloadService(settings: settings)
        hud = HUDService(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        displayManager = DisplayManager(
            settings: settings, battery: battery, timers: timers,
            nowPlaying: nowPlaying, downloads: downloads, calendar: calendar
        )
        hud.onChange = { [weak self] kind, level, muted in self?.displayManager?.showLevel(kind, level, muted: muted) }
        registerShortcuts()
        settingsObserver = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(suffix: "Shortcut") else { return }
            MainActor.assumeIsolated { self?.registerShortcuts() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
    }

    // MARK: Shortcuts

    private func registerShortcuts() {
        let shortcuts = [settings.toggleShortcut, settings.timerShortcut, settings.playPauseShortcut, settings.downloadsShortcut, settings.dashboardShortcut]
        guard shortcuts != registeredShortcuts else { return }
        registeredShortcuts = shortcuts
        hotkeys.unregisterAll()

        hotkeyStatus.failed = []
        func add(_ shortcut: KeyShortcut, _ name: String, _ action: @escaping () -> Void) {
            if shortcut.isSet, !hotkeys.register(shortcut, action: action) { hotkeyStatus.failed.insert(name) }
        }
        add(settings.toggleShortcut, "toggle") { [weak self] in self?.displayManager?.activeCoordinator?.toggleFromKeyboard() }
        add(settings.timerShortcut, "timer") { [weak self] in self?.displayManager?.activeCoordinator?.startQuickTimer() }
        add(settings.playPauseShortcut, "playPause") { [weak self] in self?.nowPlaying.togglePlayPause() }
        add(settings.dashboardShortcut, "dashboard") { [weak self] in self?.displayManager?.activeCoordinator?.toggleFromKeyboard(tab: .dashboard) }
        add(settings.downloadsShortcut, "downloads") { [weak self] in self?.displayManager?.activeCoordinator?.toggleFromKeyboard(tab: .downloads) }
    }

    // MARK: notch:// links

    /// Lets Shortcuts, scripts and other apps control the island, e.g. `open "notch://timer?minutes=25"`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "notch" {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        let island = displayManager?.activeCoordinator
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host() ?? "" {
        case "timer":
            let minutes = query.first { $0.name == "minutes" }?.value.flatMap(Int.init) ?? settings.quickTimerMinutes
            island?.startCountdown(minutes: max(1, minutes))
        case "stopwatch": island?.startStopwatch()
        case "play-pause": nowPlaying.togglePlayPause()
        case "next": nowPlaying.nextTrack()
        case "previous": nowPlaying.previousTrack()
        case "toggle": island?.toggleFromKeyboard()
        case "downloads": island?.toggleFromKeyboard(tab: .downloads)
        case "dashboard": island?.toggleFromKeyboard(tab: .dashboard)
        case "settings":
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "download":
            // notch://download?url=https%3A%2F%2F…  (optionally &quality=audio|p720|p1080|best)
            guard let link = query.first(where: { $0.name == "url" })?.value else { return }
            let quality = query.first { $0.name == "quality" }?.value.flatMap(DownloadQuality.init(rawValue:))
            downloads.download(link, quality: quality)
        case "collapse": displayManager?.coordinators.forEach { $0.collapse() }
        default: NSLog("Notch: unknown link \(url.absoluteString)")
        }
    }
}

/// Observable so Settings › Shortcuts can show "in use by another app".
@Observable
final class HotkeyStatus {
    var failed: Set<String> = []
}
