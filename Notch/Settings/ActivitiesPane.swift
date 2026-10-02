import AppKit
import EventKit
import SwiftUI

/// Settings › Activities: switch each feature on or off and tune how it behaves.
struct ActivitiesPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                ActivityOrderList()
                Toggle("Show music in the collapsed island", isOn: $settings.musicInCompact)
                Toggle("Show timers in the collapsed island", isOn: $settings.timersInCompact)
                Toggle("Show downloads in the collapsed island", isOn: $settings.downloadsInCompact)
                Toggle(isOn: $settings.showSplitBubble) {
                    Text("Show a second activity in a bubble")
                    Text("Otherwise only the top activity shows")
                }
            } header: {
                Text("Collapsed island")
            } footer: {
                Text("The top activity takes the island when several are running.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Ready to use, no permissions needed") {
                Toggle(isOn: $settings.nowPlayingEnabled) {
                    Text("Now Playing")
                    Text("Any app that plays media")
                }
                if settings.nowPlayingEnabled {
                    Toggle(isOn: $settings.lyricsEnabled) {
                        Text("Lyrics button")
                        Text("In the player's controls. Looks up the song on lrclib.net only when you open lyrics")
                    }
                    .padding(.leading, 16)
                    Toggle("Show a peek when the song changes", isOn: $settings.trackChangePeek)
                        .padding(.leading, 16)
                    Picker("After pausing, keep showing music", selection: $settings.pausedGraceSeconds) {
                        Text("Hide immediately").tag(0)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                    .padding(.leading, 16)
                }

                Toggle(isOn: $settings.batteryEnabled) {
                    Text("Battery & charging")
                    Text("Peeks when you plug in or run low")
                }
                if settings.batteryEnabled {
                    Toggle("Show a peek when the charger connects", isOn: $settings.chargingPeek)
                        .padding(.leading, 16)
                    Toggle("Show a peek when the charger disconnects", isOn: $settings.unpluggedPeek)
                        .padding(.leading, 16)
                    Toggle("Warn at 20% and 10%", isOn: $settings.lowBatteryWarnings)
                        .padding(.leading, 16)
                }

                Toggle(isOn: $settings.timersEnabled) {
                    Text("Timers")
                    Text("Start from the island or with ⌥⌘T")
                }
                if settings.timersEnabled {
                    Stepper(value: $settings.quickTimerMinutes, in: 1...120) {
                        Text("⌥⌘T starts a timer for")
                        Text("\(settings.quickTimerMinutes) min")
                    }
                    .padding(.leading, 16)
                    TimerPresetsField(presets: $settings.timerPresets)
                        .padding(.leading, 16)
                    TimerSoundPicker(selection: $settings.timerSound)
                        .padding(.leading, 16)
                }

            }

            DownloadsSettings()
            BrowserDownloadsSettings()

            Section("Needs your permission") {
                CalendarPermissionRows()
                HUDPermissionRows()

                Toggle(isOn: .constant(false)) {
                    Text("Focus")
                    Text("Shows which Focus is on · coming in a later version")
                }
                .disabled(true)
                Toggle(isOn: .constant(false)) {
                    Text("Notifications · Experimental")
                    Text("Mirrors banners into the island · coming in a later version")
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Activities")
    }
}

/// The design's in-place permission flow: Off → explanation with a button →
/// "Waiting for access…" → turns on by itself once access is granted. No relaunch.
private struct CalendarPermissionRows: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(CalendarService.self) private var calendar
    @State private var waitingForSettings = false

    var body: some View {
        @Bindable var settings = settings

        Toggle(isOn: $settings.calendarEnabled) {
            Text("Calendar")
            Text("Next meeting with a Join button")
        }
        .onChange(of: settings.calendarEnabled) { _, on in
            if !on { waitingForSettings = false }
        }

        if settings.calendarEnabled {
            if calendar.isAuthorized {
                Label("Calendar access granted", systemImage: "checkmark")
                    .foregroundStyle(.green)
                    .padding(.leading, 16)
                Picker("Remind me", selection: $settings.meetingLeadMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min before").tag($0) }
                }
                .padding(.leading, 16)
                Toggle("Also alert when the event starts", isOn: $settings.meetingAlertAtStart)
                    .padding(.leading, 16)
                CalendarChooser()
                    .padding(.leading, 16)
            } else if waitingForSettings {
                Text("Waiting for Calendar access. This turns on by itself once access is granted.")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .task {
                        // Only runs while this message is on screen.
                        while !calendar.isAuthorized, !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            calendar.refreshAuthorization()
                        }
                        waitingForSettings = false
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notch reads your calendars to show upcoming events. Nothing leaves your Mac.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if calendar.authorization == .notDetermined {
                            Button("Allow Access…") {
                                Task {
                                    NSApp.activate()
                                    await calendar.requestAccess()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Open System Settings…") {
                                calendar.openPrivacySettings()
                                waitingForSettings = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Not now") { settings.calendarEnabled = false }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

private struct CalendarChooser: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        DisclosureGroup("Calendars") {
            ForEach(calendar.calendars) { item in
                Toggle(isOn: binding(for: item.id)) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.color.map { Color(cgColor: $0) } ?? .gray)
                            .frame(width: 9, height: 9)
                        Text(item.title)
                        Text(item.source).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.excludedCalendarIDs.contains(id) },
            set: { included in
                if included {
                    settings.excludedCalendarIDs.removeAll { $0 == id }
                } else if !settings.excludedCalendarIDs.contains(id) {
                    settings.excludedCalendarIDs.append(id)
                }
            }
        )
    }
}

private struct TimerSoundPicker: View {
    @Binding var selection: String

    /// The built-in alert sounds in /System/Library/Sounds.
    private static let sounds: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    var body: some View {
        Picker("Sound when a timer ends", selection: $selection) {
            Text("None").tag("")
            Divider()
            ForEach(Self.sounds, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: selection) { _, name in
            if !name.isEmpty { NSSound(named: name)?.play() }  // preview
        }
    }
}

/// Priority of ongoing activities, highest first. Arrow buttons move a row.
private struct ActivityOrderList: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let order = settings.activityOrder
        ForEach(Array(order.enumerated()), id: \.element) { index, activity in
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Image(systemName: symbol(activity)).frame(width: 18).foregroundStyle(Theme.orange)
                Text(title(activity))
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == order.count - 1)
            }
            .buttonStyle(.borderless)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var order = settings.activityOrder
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        settings.activityOrder = order
    }

    private func title(_ activity: Activity) -> String {
        switch activity {
        case .music: "Now Playing"
        case .countdown: "Timer"
        case .stopwatch: "Stopwatch"
        case .download: "Downloads"
        }
    }

    private func symbol(_ activity: Activity) -> String {
        switch activity {
        case .music: "music.note"
        case .countdown: "timer"
        case .stopwatch: "stopwatch"
        case .download: "arrow.down.circle"
        }
    }
}

/// "1, 5, 10, 25": the buttons on the island's Timer tab.
private struct TimerPresetsField: View {
    @Binding var presets: [Int]
    @State private var text = ""

    var body: some View {
        LabeledContent {
            TextField("Presets", text: $text, prompt: Text("1, 5, 10, 25"))
                .labelsHidden()
                .frame(width: 160)
                .onSubmit(commit)
                .onAppear { text = presets.map(String.init).joined(separator: ", ") }
        } label: {
            Text("Timer buttons")
            Text("Minutes, separated by commas (up to 6)")
        }
    }

    private func commit() {
        let values = text.split(whereSeparator: { ",; ".contains($0) }).compactMap { Int($0) }.filter { (1...600).contains($0) }
        var unique: [Int] = []
        for v in values where !unique.contains(v) { unique.append(v) }
        if !unique.isEmpty { presets = Array(unique.prefix(6)) }
        text = presets.map(String.init).joined(separator: ", ")
    }
}

/// Volume & brightness: the same in-place permission flow as Calendar, for Accessibility.
private struct HUDPermissionRows: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HUDService.self) private var hud
    @State private var waitingForSettings = false

    var body: some View {
        @Bindable var settings = settings

        Toggle(isOn: $settings.hudEnabled) {
            Text("Volume & brightness")
            Text("Replaces the system overlay with one from the notch")
        }
        .onChange(of: settings.hudEnabled) { _, on in
            if !on { waitingForSettings = false }
        }

        if settings.hudEnabled {
            if hud.isTrusted {
                Label("Accessibility access granted", systemImage: "checkmark")
                    .foregroundStyle(.green)
                    .padding(.leading, 16)
                Toggle("Volume", isOn: $settings.hudVolume).padding(.leading, 16)
                Toggle("Display brightness", isOn: $settings.hudBrightness).padding(.leading, 16)
                Picker(selection: $settings.hudSteps) {
                    Text("8 steps").tag(8)
                    Text("16 steps (like macOS)").tag(16)
                    Text("32 steps").tag(32)
                    Text("64 steps").tag(64)
                } label: {
                    Text("Key press size")
                    Text("Hold ⌥⇧ for quarter steps")
                }
                .padding(.leading, 16)
            } else if waitingForSettings {
                Text("Waiting for Accessibility access. Turn on Notch in the list; this switches on by itself.")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .task {
                        while !hud.isTrusted, !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            hud.refreshTrust()
                        }
                        waitingForSettings = false
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notch needs Accessibility access to catch the volume and brightness keys. It doesn't read anything you type.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open System Settings…") {
                            hud.requestAccess()
                            hud.openPrivacySettings()
                            waitingForSettings = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Not now") { settings.hudEnabled = false }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

/// Settings › Activities › Downloads: tools, folder, quality, and sign-in cookies.
private struct DownloadsSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadService.self) private var downloads

    var body: some View {
        @Bindable var settings = settings

        Section {
            Toggle(isOn: $settings.downloadsEnabled) {
                Text("Downloads")
                Text("Paste a link from X, YouTube and 1,000+ other sites to save the video")
            }
            if settings.downloadsEnabled {
                toolsRow
                LabeledContent {
                    HStack {
                        Text(downloads.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                } label: {
                    Text("Save to")
                }
                Picker("Default quality", selection: $settings.downloadQuality) {
                    Text("Best").tag(DownloadQuality.best)
                    Text("1080p").tag(DownloadQuality.p1080)
                    Text("720p").tag(DownloadQuality.p720)
                    Text("Audio only (MP3)").tag(DownloadQuality.audio)
                }
                Picker(selection: $settings.videoCompatibility) {
                    Text("Plays everywhere (H.264, up to 1080p)").tag(VideoCompatibility.quickTime)
                    Text("Highest quality (up to 4K, may need VLC)").tag(VideoCompatibility.highest)
                } label: {
                    Text("Video format")
                }
                Picker("File names", selection: $settings.fileNaming) {
                    Text("Title").tag(FileNaming.title)
                    Text("Title [video ID]").tag(FileNaming.titleAndID)
                }
                Picker(selection: $settings.cookieBrowser) {
                    Text("Don't sign in").tag(CookieBrowser.none)
                    Divider()
                    Text("Safari").tag(CookieBrowser.safari)
                    Text("Chrome").tag(CookieBrowser.chrome)
                    Text("Firefox").tag(CookieBrowser.firefox)
                    Text("Brave").tag(CookieBrowser.brave)
                    Text("Edge").tag(CookieBrowser.edge)
                } label: {
                    Text("Sign in using")
                    Text("For posts that need an account. Uses that browser's cookies on this Mac; Safari needs Full Disk Access")
                }
                Toggle("Show a peek when a download finishes", isOn: $settings.downloadPeek)
                Toggle(isOn: $settings.autoUpdateDownloader) {
                    Text("Keep yt-dlp up to date")
                    Text("Sites change often; checks at most once a day, via Homebrew")
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Only download videos you have the right to keep. Some sites' terms, including YouTube's, restrict downloading.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var toolsRow: some View {
        let tools = downloads.tools
        LabeledContent {
            switch downloads.toolTask {
            case .running(let title, _):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(title).foregroundStyle(.secondary)
                }
            default:
                if tools.isReady {
                    Button("Update Now") { downloads.updateTools() }
                        .disabled(tools.brew == nil)
                } else if tools.brew != nil {
                    Button("Install with Homebrew") { downloads.installTools() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Link("Get Homebrew…", destination: URL(string: "https://brew.sh")!)
                }
            }
        } label: {
            Text("yt-dlp and ffmpeg")
            if case .failed(let message) = downloads.toolTask {
                Text(message).foregroundStyle(.red)
            } else {
                Text(tools.isReady ? "Installed" : "Not installed — needed for downloads")
                    .foregroundStyle(tools.isReady ? .green : .orange)
            }
        }
        .onAppear { downloads.refreshTools() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloads.folder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadFolder = url.path
        }
    }
}

/// Settings › Activities › Browser downloads: following the browser's downloads, and the
/// optional extension hand-off with the file types it takes.
private struct BrowserDownloadsSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BrowserBridgeService.self) private var bridge

    var body: some View {
        @Bindable var settings = settings

        if settings.downloadsEnabled {
            Section {
                Toggle(isOn: $settings.followBrowserDownloads) {
                    Text("Show browser downloads in the island")
                    Text("Progress, cancel and the finished file for downloads from Safari, Chrome, Brave, Edge and Arc. Nothing to install")
                }
                Toggle(isOn: $settings.browserTakeover) {
                    Text("Let Notch do the downloading · needs the extension")
                    Text("Chrome, Edge, Brave, Arc or Firefox hand downloads to Notch, which saves them itself. Choose which file types below")
                }
                if settings.browserTakeover {
                    LabeledContent {
                        Button("Show Extension Folder", action: showExtension)
                    } label: {
                        Text("Notch extension")
                        status
                    }
                    ForEach(FileKind.allCases, id: \.self) { kind in
                        Toggle(isOn: Binding(
                            get: { settings.takeoverKinds.contains(kind) },
                            set: { on in
                                if on { settings.takeoverKinds.insert(kind) } else { settings.takeoverKinds.remove(kind) }
                            }
                        )) {
                            Text(kind.title)
                            Text(kind.examples)
                        }
                        .padding(.leading, 16)
                    }
                }
            } header: {
                Text("Browser downloads")
            } footer: {
                if settings.browserTakeover {
                    Text("Install it once: open chrome://extensions (or about:debugging in Firefox), turn on Developer mode, choose Load unpacked and pick the folder. File types you turn off stay with the browser. Safari isn't supported yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let problem = bridge.problem {
            Text(problem).foregroundStyle(.red)
        } else if let seen = bridge.lastSeen {
            Text("Connected · last seen \(seen.formatted(.relative(presentation: .named)))").foregroundStyle(.green)
        } else {
            Text("Waiting for the extension. Open your browser after installing it").foregroundStyle(.orange)
        }
    }

    /// Copies the bundled extension somewhere stable (so app updates don't move it) and reveals it.
    private func showExtension() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Extension", isDirectory: true) else { return }
        let target = URL.applicationSupportDirectory
            .appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("Browser Extension", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: bundled, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([bundled])
        }
    }
}

private extension FileKind {
    var title: String {
        switch self {
        case .document: "Documents"
        case .image: "Images"
        case .archive: "Archives"
        case .installer: "Apps and disk images"
        case .media: "Video and audio files"
        case .other: "Everything else"
        }
    }

    var examples: String {
        switch self {
        case .document: "PDF, Word, Excel, PowerPoint, Pages, text, EPUB"
        case .image: "PNG, JPEG, HEIC, GIF, WebP, SVG"
        case .archive: "ZIP, RAR, 7z, tar.gz"
        case .installer: "DMG, PKG, ISO"
        case .media: "MP4, MOV, MKV, MP3, M4A, WAV"
        case .other: "Files of any other type"
        }
    }
}
