import Carbon.HIToolbox
import Foundation
import Testing
@testable import Notch

@MainActor
struct Phase5Tests {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "NotchTests-\(UUID())")! }

    private func makeCoordinator(_ settings: SettingsStore) -> IslandCoordinator {
        IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json")),
            calendar: CalendarService(settings: settings)
        )
    }

    // MARK: Settings storage

    @Test func settingsPersistAndReset() {
        let defaults = makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.expandedSize = .large
        settings.timerPresets = [3, 7]
        settings.activityOrder = [.stopwatch, .music, .countdown, .download]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.expandedSize == .large)
        #expect(reloaded.timerPresets == [3, 7])
        #expect(reloaded.activityOrder == [.stopwatch, .music, .countdown, .download])

        reloaded.resetToDefaults()
        #expect(reloaded.expandedSize == .regular)
        #expect(reloaded.activityOrder == Activity.allCases)
        #expect(SettingsStore(defaults: defaults).timerPresets == [1, 5, 10, 25])
    }

    @Test func badStoredValuesFallBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set("sideways", forKey: "compactStyle")
        defaults.set(99_999, forKey: "hoverDelay")
        defaults.set(["stopwatch", "bogus"], forKey: "activityOrder")
        defaults.set([0, -5], forKey: "timerPresets")

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.compactStyle == .beside)
        #expect(settings.hoverDelay == 1000)  // clamped
        #expect(settings.activityOrder == [.stopwatch, .music, .countdown, .download])  // unknown dropped, missing appended
        #expect(settings.timerPresets == [1, 5, 10, 25])
    }

    @Test func migratesOldFullScreenSetting() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "hideInFullScreen")
        #expect(SettingsStore(defaults: defaults).fullScreenMode == .show)
    }

    // MARK: Island behaviour

    @Test func fullScreenModes() {
        let settings = SettingsStore(defaults: makeDefaults())
        let c = makeCoordinator(settings)
        c.isFullScreen = true

        settings.fullScreenMode = .hideWhenIdle
        #expect(c.state == .hidden)
        c.startCountdown(minutes: 5)
        #expect(c.state == .compact(.countdown))  // something is live

        settings.fullScreenMode = .hide
        #expect(c.state == .hidden)
        settings.fullScreenMode = .show
        #expect(c.state == .compact(.countdown))
    }

    @Test func priorityOrderAndBubbleSetting() {
        let settings = SettingsStore(defaults: makeDefaults())
        let c = makeCoordinator(settings)
        c.startCountdown(minutes: 5)
        c.startStopwatch()
        #expect(c.state == .split(.countdown, .stopwatch))

        settings.activityOrder = [.stopwatch, .countdown, .music]
        #expect(c.state == .split(.stopwatch, .countdown))

        settings.showSplitBubble = false
        #expect(c.state == .compact(.stopwatch))

        settings.timersInCompact = false
        #expect(c.state == .idle)
        #expect(c.focusedTimer == .stopwatch)  // still reachable in the Timer tab
    }

    @Test func layoutOptionsChangeSizes() {
        let notch = CGSize(width: 190, height: 37)
        let below = IslandState.LayoutOptions(compactStyle: .below, expandedScale: 1)
        let m = IslandState.compact(.countdown).metrics(notch: notch, hasNotch: true, options: below)
        #expect(m.height == 37 + IslandState.belowBandHeight)
        #expect(m.width >= 230)

        let large = IslandState.LayoutOptions(compactStyle: .beside, expandedScale: 1.12)
        let e = IslandState.expanded(.downloads).metrics(notch: notch, hasNotch: true, options: large)
        #expect(abs(e.width - 540 * 1.12) < 0.01)
        #expect(IslandState.hidden.metrics(notch: notch, hasNotch: true).height == 0)
    }

    @Test func tryItPeeksIgnoreSettings() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.unpluggedPeek = false
        let c = makeCoordinator(settings)
        c.show(.unplugged(50))
        #expect(c.state == .idle)
        c.show(.unplugged(50), force: true)
        #expect(c.state == .peek(.unplugged(50)))
    }

    @Test func shortcutLabels() {
        #expect(KeyShortcut(keyCode: kVK_Space, modifiers: cmdKey | shiftKey).displayString == "⇧⌘Space")
        #expect(KeyShortcut(keyCode: kVK_F5, modifiers: controlKey | optionKey).displayString == "⌃⌥F5")
    }
}
