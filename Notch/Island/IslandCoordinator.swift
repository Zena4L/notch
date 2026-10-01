import AppKit
import Observation
import SwiftUI

/// What one display's island shows. Each display gets its own coordinator; the
/// services (music, timers, downloads…) are shared, and DisplayManager fans events out.
@Observable
final class IslandCoordinator {
    var notchSize = CGSize(width: 190, height: 37)
    var hasNotch = true
    var tab: IslandTab = .downloads
    /// Which timer the Timer tab shows when both are running.
    var timerFocus: Activity = .countdown
    /// The Downloads link field has keyboard focus, so don't collapse when the pointer leaves.
    var isTyping = false

    private(set) var isExpanded = false
    private(set) var peek: Peek?
    /// A full-screen app covers this display (set by DisplayManager).
    var isFullScreen = false
    /// The pointer is over the island but hover doesn't expand it, so we show the song title instead.
    private(set) var showsHoverTitle = false
    /// Bumped each time the pointer arrives, to play the hover bounce.
    private(set) var hoverPulse = 0

    let settings: SettingsStore
    let battery: BatteryService
    let timers: TimerService
    let nowPlaying: NowPlayingService
    let downloads: DownloadService
    let calendar: CalendarService
    let lyrics: LyricsService
    let stats: SystemStatsService
    let weather: WeatherService
    let clipboard: ClipboardService

    /// Everything ongoing right now, in the user's priority order (Settings › Activities).
    var runningActivities: [Activity] {
        settings.activityOrder.filter { activity in
            switch activity {
            case .music: settings.nowPlayingEnabled && nowPlaying.isActive
            case .countdown: timers.countdown != nil
            case .stopwatch: timers.stopwatch != nil
            case .download: settings.downloadsEnabled && downloads.activeItem != nil
            }
        }
    }

    /// The running activities allowed in the collapsed island.
    var activities: [Activity] {
        runningActivities.filter { activity in
            switch activity {
            case .music: settings.musicInCompact
            case .countdown, .stopwatch: settings.timersInCompact
            case .download: settings.downloadsInCompact
            }
        }
    }

    /// Tabs for the features that are turned on in Settings › Activities.
    var availableTabs: [IslandTab] {
        var tabs: [IslandTab] = []
        if settings.dashboardEnabled { tabs.append(.dashboard) }
        if settings.nowPlayingEnabled { tabs.append(.nowPlaying) }
        if settings.downloadsEnabled { tabs.append(.downloads) }
        if settings.timersEnabled || focusedTimer != nil { tabs.append(.timer) }
        return tabs
    }

    /// Lyrics is part of the player (the 💬 button), not a tab of its own.
    var lyricsAvailable: Bool { settings.nowPlayingEnabled && settings.lyricsEnabled }
    var showsLyrics: Bool { isExpanded && tab == .lyrics }
    /// Remembers that lyrics were left open, so the player reopens on them — like Apple Music.
    @ObservationIgnored private var prefersLyrics = false

    func toggleLyrics() {
        guard lyricsAvailable else { return }
        tab = tab == .lyrics ? .nowPlaying : .lyrics
        prefersLyrics = tab == .lyrics
    }

    var state: IslandState {
        if isFullScreen {
            switch settings.fullScreenMode {
            case .hide: return .hidden
            case .hideWhenIdle where !isExpanded && peek == nil && activities.isEmpty: return .hidden
            default: break
            }
        }
        if isExpanded { return .expanded(tab == .lyrics && !lyricsAvailable ? .nowPlaying : tab) }
        if let peek { return .peek(peek) }
        let activities = activities
        switch activities.count {
        case 0: return .idle
        case 1: return .compact(activities[0])
        default: return settings.showSplitBubble ? .split(activities[0], activities[1]) : .compact(activities[0])
        }
    }

    /// The waveform and glow colour: the artwork's, or the design's default coral.
    var waveformTint: Color {
        settings.tintWithArtwork ? nowPlaying.tint : NowPlayingService.defaultTint
    }

    var layoutOptions: IslandState.LayoutOptions {
        IslandState.LayoutOptions(
            compactStyle: settings.compactStyle, expandedScale: settings.expandedSize.scale, dashboardRows: dashboardRows
        )
    }

    var dashboardRows: Int {
        DashboardLayout.rows(settings.dashboardWidgets, maxRows: settings.dashboardMaxRows).count
    }

    var metrics: IslandState.Metrics { state.metrics(notch: notchSize, hasNotch: hasNotch, options: layoutOptions) }

    /// The timer the Timer tab should show, or nil to show the presets.
    var focusedTimer: Activity? {
        let timers = runningActivities.filter { $0 == .countdown || $0 == .stopwatch }
        return timers.contains(timerFocus) ? timerFocus : timers.first
    }

    /// Called when a click or shortcut expands the island, so the panel can take keyboard focus (for Esc).
    @ObservationIgnored var onFocusRequest: (() -> Void)?
    @ObservationIgnored var onCollapse: (() -> Void)?

    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var peekTask: Task<Void, Never>?

    init(
        settings: SettingsStore, battery: BatteryService, timers: TimerService,
        nowPlaying: NowPlayingService, downloads: DownloadService, calendar: CalendarService,
        lyrics: LyricsService = LyricsService(),
        stats: SystemStatsService? = nil, weather: WeatherService? = nil, clipboard: ClipboardService? = nil
    ) {
        self.settings = settings
        self.battery = battery
        self.timers = timers
        self.nowPlaying = nowPlaying
        self.downloads = downloads
        self.calendar = calendar
        self.lyrics = lyrics
        self.stats = stats ?? SystemStatsService(settings: settings)
        self.weather = weather ?? WeatherService(settings: settings)
        self.clipboard = clipboard ?? ClipboardService(settings: settings)
    }

