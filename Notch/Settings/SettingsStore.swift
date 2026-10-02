import Foundation
import Observation
import ServiceManagement

extension Notification.Name {
    static let settingsDidChange = Notification.Name("NotchSettingsDidChange")
    /// Posted by Settings › Try it, with the peek's name as the object.
    static let previewPeek = Notification.Name("NotchPreviewPeek")
}

enum DisplayMode: String, CaseIterable {
    case builtIn, all, withCursor
}

enum FullScreenMode: String, CaseIterable {
    case show, hideWhenIdle, hide
}

enum IslandMaterial: String, CaseIterable {
    case black, hybrid, glass
}

enum CompactStyle: String, CaseIterable {
    /// Content in the "ears" either side of the notch.
    case beside
    /// A band below the camera, so the island never covers menu bar items.
    case below
}

enum ExpandedSize: String, CaseIterable {
    case compact, regular, large

    var scale: CGFloat {
        switch self {
        case .compact: 0.88
        case .regular: 1
        case .large: 1.12
        }
    }
}

enum DownloadQuality: String, CaseIterable, Codable {
    case best, p1080, p720, audio
}

/// Broad file types, for browser downloads Notch takes over and for icons in the Downloads tab.
enum FileKind: String, CaseIterable, Codable {
    case document, image, archive, installer, media, other

    var extensions: Set<String> {
        switch self {
        case .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "csv", "epub", "md", "odt", "ods", "odp"]
        case .image: ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "svg", "tif", "tiff", "bmp", "avif"]
        case .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]
        case .installer: ["dmg", "pkg", "app", "iso", "mpkg"]
        case .media: ["mp4", "mov", "mkv", "webm", "avi", "m4v", "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus"]
        case .other: []
        }
    }

    /// By extension first (".tar.gz" counts as an archive), then by MIME type.
    static func of(filename: String, mime: String? = nil) -> FileKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let kind = allCases.first(where: { $0.extensions.contains(ext) }) { return kind }
        let mime = (mime ?? "").lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return .media }
        if mime.hasPrefix("text/") && mime != "text/html" { return .document }
        switch mime {
        case "application/pdf", "application/msword", "application/rtf", "application/epub+zip": return .document
        case "application/zip", "application/x-zip-compressed", "application/gzip", "application/x-tar",
             "application/x-7z-compressed", "application/vnd.rar", "application/x-bzip2", "application/x-xz": return .archive
        case "application/x-apple-diskimage", "application/x-iso9660-image", "application/vnd.apple.installer+xml": return .installer
        default:
            if mime.hasPrefix("application/vnd.openxmlformats-officedocument") || mime.hasPrefix("application/vnd.ms-")
                || mime.hasPrefix("application/vnd.oasis.opendocument") { return .document }
            return .other
        }
    }
}

enum VideoCompatibility: String, CaseIterable {
    /// H.264 + AAC in MP4, up to 1080p — plays everywhere, including QuickTime and iPhone.
    case quickTime
    /// Whatever's best (VP9/AV1, up to 4K) — may need VLC or IINA to play.
    case highest
}

enum FileNaming: String, CaseIterable {
    case title, titleAndID
}

enum CookieBrowser: String, CaseIterable {
    case none, safari, chrome, firefox, brave, edge
}

enum MenuBarIconStyle: String, CaseIterable {
    /// A tiny MacBook screen with the island hanging from the top (drawn by Notch).
    case island
    /// Just the island pill.
    case pill
    /// The island with a waveform, matching the app icon.
    case waveform
    /// Shows what's happening: bars while music plays, a timer while counting down, an arrow while downloading.
    case live
}

enum TemperatureUnit: String, CaseIterable {
    case automatic, celsius, fahrenheit
}

enum DashboardWidget: String, CaseIterable, Codable {
    case cpu, memory, storage, network, battery, weather, calendar, clipboard

    static let defaults: [DashboardWidget] = [.cpu, .memory, .battery, .storage, .weather, .calendar]

