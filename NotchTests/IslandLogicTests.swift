import Testing
import Foundation
@testable import Notch

@MainActor
struct IslandLogicTests {
    private func makeCoordinator() -> IslandCoordinator {
        let defaults = UserDefaults(suiteName: "NotchTests-\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        let downloads = DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID()).json"))
        return IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: downloads, calendar: CalendarService(settings: settings)
        )
    }

    @Test func idleWhenNothingRuns() {
        #expect(makeCoordinator().state == .idle)
    }

    @Test func oneTimerIsCompactTwoAreSplit() {
        let c = makeCoordinator()
        c.startCountdown(minutes: 5)
        #expect(c.state == .compact(.countdown))
        c.startStopwatch()
        #expect(c.state == .split(.countdown, .stopwatch))
        #expect(c.state.bubble == .stopwatch)
    }

    @Test func peekBeatsActivityAndExpandedBeatsPeek() {
        let c = makeCoordinator()
        c.startCountdown(minutes: 5)
        c.show(.charging(80))
        #expect(c.state == .peek(.charging(80)))
        c.expand()
        #expect(c.state == .expanded(.timer))  // a running timer opens on the Timer tab
        c.collapse()
        #expect(c.state == .peek(.charging(80)))
    }

    @Test func expandingFromBubbleFocusesThatTimer() {
        let c = makeCoordinator()
        c.startCountdown(minutes: 5)
        c.startStopwatch()
        c.expand(focus: .stopwatch)
        #expect(c.focusedTimer == .stopwatch)
        c.timers.resetStopwatch()
        #expect(c.focusedTimer == .countdown)
    }

    @Test func designSizes() {
        let notch = CGSize(width: 190, height: 37)
        func size(_ s: IslandState) -> CGSize {
            let m = s.metrics(notch: notch, hasNotch: true)
            return CGSize(width: m.width, height: m.height)
        }
        #expect(size(.idle) == notch)
        #expect(size(.compact(.countdown)) == CGSize(width: 300, height: 37))
        #expect(size(.compact(.music)) == CGSize(width: 316, height: 37))
        #expect(size(.split(.music, .countdown)) == CGSize(width: 300, height: 37))
        #expect(size(.peek(.trackChange)) == CGSize(width: 430, height: 92))
        #expect(size(.peek(.charging(80))) == CGSize(width: 408, height: 37))
        #expect(size(.expanded(.timer)) == CGSize(width: 540, height: 176))
        #expect(size(.expanded(.downloads)) == CGSize(width: 540, height: 212))
        #expect(IslandState.idle.metrics(notch: notch, hasNotch: false).height == 0)
    }

    @Test func countdownPauseAndResumeKeepsRemainingTime() async throws {
        let t = TimerService()
        t.startCountdown(seconds: 60)
        t.pauseCountdown()
        let paused = try #require(t.countdown?.pausedRemaining)
        try await Task.sleep(for: .milliseconds(300))
        #expect(t.countdown?.remaining(at: .now) == paused)
        t.resumeCountdown()
        let remaining = try #require(t.countdown?.remaining(at: .now))
        #expect(abs(remaining - paused) < 0.1)
    }

    @Test func countdownFinishes() async throws {
        let t = TimerService()
        var finished = false
        t.onCountdownFinished = { finished = true }
        t.startCountdown(seconds: 0.2)
        try await Task.sleep(for: .milliseconds(600))
        #expect(finished)
        #expect(t.countdown == nil)
    }

    @Test func trackPositionAdvancesOnlyWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1000)
        var track = NowPlayingService.Track(
            title: "Alright", artist: "Kendrick Lamar", album: "To Pimp a Butterfly", duration: 219,
            bundleIdentifier: "com.apple.Music", elapsed: 100, timestamp: start, playbackRate: 1, isPlaying: true
        )
        #expect(track.elapsed(at: start + 10) == 110)
        #expect(track.elapsed(at: start + 500) == 219)  // clamped to the song's length
        track.isPlaying = false
        #expect(track.elapsed(at: start + 10) == 100)
    }

    @Test func clockFormatting() {
        #expect(formatClock(299) == "4:59")
        #expect(formatClock(299, padMinutes: true) == "04:59")
        #expect(formatClock(3899) == "1:04:59")
    }
}