    // MARK: Pointer

    /// `focus` is set when the cursor entered over the split bubble.
    func pointerEntered(focus: Activity? = nil) {
        hoverTask?.cancel()
        if settings.bounceOnHover, !isExpanded, state != .hidden { hoverPulse += 1 }
        // Hovering a peek with buttons (Join, Show, Retry) holds it open instead of expanding.
        if peek?.isInteractive == true {
            peekTask?.cancel()
            return
        }
        guard settings.expandOnHover else {
            showsHoverTitle = settings.titleOnHover && isMusicPrimary
            return
        }
        guard !isExpanded else { return }
        let delay = Duration.milliseconds(settings.hoverDelay)
        hoverTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            expand(focus: focus)
        }
    }

    func pointerExited() {
        hoverTask?.cancel()
        showsHoverTitle = false
        if peek?.isInteractive == true {
            dismissPeek(after: .seconds(2))
            return
        }
        guard isExpanded else { return }
        hoverTask = Task {
            try? await Task.sleep(for: Theme.hoverLeaveDelay)
            // Don't collapse mid-drag (a file being dragged out) or while typing a link.
            while NSEvent.pressedMouseButtons != 0 || isTyping {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            collapse()
        }
    }

    func clicked(focus: Activity? = nil) {
        hoverTask?.cancel()
        expand(focus: focus)
        onFocusRequest?()
    }

    // MARK: State changes

    func expand(tab requestedTab: IslandTab? = nil, focus: Activity? = nil) {
        guard !isExpanded else { return }
        tab = chooseTab(requested: requestedTab, focus: focus)
        if let focus, focus == .countdown || focus == .stopwatch { timerFocus = focus }
        if tab == .downloads { downloads.pruneMissing() }

        isExpanded = true
        if settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// Like the design: music first, then a running timer, otherwise Downloads.
    private func chooseTab(requested: IslandTab?, focus: Activity?) -> IslandTab {
        let available = availableTabs
        let preferred: IslandTab
        if let requested {
            preferred = requested
        } else if focus == .music {
            preferred = .nowPlaying
        } else if focus == .download {
            preferred = .downloads
        } else if focus != nil {
            preferred = .timer
        } else if settings.nowPlayingEnabled, nowPlaying.track != nil {
            preferred = .nowPlaying
        } else if focusedTimer != nil {
            preferred = .timer
        } else if downloads.activeItem != nil {
            preferred = .downloads
        } else if settings.dashboardEnabled, settings.dashboardOnIdle {
            preferred = .dashboard
        } else {
            preferred = .downloads
        }
        if preferred == .nowPlaying, prefersLyrics, lyricsAvailable, available.contains(.nowPlaying) { return .lyrics }
        if preferred == .lyrics, lyricsAvailable { return .lyrics }
        return available.contains(preferred) ? preferred : (available.first ?? preferred)
    }

    func collapse() {
        hoverTask?.cancel()
        guard isExpanded else { return }
        isExpanded = false
        isTyping = false
        onCollapse?()
    }

    /// ⌥⌘N, or ⌥⌘D with `tab: .downloads`.
    func toggleFromKeyboard(tab requestedTab: IslandTab? = nil) {
        if isExpanded, requestedTab == nil || requestedTab == tab {
            collapse()
        } else if isExpanded, let requestedTab {
            tab = requestedTab
        } else {
            expand(tab: requestedTab)
            onFocusRequest?()
        }
    }

    /// `force` skips the Settings checks, for Settings › Try it.
    func show(_ peek: Peek, force: Bool = false) {
        if !force {
            guard allows(peek) else { return }
        }
        self.peek = peek
        dismissPeek(after: peek.duration)
    }

    private func allows(_ peek: Peek) -> Bool {
        switch peek {
        case .charging: settings.batteryEnabled && settings.chargingPeek
        case .unplugged: settings.batteryEnabled && settings.unpluggedPeek
        case .lowBattery: settings.batteryEnabled && settings.lowBatteryWarnings
        case .trackChange: settings.nowPlayingEnabled && settings.trackChangePeek
        case .meeting: settings.calendarEnabled
        case .hud: settings.hudEnabled
        case .downloadDone, .downloadFailed: settings.downloadsEnabled && settings.downloadPeek
        case .timerDone: true
        }
    }

    /// Closes the current peek straight away (e.g. after its button was used).
    func dismissPeek() {
        peekTask?.cancel()
        peek = nil
    }

    private func dismissPeek(after delay: Duration) {
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.peek = nil
        }
    }

    private var isMusicPrimary: Bool {
        switch state {
        case .compact(.music), .split(.music, _): true
        default: false
        }
    }

    /// Opens the meeting link and closes the peek.
    func joinMeeting() {
        if let url = calendar.meeting?.joinURL { NSWorkspace.shared.open(url) }
        peekTask?.cancel()
        peek = nil
    }

    // MARK: Timers

    func startCountdown(minutes: Int) {
        guard settings.timersEnabled else { return }
        timers.startCountdown(seconds: TimeInterval(minutes * 60))
        timerFocus = .countdown
    }

    func startQuickTimer() {
        startCountdown(minutes: settings.quickTimerMinutes)
    }

    func startStopwatch() {
        guard settings.timersEnabled else { return }
        timers.startStopwatch()
        timerFocus = .stopwatch
    }
}
