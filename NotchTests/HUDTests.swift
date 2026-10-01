import Foundation
import Testing
@testable import Notch

@MainActor
struct HUDTests {
    @Test func hudPeekIsSlimAndDoesNotRefadeOnEveryPress() {
        let notch = CGSize(width: 190, height: 37)
        let quiet = IslandState.peek(.hud(.volume, level: 40, muted: false))
        let loud = IslandState.peek(.hud(.volume, level: 50, muted: false))
        #expect(quiet.metrics(notch: notch, hasNotch: true).width == 318)  // notch + room either side
        #expect(quiet.metrics(notch: notch, hasNotch: true).height == 37 + IslandState.hudLip)  // the level lip
        // Same content kind, so the bar animates instead of the whole peek cross-fading.
        #expect(quiet.contentKind == loud.contentKind)
        #expect(quiet.contentKind != IslandState.peek(.hud(.brightness, level: 50, muted: false)).contentKind)
    }

    @Test func hudPeekNeedsTheSetting() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let c = IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json")),
            calendar: CalendarService(settings: settings)
        )
        c.show(.hud(.volume, level: 50, muted: false))
        #expect(c.state == .idle)  // off by default
        settings.hudEnabled = true
        c.show(.hud(.volume, level: 50, muted: false))
        #expect(c.state == .peek(.hud(.volume, level: 50, muted: false)))
    }

    /// Read-only: confirms Core Audio and DisplayServices answer on this Mac. Changes nothing.
    @Test func systemLevelsAreReadable() {
        if SystemVolume.isControllable {
            let level = SystemVolume.level
            #expect(level != nil)
            #expect((0...1).contains(level ?? -1))
        }
        if DisplayBrightness.isAvailable {
            #expect((0...1).contains(DisplayBrightness.level ?? -1))
        }
        print("volume controllable: \(SystemVolume.isControllable), level: \(SystemVolume.level ?? -1); brightness available: \(DisplayBrightness.isAvailable), level: \(DisplayBrightness.level ?? -1)")
    }
}
