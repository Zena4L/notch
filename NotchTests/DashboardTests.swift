import Foundation
import Testing
@testable import Notch

@MainActor
struct DashboardTests {
    private func makeCoordinator(_ settings: SettingsStore) -> IslandCoordinator {
        IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json")),
            calendar: CalendarService(settings: settings)
        )
    }

    @Test func packsWidgetsIntoFourSlotRows() {
        let rows = DashboardLayout.rows([.cpu, .memory, .battery, .storage, .weather, .calendar], maxRows: 3)
        #expect(rows == [[.cpu, .memory, .battery, .storage], [.weather, .calendar]])
        // A wide widget that doesn't fit starts a new row.
        #expect(DashboardLayout.rows([.cpu, .memory, .battery, .weather], maxRows: 3) == [[.cpu, .memory, .battery], [.weather]])
        // Extra rows are left out.
        #expect(DashboardLayout.rows([.weather, .calendar, .clipboard, .cpu], maxRows: 1) == [[.weather, .calendar]])
        #expect(DashboardLayout.rows([], maxRows: 2).isEmpty)
    }

    @Test func islandHeightFollowsRows() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let c = makeCoordinator(settings)
        c.expand(tab: .dashboard)
        let two = c.metrics.height
        #expect(two == DashboardLayout.height(rows: 2))
        settings.dashboardMaxRows = 1
        #expect(c.metrics.height == DashboardLayout.height(rows: 1))
        #expect(c.metrics.height < two)
    }

    @Test func idleIslandOpensOnTheDashboard() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let c = makeCoordinator(settings)
        c.expand()
        #expect(c.state == .expanded(.dashboard))
        c.collapse()
        c.startCountdown(minutes: 5)
        c.expand()
        #expect(c.state == .expanded(.timer))  // something live wins
        c.collapse()
        c.timers.cancelCountdown()
        settings.dashboardOnIdle = false
        c.expand()
        #expect(c.state == .expanded(.downloads))
    }

    /// Reads real values from this Mac (nothing is changed).
    @Test func systemReadingsAreSane() throws {
        let cpu = try #require(SystemStatsService.cpuTicks())
        #expect(cpu.total >= cpu.busy)
        let memory = try #require(SystemStatsService.memoryUsed())
        #expect(memory > 0 && memory < Double(ProcessInfo.processInfo.physicalMemory))
        let storage = try #require(SystemStatsService.storage())
        #expect(storage.free > 0 && storage.free < storage.total)
        #expect(SystemStatsService.networkBytes() != nil)
        print("cpu ticks \(cpu), memory \(Int(memory / 1_048_576)) MB, free \(Int(storage.free / 1e9)) GB of \(Int(storage.total / 1e9)) GB")
    }

    @Test func networkCountersWrap() {
        #expect(SystemStatsService.delta(10, 5) == 5)
        #expect(SystemStatsService.delta(5, UInt64(UInt32.max) - 4) == 10)
    }

    @Test func describesWeather() {
        #expect(WeatherService.describe(0, isDay: true).symbol == "sun.max.fill")
        #expect(WeatherService.describe(0, isDay: false).symbol == "moon.stars.fill")
        #expect(WeatherService.describe(63, isDay: true).text == "Rain")
        #expect(WeatherService.describe(95, isDay: true).text == "Thunderstorm")
    }

    @Test func menuBarIconsAreTemplates() {
        for style in MenuBarIconStyle.allCases {
            let image = MenuBarIcon.image(style)
            #expect(image.isTemplate)
            #expect(image.size.height == 16)
        }
    }
}