    /// Slots in a 4-slot row.
    var width: Int {
        switch self {
        case .weather, .calendar, .clipboard: 2
        default: 1
        }
    }
}

/// A global shortcut in Carbon terms. `keyCode < 0` means "not set".
struct KeyShortcut: Equatable {
    var keyCode: Int
    var modifiers: Int

    static let none = KeyShortcut(keyCode: -1, modifiers: 0)
    var isSet: Bool { keyCode >= 0 }
}

/// Carbon's ⌥⌘ modifier mask.
private let cmdOption = 256 | 2048

/// User preferences, persisted in UserDefaults. Views bind to it directly;
/// AppKit code listens for `.settingsDidChange`.
///
/// Loading is tolerant: missing, unknown or out-of-range values fall back to the defaults.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    // MARK: General
    var displayMode: DisplayMode = .builtIn { didSet { persist("displayMode", displayMode.rawValue) } }
    var fullScreenMode: FullScreenMode = .hideWhenIdle { didSet { persist("fullScreenMode", fullScreenMode.rawValue) } }
    var hideWhileSharing: Bool = false { didSet { persist("hideWhileSharing", hideWhileSharing) } }
    var expandOnHover: Bool = true { didSet { persist("expandOnHover", expandOnHover) } }
    /// Milliseconds the cursor must rest on the island before it expands.
    var hoverDelay: Int = 150 { didSet { persist("hoverDelay", hoverDelay) } }
    var haptics: Bool = true { didSet { persist("haptics", haptics) } }

    // MARK: Appearance
    /// Black matches the design guide; Hybrid and Glass use Liquid Glass on macOS 26+.
    var material: IslandMaterial = .black { didSet { persist("material", material.rawValue) } }
    /// When hidden, open Settings from the gear in the expanded island.
    var showMenuBarIcon: Bool = true { didSet { persist("showMenuBarIcon", showMenuBarIcon) } }
    var menuBarIconStyle: MenuBarIconStyle = .island { didSet { persist("menuBarIconStyle", menuBarIconStyle.rawValue) } }
    var compactStyle: CompactStyle = .beside { didSet { persist("compactStyle", compactStyle.rawValue) } }
    var expandedSize: ExpandedSize = .regular { didSet { persist("expandedSize", expandedSize.rawValue) } }
    var tintWithArtwork: Bool = true { didSet { persist("tintWithArtwork", tintWithArtwork) } }
    /// A soft glow in the artwork's colour behind the island while music plays.
    var artworkGlow: Bool = true { didSet { persist("artworkGlow", artworkGlow) } }
    var shadowWhenExpanded: Bool = true { didSet { persist("shadowWhenExpanded", shadowWhenExpanded) } }
    var bounceOnHover: Bool = true { didSet { persist("bounceOnHover", bounceOnHover) } }
    /// When hover doesn't expand the island, show the song title under it instead.
    var titleOnHover: Bool = true { didSet { persist("titleOnHover", titleOnHover) } }

    // MARK: Activities
    var nowPlayingEnabled: Bool = true { didSet { persist("nowPlayingEnabled", nowPlayingEnabled) } }
    var batteryEnabled: Bool = true { didSet { persist("batteryEnabled", batteryEnabled) } }
    var timersEnabled: Bool = true { didSet { persist("timersEnabled", timersEnabled) } }
    var downloadsEnabled: Bool = true { didSet { persist("downloadsEnabled", downloadsEnabled) } }
    /// The user's choice. Calendar also needs access, which macOS controls.
    var calendarEnabled: Bool = false { didSet { persist("calendarEnabled", calendarEnabled) } }
    /// Priority of ongoing activities in the collapsed island, highest first.
    var activityOrder: [Activity] = Activity.allCases { didSet { persist("activityOrder", activityOrder.map(\.rawValue)) } }
    var musicInCompact: Bool = true { didSet { persist("musicInCompact", musicInCompact) } }
    var timersInCompact: Bool = true { didSet { persist("timersInCompact", timersInCompact) } }
    /// Show a second ongoing activity in a detached bubble.
    var showSplitBubble: Bool = true { didSet { persist("showSplitBubble", showSplitBubble) } }
    /// Show the Lyrics tab. Lyrics are looked up on lrclib.net only when you open it.
    var lyricsEnabled: Bool = true { didSet { persist("lyricsEnabled", lyricsEnabled) } }
    var trackChangePeek: Bool = true { didSet { persist("trackChangePeek", trackChangePeek) } }
    /// Seconds the island keeps showing music after you pause.
    var pausedGraceSeconds: Int = 30 { didSet { persist("pausedGraceSeconds", pausedGraceSeconds) } }
    var chargingPeek: Bool = true { didSet { persist("chargingPeek", chargingPeek) } }
    var unpluggedPeek: Bool = false { didSet { persist("unpluggedPeek", unpluggedPeek) } }
    var lowBatteryWarnings: Bool = true { didSet { persist("lowBatteryWarnings", lowBatteryWarnings) } }
    /// Length of the timer the quick-timer shortcut starts.
    var quickTimerMinutes: Int = 5 { didSet { persist("quickTimerMinutes", quickTimerMinutes) } }
    /// Buttons on the Timer tab, in minutes.
    var timerPresets: [Int] = [1, 5, 10, 25] { didSet { persist("timerPresets", timerPresets) } }
    /// A system sound name, or "" for silence.
    var timerSound: String = "Glass" { didSet { persist("timerSound", timerSound) } }
    var downloadsInCompact: Bool = true { didSet { persist("downloadsInCompact", downloadsInCompact) } }
    var downloadPeek: Bool = true { didSet { persist("downloadPeek", downloadPeek) } }
    /// Where downloads go. Empty means your Downloads folder.
    var downloadFolder: String = "" { didSet { persist("downloadFolder", downloadFolder) } }
    var downloadQuality: DownloadQuality = .best { didSet { persist("downloadQuality", downloadQuality.rawValue) } }
    var videoCompatibility: VideoCompatibility = .quickTime { didSet { persist("videoCompatibility", videoCompatibility.rawValue) } }
    var fileNaming: FileNaming = .title { didSet { persist("fileNaming", fileNaming.rawValue) } }
    /// Sign-in cookies for posts that need an account (X, age-restricted videos).
    var cookieBrowser: CookieBrowser = .none { didSet { persist("cookieBrowser", cookieBrowser.rawValue) } }
    /// Keep yt-dlp current; sites change often.
    var autoUpdateDownloader: Bool = true { didSet { persist("autoUpdateDownloader", autoUpdateDownloader) } }
    /// Show downloads Safari, Chrome and other browsers make in the island. No extension needed.
    var followBrowserDownloads: Bool = true { didSet { persist("followBrowserDownloads", followBrowserDownloads) } }
    /// Let the Notch browser extension hand over downloads you click in Chrome or Firefox.
    var browserTakeover: Bool = false { didSet { persist("browserTakeover", browserTakeover) } }
    /// File types Notch takes over; the browser keeps the rest.
    var takeoverKinds: Set<FileKind> = Set(FileKind.allCases) { didSet { persist("takeoverKinds", takeoverKinds.map(\.rawValue).sorted()) } }
    /// Minutes before an event starts that the reminder appears.
    var meetingLeadMinutes: Int = 5 { didSet { persist("meetingLeadMinutes", meetingLeadMinutes) } }
    var meetingAlertAtStart: Bool = false { didSet { persist("meetingAlertAtStart", meetingAlertAtStart) } }
    /// Calendars the user switched off, by identifier.
    var excludedCalendarIDs: [String] = [] { didSet { persist("excludedCalendarIDs", excludedCalendarIDs) } }
    /// Replace the system volume and brightness overlay. Needs Accessibility access.
    var hudEnabled: Bool = false { didSet { persist("hudEnabled", hudEnabled) } }
    var hudVolume: Bool = true { didSet { persist("hudVolume", hudVolume) } }
    var hudBrightness: Bool = true { didSet { persist("hudBrightness", hudBrightness) } }
    /// How many key presses go from silent to full volume (or dark to full brightness).
    var hudSteps: Int = 16 { didSet { persist("hudSteps", hudSteps) } }

    // MARK: Dashboard
    var dashboardEnabled: Bool = true { didSet { persist("dashboardEnabled", dashboardEnabled) } }
    /// Open the dashboard when nothing else is going on (no music or timers).
    var dashboardOnIdle: Bool = true { didSet { persist("dashboardOnIdle", dashboardOnIdle) } }
    /// Widgets that are on, in order.
    var dashboardWidgets: [DashboardWidget] = DashboardWidget.defaults { didSet { persist("dashboardWidgets", dashboardWidgets.map(\.rawValue)) } }
    var dashboardMaxRows: Int = 2 { didSet { persist("dashboardMaxRows", dashboardMaxRows) } }
    /// Seconds between CPU, memory and network readings, only while the dashboard is open.
    var statsInterval: Int = 2 { didSet { persist("statsInterval", statsInterval) } }
    var weatherUsesLocation: Bool = false { didSet { persist("weatherUsesLocation", weatherUsesLocation) } }
    var weatherCity: String = "" { didSet { persist("weatherCity", weatherCity) } }
    var temperatureUnit: TemperatureUnit = .automatic { didSet { persist("temperatureUnit", temperatureUnit.rawValue) } }
    /// Off by default: keeps recent copied text in memory only.
    var clipboardHistory: Bool = false { didSet { persist("clipboardHistory", clipboardHistory) } }
    var clipboardLimit: Int = 20 { didSet { persist("clipboardLimit", clipboardLimit) } }
    /// Skip passwords copied from password managers.
    var clipboardIgnoreConcealed: Bool = true { didSet { persist("clipboardIgnoreConcealed", clipboardIgnoreConcealed) } }

    // MARK: Shortcuts
    /// ⌥⌘N
    var toggleShortcut: KeyShortcut = KeyShortcut(keyCode: 45, modifiers: cmdOption) { didSet { persist("toggleShortcut", [toggleShortcut.keyCode, toggleShortcut.modifiers]) } }
    /// ⌥⌘T
    var timerShortcut: KeyShortcut = KeyShortcut(keyCode: 17, modifiers: cmdOption) { didSet { persist("timerShortcut", [timerShortcut.keyCode, timerShortcut.modifiers]) } }
    /// ⌥⌘P
    var playPauseShortcut: KeyShortcut = KeyShortcut(keyCode: 35, modifiers: cmdOption) { didSet { persist("playPauseShortcut", [playPauseShortcut.keyCode, playPauseShortcut.modifiers]) } }
    /// ⌥⌘I
    var dashboardShortcut: KeyShortcut = KeyShortcut(keyCode: 34, modifiers: cmdOption) { didSet { persist("dashboardShortcut", [dashboardShortcut.keyCode, dashboardShortcut.modifiers]) } }
    /// ⌥⌘D
    var downloadsShortcut: KeyShortcut = KeyShortcut(keyCode: 2, modifiers: cmdOption) { didSet { persist("downloadsShortcut", [downloadsShortcut.keyCode, downloadsShortcut.modifiers]) } }

    /// Backed by the system's login item list rather than UserDefaults.
    var openAtLogin: Bool {
        get {
            access(keyPath: \.openAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.openAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Notch: couldn't update login item: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Storage

    @ObservationIgnored private let defaults: UserDefaults
    /// Suppresses saving while values are being loaded.
    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migrate the Phase 1 on/off setting to the three-way choice.
        if defaults.object(forKey: "fullScreenMode") == nil, defaults.object(forKey: "hideInFullScreen") != nil {
            fullScreenMode = defaults.bool(forKey: "hideInFullScreen") ? .hideWhenIdle : .show
        }
        load()
    }

    /// Settings › General › Reset to Defaults. Doesn't touch your downloads or the login item.
    func resetToDefaults() {
        let fresh = SettingsStore(defaults: UserDefaults(suiteName: "NotchDefaults-\(UUID())")!)
        isLoading = true
        displayMode = fresh.displayMode
        fullScreenMode = fresh.fullScreenMode
        hideWhileSharing = fresh.hideWhileSharing
        expandOnHover = fresh.expandOnHover
        hoverDelay = fresh.hoverDelay
        haptics = fresh.haptics
        material = fresh.material
        showMenuBarIcon = fresh.showMenuBarIcon
        menuBarIconStyle = fresh.menuBarIconStyle
        compactStyle = fresh.compactStyle
        expandedSize = fresh.expandedSize
        tintWithArtwork = fresh.tintWithArtwork
        artworkGlow = fresh.artworkGlow
        shadowWhenExpanded = fresh.shadowWhenExpanded
        bounceOnHover = fresh.bounceOnHover
        titleOnHover = fresh.titleOnHover
        nowPlayingEnabled = fresh.nowPlayingEnabled
        batteryEnabled = fresh.batteryEnabled
        timersEnabled = fresh.timersEnabled
        downloadsEnabled = fresh.downloadsEnabled
        calendarEnabled = fresh.calendarEnabled
        activityOrder = fresh.activityOrder
        musicInCompact = fresh.musicInCompact
        timersInCompact = fresh.timersInCompact
        showSplitBubble = fresh.showSplitBubble
        lyricsEnabled = fresh.lyricsEnabled
        trackChangePeek = fresh.trackChangePeek
        pausedGraceSeconds = fresh.pausedGraceSeconds
        chargingPeek = fresh.chargingPeek
        unpluggedPeek = fresh.unpluggedPeek
        lowBatteryWarnings = fresh.lowBatteryWarnings
        quickTimerMinutes = fresh.quickTimerMinutes
        timerPresets = fresh.timerPresets
        timerSound = fresh.timerSound
        downloadsInCompact = fresh.downloadsInCompact
        downloadPeek = fresh.downloadPeek
        downloadFolder = fresh.downloadFolder
        downloadQuality = fresh.downloadQuality
        videoCompatibility = fresh.videoCompatibility
        fileNaming = fresh.fileNaming
        cookieBrowser = fresh.cookieBrowser
        autoUpdateDownloader = fresh.autoUpdateDownloader
        followBrowserDownloads = fresh.followBrowserDownloads
        browserTakeover = fresh.browserTakeover
        takeoverKinds = fresh.takeoverKinds
        meetingLeadMinutes = fresh.meetingLeadMinutes
        meetingAlertAtStart = fresh.meetingAlertAtStart
        excludedCalendarIDs = fresh.excludedCalendarIDs
        hudEnabled = fresh.hudEnabled
        hudVolume = fresh.hudVolume
        hudBrightness = fresh.hudBrightness
        hudSteps = fresh.hudSteps
        dashboardEnabled = fresh.dashboardEnabled
        dashboardOnIdle = fresh.dashboardOnIdle
        dashboardWidgets = fresh.dashboardWidgets
        dashboardMaxRows = fresh.dashboardMaxRows
        statsInterval = fresh.statsInterval
        weatherUsesLocation = fresh.weatherUsesLocation
        weatherCity = fresh.weatherCity
        temperatureUnit = fresh.temperatureUnit
        clipboardHistory = fresh.clipboardHistory
        clipboardLimit = fresh.clipboardLimit
        clipboardIgnoreConcealed = fresh.clipboardIgnoreConcealed
        toggleShortcut = fresh.toggleShortcut
        timerShortcut = fresh.timerShortcut
        playPauseShortcut = fresh.playPauseShortcut
        dashboardShortcut = fresh.dashboardShortcut
        downloadsShortcut = fresh.downloadsShortcut
        isLoading = false
        for key in Self.keys { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    private static let keys = [
        "displayMode",
        "fullScreenMode",
        "hideWhileSharing",
        "expandOnHover",
        "hoverDelay",
        "haptics",
        "material",
        "showMenuBarIcon",
        "menuBarIconStyle",
        "compactStyle",
        "expandedSize",
        "tintWithArtwork",
        "artworkGlow",
        "shadowWhenExpanded",
        "bounceOnHover",
        "titleOnHover",
        "nowPlayingEnabled",
        "batteryEnabled",
        "timersEnabled",
        "downloadsEnabled",
        "calendarEnabled",
        "activityOrder",
        "musicInCompact",
        "timersInCompact",
        "showSplitBubble",
        "lyricsEnabled",
        "trackChangePeek",
        "pausedGraceSeconds",
        "chargingPeek",
        "unpluggedPeek",
        "lowBatteryWarnings",
        "quickTimerMinutes",
        "timerPresets",
        "timerSound",
        "downloadsInCompact",
        "downloadPeek",
        "downloadFolder",
        "downloadQuality",
        "videoCompatibility",
        "fileNaming",
        "cookieBrowser",
        "autoUpdateDownloader",
        "followBrowserDownloads",
        "browserTakeover",
        "takeoverKinds",
        "meetingLeadMinutes",
        "meetingAlertAtStart",
        "excludedCalendarIDs",
        "hudEnabled",
        "hudVolume",
        "hudBrightness",
        "hudSteps",
        "dashboardEnabled",
        "dashboardOnIdle",
        "dashboardWidgets",
        "dashboardMaxRows",
        "statsInterval",
        "weatherUsesLocation",
        "weatherCity",
        "temperatureUnit",
        "clipboardHistory",
        "clipboardLimit",
        "clipboardIgnoreConcealed",
        "toggleShortcut",
        "timerShortcut",
        "playPauseShortcut",
        "dashboardShortcut",
        "downloadsShortcut",
    ]

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let d = defaults
        if let raw = d.string(forKey: "displayMode"), let value = DisplayMode(rawValue: raw) { displayMode = value }
        if let raw = d.string(forKey: "fullScreenMode"), let value = FullScreenMode(rawValue: raw) { fullScreenMode = value }
        if d.object(forKey: "hideWhileSharing") != nil { hideWhileSharing = d.bool(forKey: "hideWhileSharing") }
        if d.object(forKey: "expandOnHover") != nil { expandOnHover = d.bool(forKey: "expandOnHover") }
        if d.object(forKey: "hoverDelay") != nil { hoverDelay = (0...1000).clamp(d.integer(forKey: "hoverDelay")) }
        if d.object(forKey: "haptics") != nil { haptics = d.bool(forKey: "haptics") }
        if let raw = d.string(forKey: "material"), let value = IslandMaterial(rawValue: raw) { material = value }
        if d.object(forKey: "showMenuBarIcon") != nil { showMenuBarIcon = d.bool(forKey: "showMenuBarIcon") }
        if let raw = d.string(forKey: "menuBarIconStyle"), let value = MenuBarIconStyle(rawValue: raw) { menuBarIconStyle = value }
        if let raw = d.string(forKey: "compactStyle"), let value = CompactStyle(rawValue: raw) { compactStyle = value }
        if let raw = d.string(forKey: "expandedSize"), let value = ExpandedSize(rawValue: raw) { expandedSize = value }
        if d.object(forKey: "tintWithArtwork") != nil { tintWithArtwork = d.bool(forKey: "tintWithArtwork") }
        if d.object(forKey: "artworkGlow") != nil { artworkGlow = d.bool(forKey: "artworkGlow") }
        if d.object(forKey: "shadowWhenExpanded") != nil { shadowWhenExpanded = d.bool(forKey: "shadowWhenExpanded") }
        if d.object(forKey: "bounceOnHover") != nil { bounceOnHover = d.bool(forKey: "bounceOnHover") }
        if d.object(forKey: "titleOnHover") != nil { titleOnHover = d.bool(forKey: "titleOnHover") }
        if d.object(forKey: "nowPlayingEnabled") != nil { nowPlayingEnabled = d.bool(forKey: "nowPlayingEnabled") }
        if d.object(forKey: "batteryEnabled") != nil { batteryEnabled = d.bool(forKey: "batteryEnabled") }
        if d.object(forKey: "timersEnabled") != nil { timersEnabled = d.bool(forKey: "timersEnabled") }
        if d.object(forKey: "downloadsEnabled") != nil { downloadsEnabled = d.bool(forKey: "downloadsEnabled") }
        if d.object(forKey: "calendarEnabled") != nil { calendarEnabled = d.bool(forKey: "calendarEnabled") }
        if let raw = d.stringArray(forKey: "activityOrder") {
            // Keep known activities in the saved order, then append any that are new.
            var order: [Activity] = []
            for a in raw.compactMap(Activity.init(rawValue:)) where !order.contains(a) { order.append(a) }
            activityOrder = order + Activity.allCases.filter { !order.contains($0) }
        }
        if d.object(forKey: "musicInCompact") != nil { musicInCompact = d.bool(forKey: "musicInCompact") }
        if d.object(forKey: "timersInCompact") != nil { timersInCompact = d.bool(forKey: "timersInCompact") }
        if d.object(forKey: "showSplitBubble") != nil { showSplitBubble = d.bool(forKey: "showSplitBubble") }
        if d.object(forKey: "lyricsEnabled") != nil { lyricsEnabled = d.bool(forKey: "lyricsEnabled") }
        if d.object(forKey: "trackChangePeek") != nil { trackChangePeek = d.bool(forKey: "trackChangePeek") }
        if d.object(forKey: "pausedGraceSeconds") != nil { pausedGraceSeconds = (0...3600).clamp(d.integer(forKey: "pausedGraceSeconds")) }
        if d.object(forKey: "chargingPeek") != nil { chargingPeek = d.bool(forKey: "chargingPeek") }
        if d.object(forKey: "unpluggedPeek") != nil { unpluggedPeek = d.bool(forKey: "unpluggedPeek") }
        if d.object(forKey: "lowBatteryWarnings") != nil { lowBatteryWarnings = d.bool(forKey: "lowBatteryWarnings") }
        if d.object(forKey: "quickTimerMinutes") != nil { quickTimerMinutes = (1...180).clamp(d.integer(forKey: "quickTimerMinutes")) }
        if let value = d.array(forKey: "timerPresets") as? [Int] {
            let valid = value.filter { (1...600).contains($0) }
            if !valid.isEmpty { timerPresets = Array(valid.prefix(6)) }
        }
        if let value = d.string(forKey: "timerSound") { timerSound = value }
        if d.object(forKey: "downloadsInCompact") != nil { downloadsInCompact = d.bool(forKey: "downloadsInCompact") }
        if d.object(forKey: "downloadPeek") != nil { downloadPeek = d.bool(forKey: "downloadPeek") }
        if let value = d.string(forKey: "downloadFolder") { downloadFolder = value }
        if let raw = d.string(forKey: "downloadQuality"), let value = DownloadQuality(rawValue: raw) { downloadQuality = value }
        if let raw = d.string(forKey: "videoCompatibility"), let value = VideoCompatibility(rawValue: raw) { videoCompatibility = value }
        if let raw = d.string(forKey: "fileNaming"), let value = FileNaming(rawValue: raw) { fileNaming = value }
        if let raw = d.string(forKey: "cookieBrowser"), let value = CookieBrowser(rawValue: raw) { cookieBrowser = value }
        if d.object(forKey: "autoUpdateDownloader") != nil { autoUpdateDownloader = d.bool(forKey: "autoUpdateDownloader") }
        if d.object(forKey: "followBrowserDownloads") != nil { followBrowserDownloads = d.bool(forKey: "followBrowserDownloads") }
        if d.object(forKey: "browserTakeover") != nil { browserTakeover = d.bool(forKey: "browserTakeover") }
        if let raw = d.stringArray(forKey: "takeoverKinds") { takeoverKinds = Set(raw.compactMap(FileKind.init(rawValue:))) }
        if d.object(forKey: "meetingLeadMinutes") != nil { meetingLeadMinutes = (1...60).clamp(d.integer(forKey: "meetingLeadMinutes")) }
        if d.object(forKey: "meetingAlertAtStart") != nil { meetingAlertAtStart = d.bool(forKey: "meetingAlertAtStart") }
        if let value = d.stringArray(forKey: "excludedCalendarIDs") { excludedCalendarIDs = value }
        if d.object(forKey: "hudEnabled") != nil { hudEnabled = d.bool(forKey: "hudEnabled") }
        if d.object(forKey: "hudVolume") != nil { hudVolume = d.bool(forKey: "hudVolume") }
        if d.object(forKey: "hudBrightness") != nil { hudBrightness = d.bool(forKey: "hudBrightness") }
        if d.object(forKey: "hudSteps") != nil { hudSteps = (4...64).clamp(d.integer(forKey: "hudSteps")) }
        if d.object(forKey: "dashboardEnabled") != nil { dashboardEnabled = d.bool(forKey: "dashboardEnabled") }
        if d.object(forKey: "dashboardOnIdle") != nil { dashboardOnIdle = d.bool(forKey: "dashboardOnIdle") }
        if let raw = d.stringArray(forKey: "dashboardWidgets") {
            var list: [DashboardWidget] = []
            for w in raw.compactMap(DashboardWidget.init(rawValue:)) where !list.contains(w) { list.append(w) }
            dashboardWidgets = list
        }
        if d.object(forKey: "dashboardMaxRows") != nil { dashboardMaxRows = (1...3).clamp(d.integer(forKey: "dashboardMaxRows")) }
        if d.object(forKey: "statsInterval") != nil { statsInterval = (1...10).clamp(d.integer(forKey: "statsInterval")) }
        if d.object(forKey: "weatherUsesLocation") != nil { weatherUsesLocation = d.bool(forKey: "weatherUsesLocation") }
        if let value = d.string(forKey: "weatherCity") { weatherCity = value }
        if let raw = d.string(forKey: "temperatureUnit"), let value = TemperatureUnit(rawValue: raw) { temperatureUnit = value }
        if d.object(forKey: "clipboardHistory") != nil { clipboardHistory = d.bool(forKey: "clipboardHistory") }
        if d.object(forKey: "clipboardLimit") != nil { clipboardLimit = (5...100).clamp(d.integer(forKey: "clipboardLimit")) }
        if d.object(forKey: "clipboardIgnoreConcealed") != nil { clipboardIgnoreConcealed = d.bool(forKey: "clipboardIgnoreConcealed") }
        if let pair = d.array(forKey: "toggleShortcut") as? [Int], pair.count == 2 { toggleShortcut = KeyShortcut(keyCode: pair[0], modifiers: pair[1]) }
        if let pair = d.array(forKey: "timerShortcut") as? [Int], pair.count == 2 { timerShortcut = KeyShortcut(keyCode: pair[0], modifiers: pair[1]) }
        if let pair = d.array(forKey: "playPauseShortcut") as? [Int], pair.count == 2 { playPauseShortcut = KeyShortcut(keyCode: pair[0], modifiers: pair[1]) }
        if let pair = d.array(forKey: "dashboardShortcut") as? [Int], pair.count == 2 { dashboardShortcut = KeyShortcut(keyCode: pair[0], modifiers: pair[1]) }
        if let pair = d.array(forKey: "downloadsShortcut") as? [Int], pair.count == 2 { downloadsShortcut = KeyShortcut(keyCode: pair[0], modifiers: pair[1]) }
    }

    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsDidChange, object: self, userInfo: [Self.changedKey: key])
    }

    /// userInfo key naming the setting that changed (absent after Reset to Defaults).
    nonisolated static let changedKey = "key"
}

extension Notification {
    /// Whether this settings change touches any of `keys` (always true after a reset).
    nonisolated func affects(_ keys: Set<String>) -> Bool {
        guard let key = userInfo?[SettingsStore.changedKey] as? String else { return true }
        return keys.contains(key)
    }

    nonisolated func affects(suffix: String) -> Bool {
        guard let key = userInfo?[SettingsStore.changedKey] as? String else { return true }
        return key.hasSuffix(suffix)
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
