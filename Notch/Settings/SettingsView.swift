import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, activities, dashboard, notifications, shortcuts, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .activities: "Activities"
        case .dashboard: "Dashboard"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "circle.lefthalf.filled"
        case .activities: "capsule.fill"
        case .dashboard: "square.grid.2x2.fill"
        case .notifications: "bell.fill"
        case .shortcuts: "keyboard.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: Color(red: 0.56, green: 0.56, blue: 0.58)
        case .appearance: Theme.blue
        case .activities: Theme.orange
        case .dashboard: Color(red: 0.35, green: 0.34, blue: 0.84)
        case .notifications: Color(red: 1, green: 0.23, blue: 0.19)
        case .shortcuts: Color(red: 0.39, green: 0.39, blue: 0.4)
        case .about: Color(red: 0.19, green: 0.69, blue: 0.78)
        }
    }
}

/// System Settings–style window: a sidebar of sections and a grouped form on the right.
struct SettingsView: View {
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pane.color, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .navigationSplitViewColumnWidth(210)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch pane ?? .general {
            case .general: GeneralPane()
            case .appearance: AppearancePane()
            case .activities: ActivitiesPane()
            case .dashboard: DashboardPane()
            case .shortcuts: ShortcutsPane()
            case .about: AboutPane()
            case .notifications: NotificationsPane()
            }
        }
        .frame(minWidth: 715, minHeight: 520)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(SettingsStore.self) private var settings
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Open at login", isOn: $settings.openAtLogin)
                Picker("Show island on", selection: $settings.displayMode) {
                    Text("Built-in").tag(DisplayMode.builtIn)
                    Text("All displays").tag(DisplayMode.all)
                    Text("With cursor").tag(DisplayMode.withCursor)
                }
                .pickerStyle(.segmented)
                Picker("In full-screen apps", selection: $settings.fullScreenMode) {
                    Text("Keep showing").tag(FullScreenMode.show)
                    Text("Hide unless something is live").tag(FullScreenMode.hideWhenIdle)
                    Text("Hide").tag(FullScreenMode.hide)
                }
                Toggle(isOn: $settings.hideWhileSharing) {
                    Text("Hide while sharing your screen")
                    Text("Keeps notifications and media private during calls")
                }
            }

            Section("Interaction") {
                Toggle("Expand on hover", isOn: $settings.expandOnHover)
                LabeledContent {
                    Slider(
                        value: Binding(get: { Double(settings.hoverDelay) }, set: { settings.hoverDelay = Int($0) }),
                        in: 0...500, step: 50
                    )
                    .labelsHidden()
                    .frame(width: 150)
                } label: {
                    Text("Hover delay")
                    Text("\(settings.hoverDelay) ms")
                }
                .disabled(!settings.expandOnHover)
                Toggle(isOn: $settings.haptics) {
                    Text("Haptic feedback")
                    Text("On Force Touch trackpads")
                }
            }

            Section {
                TryItButtons()
            } header: {
                Text("Try it")
            } footer: {
                Text("Shows each peek on the island now, even if it's turned off in Activities.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button("Reset All Settings to Defaults…", role: .destructive) { confirmingReset = true }
                    .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
                        Button("Reset", role: .destructive) { settings.resetToDefaults() }
                    } message: {
                        Text("Your downloads and calendar access aren't affected.")
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

private struct TryItButtons: View {
    private let items: [(String, String)] = [
        ("Charging", "charging"), ("On battery", "unplugged"), ("Low battery", "lowBattery"),
        ("Song change", "trackChange"), ("Meeting", "meeting"), ("Timer done", "timerDone"),
        ("Volume", "volume"), ("Downloaded", "downloadDone"),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
            ForEach(items, id: \.1) { title, name in
                Button(title) {
                    NotificationCenter.default.post(name: .previewPeek, object: name)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Environment(SettingsStore.self) private var settings

    private var glassAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker(selection: $settings.material) {
                    Text("Black").tag(IslandMaterial.black)
                    Text("Hybrid").tag(IslandMaterial.hybrid)
                    Text("Glass").tag(IslandMaterial.glass)
                } label: {
                    Text("Material")
                    Text(glassAvailable
                         ? "Hybrid stays black around the camera and fades into Liquid Glass"
                         : "Hybrid and Glass need macOS 26 or later")
                }
                .pickerStyle(.segmented)
                .disabled(!glassAvailable)
                Picker(selection: $settings.compactStyle) {
                    Text("Beside the notch").tag(CompactStyle.beside)
                    Text("Below the notch").tag(CompactStyle.below)
                } label: {
                    Text("Collapsed island")
                    Text("Below keeps menu bar items next to the notch uncovered")
                }
                Picker("Expanded size", selection: $settings.expandedSize) {
                    Text("Compact").tag(ExpandedSize.compact)
                    Text("Default").tag(ExpandedSize.regular)
                    Text("Large").tag(ExpandedSize.large)
                }
                .pickerStyle(.segmented)
            }

            Section("Menu bar") {
                Toggle(isOn: $settings.showMenuBarIcon) {
                    Text("Show menu bar icon")
                    Text("When hidden, open Settings from the gear in the expanded island")
                }
                if settings.showMenuBarIcon {
                    Picker("Icon", selection: $settings.menuBarIconStyle) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                            Label {
                                Text(menuBarTitle(style))
                            } icon: {
                                if style == .live {
                                    Image(systemName: "sparkles")
                                } else {
                                    Image(nsImage: MenuBarIcon.image(style))
                                }
                            }
                            .tag(style)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            Section("Details") {
                Toggle(isOn: $settings.tintWithArtwork) {
                    Text("Tint with album artwork")
                    Text("Colors the waveform and glow with the artwork")
                }
                Toggle(isOn: $settings.artworkGlow) {
                    Text("Artwork glow")
                    Text("A soft glow behind the island while music plays")
                }
                Toggle("Shadow when expanded", isOn: $settings.shadowWhenExpanded)
                Toggle("Bounce when the pointer arrives", isOn: $settings.bounceOnHover)
                Toggle(isOn: $settings.titleOnHover) {
                    Text("Show the song title on hover")
                    Text("When Expand on hover is off, the title appears below the island instead")
                }
                Toggle(isOn: .constant(false)) {
                    Text("Audio-reactive waveform")
                    Text("Uses real audio levels · coming in a later version")
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .safeAreaInset(edge: .bottom) {
            Text("Motion follows System Settings › Accessibility › Reduce motion.")
                .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 12)
        }
    }
}

// MARK: - Notifications

private func menuBarTitle(_ style: MenuBarIconStyle) -> String {
    switch style {
    case .island: "Island on a screen"
    case .pill: "Island"
    case .waveform: "Island with waveform"
    case .live: "Live — shows what's happening (music, timer, download)"
    }
}

private struct NotificationsPane: View {
    var body: some View {
        ContentUnavailableView(
            "Notifications",
            systemImage: "bell.fill",
            description: Text("Mirroring notification banners into the island needs Full Disk Access and arrives in a later version.")
        )
        .navigationTitle("Notifications")
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build)) · free and open source under GPL-3.0"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notch").font(.title2.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Privacy") {
                LabeledContent("Analytics", value: "None")
                LabeledContent("Network", value: "Only lyrics, weather and downloads you ask for")
                LabeledContent {
                    Text("Open-Meteo, when the dashboard opens")
                } label: {
                    Text("Weather")
                    Text("Your city, or your location rounded to ~1 km")
                }
                LabeledContent("Account", value: "None")
                LabeledContent {
                    Text("Read on your Mac only")
                } label: {
                    Text("Calendar")
                    Text("Only if you turn it on in Activities")
                }
                LabeledContent {
                    Text("Read on your Mac only")
                } label: {
                    Text("Now Playing")
                    Text("Through a bundled helper run by macOS's own Perl")
                }
                LabeledContent {
                    Text("Title & artist sent to lrclib.net")
                } label: {
                    Text("Lyrics")
                    Text("Only when you open lyrics; turn off in Activities")
                }
                LabeledContent {
                    Text("Only the links you paste")
                } label: {
                    Text("Downloads")
                    Text("yt-dlp contacts the video's site directly")
                }
            }

            Section("Acknowledgements") {
                LabeledContent("mediaremote-adapter", value: "BSD 3-Clause, © Jonas van den Berg")
                LabeledContent("yt-dlp", value: "Unlicense · installed via Homebrew")
                LabeledContent("FFmpeg", value: "GPL · installed via Homebrew")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
