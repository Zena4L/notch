import Foundation
import Testing
@testable import Notch

@MainActor
struct Phase4Tests {
    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
    }

    private func makeCoordinator(_ settings: SettingsStore) -> IslandCoordinator {
        IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: DownloadService(settings: settings, storeURL: tempURL("downloads.json")), calendar: CalendarService(settings: settings)
        )
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID())-\(name)")
    }

    // MARK: Calendar links

    @Test func findsMeetingLinks() {
        let zoom = MeetingLink.find(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123456789?pwd=abc thanks"])
        #expect(zoom?.service == "Zoom")
        #expect(zoom?.url.absoluteString == "https://us02web.zoom.us/j/123456789?pwd=abc")

        #expect(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.service == "Google Meet")
        #expect(MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting>"])?.service == "Microsoft Teams")
        #expect(MeetingLink.find(in: ["Lunch at the café", nil]) == nil)
    }

    // MARK: Settings switches

    @Test func peeksRespectSettings() {
        let settings = makeSettings()
        let c = makeCoordinator(settings)
        settings.chargingPeek = false
        c.show(.charging(80))
        #expect(c.state == .idle)
        settings.chargingPeek = true
        c.show(.charging(80))
        #expect(c.state == .peek(.charging(80)))
    }

    @Test func turningOffFeaturesHidesTheirTabs() {
        let settings = makeSettings()
        let c = makeCoordinator(settings)
        #expect(c.availableTabs == [.dashboard, .nowPlaying, .downloads, .timer])
        settings.downloadsEnabled = false
        settings.nowPlayingEnabled = false
        settings.dashboardEnabled = false
        #expect(c.availableTabs == [.timer])
        c.expand(tab: .downloads)
        #expect(c.state == .expanded(.timer))  // falls back to a tab that's on
    }

    @Test func quickTimerUsesConfiguredLength() throws {
        let settings = makeSettings()
        settings.quickTimerMinutes = 25
        let c = makeCoordinator(settings)
        c.startQuickTimer()
        let duration = try #require(c.timers.countdown?.duration)
        #expect(duration == 25 * 60)
    }
}
