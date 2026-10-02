import SwiftUI

/// The expanded island. The top band (notch height) holds tabs on the left
/// and status on the right, keeping clear of the hardware notch in the middle.
struct ExpandedView: View {
    let tab: IslandTab

    @Environment(IslandCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(coordinator.availableTabs, id: \.self) { item in
                    TabButton(tab: item, isOn: tab == item || (item == .nowPlaying && tab == .lyrics)) {
                        coordinator.tab = item
                    }
                }
                Spacer()
                if coordinator.settings.batteryEnabled, let level = coordinator.battery.level {
                    Text("\(level)%")
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(coordinator.battery.isPluggedIn ? Theme.green : .white.opacity(0.6))
                        .padding(.trailing, 12)
                }
                Button {
                    coordinator.collapse()
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 7, padding: 0))
                .accessibilityLabel("Settings")
            }
            .padding(.leading, 22)
            .padding(.trailing, 24)
            .frame(height: coordinator.notchSize.height)

            ZStack {
                switch tab {
                case .nowPlaying:
                    if let track = coordinator.nowPlaying.track {
                        NowPlayingView(track: track)
                    } else {
                        NowPlayingEmptyView()
                    }
                case .lyrics:
                    if let track = coordinator.nowPlaying.track {
                        LyricsView(track: track)
                    } else {
                        NowPlayingEmptyView()
                    }
                case .downloads: DownloadsView()
                case .dashboard: DashboardView()
                case .timer: TimerTabView()
                case .notifications: NotificationsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            .animation(.easeInOut(duration: 0.25), value: tab)
        }
        .frame(width: tab.baseSize(dashboardRows: coordinator.dashboardRows).width,
               height: tab.baseSize(dashboardRows: coordinator.dashboardRows).height)
    }
}

private struct TabButton: View {
    let tab: IslandTab
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? .white : .white.opacity(0.5))
                .frame(width: 30, height: 24)
                .background(isOn ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 7, padding: 0))
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch tab {
        case .dashboard: "square.grid.2x2"
        case .nowPlaying: "music.note"
        case .lyrics: "quote.bubble"
        case .downloads: "arrow.down.circle"
        case .timer: "timer"
        case .notifications: "bell"
        }
    }

    private var label: String {
        switch tab {
        case .dashboard: "Dashboard"
        case .nowPlaying: "Now Playing"
        case .lyrics: "Lyrics"
        case .downloads: "Downloads"
        case .timer: "Timer"
        case .notifications: "Notifications"
        }
    }
}

private struct NowPlayingEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 22))
            Text("Nothing playing")
                .font(.system(size: 13))
        }
        .foregroundStyle(Theme.secondaryText)
    }
}
