import Foundation
import Testing
@testable import Notch

@MainActor
struct LyricsTests {
    @Test func parsesLRC() {
        let lines = LRC.parse("""
        [ar:Someone]
        [00:03.34]First line
        [00:07.7]Second line
        [01:02.500][02:10.00]Chorus
        [00:09.00]
        not a lyric
        """)
        #expect(lines.map(\.text) == ["First line", "Second line", "", "Chorus", "Chorus"])
        #expect(abs(lines[0].time - 3.34) < 0.001)
        #expect(abs(lines[3].time - 62.5) < 0.001)
        #expect(lines.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func findsTheCurrentLine() {
        let lines = LRC.parse("[00:01.00]a\n[00:05.00]b\n[00:10.00]c")
        #expect(LRC.currentIndex(in: lines, at: 0.2) == nil)  // before the first line
        #expect(LRC.currentIndex(in: lines, at: 1.0) == 0)
        #expect(LRC.currentIndex(in: lines, at: 4.8) == 1)  // lights up just early
        #expect(LRC.currentIndex(in: lines, at: 99) == 2)
    }

    @Test func lyricsTabFollowsSettings() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let c = IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json")),
            calendar: CalendarService(settings: settings)
        )
        // Lyrics lives in the player's controls, not the tab bar.
        #expect(!c.availableTabs.contains(.lyrics))
        #expect(c.lyricsAvailable)

        c.expand(tab: .nowPlaying)
        c.toggleLyrics()
        #expect(c.state == .expanded(.lyrics))
        #expect(c.showsLyrics)

        // Reopening the player returns to lyrics, like Apple Music.
        c.collapse()
        c.expand(tab: .nowPlaying)
        #expect(c.state == .expanded(.lyrics))
        c.toggleLyrics()
        #expect(c.state == .expanded(.nowPlaying))

        settings.lyricsEnabled = false
        c.toggleLyrics()
        #expect(c.state == .expanded(.nowPlaying))
        #expect(!c.lyricsAvailable)

        let m = IslandState.expanded(.lyrics).metrics(notch: CGSize(width: 190, height: 37), hasNotch: true)
        #expect(m.height == 300)
    }
}

@MainActor
struct LyricsSyncTests {
    private func feed(_ service: NowPlayingService, _ json: String) {
        service.handle(line: Data(json.utf8))
    }

    @Test func usesMicrosecondTiming() throws {
        let service = NowPlayingService(startStream: false)
        feed(service, #"{"type":"data","diff":false,"payload":{"title":"Song","artist":"A","playing":true,"playbackRate":1,"timestampEpochMicros":1790866421757930,"elapsedTimeMicros":13965154,"durationMicros":236034000}}"#)
        let track = try #require(service.track)
        #expect(abs(track.elapsed - 13.965154) < 0.000_01)
        #expect(abs(track.duration - 236.034) < 0.000_01)
        #expect(abs(track.timestamp.timeIntervalSince1970 - 1_790_866_421.757930) < 0.000_01)
    }

    @Test func resumingAfterAPauseDoesNotJumpAhead() throws {
        let service = NowPlayingService(startStream: false)
        let longAgo = (Date.now.timeIntervalSince1970 - 600) * 1_000_000
        feed(service, #"{"type":"data","diff":false,"payload":{"title":"Song","playing":false,"playbackRate":0,"timestampEpochMicros":\#(longAgo),"elapsedTimeMicros":10000000,"durationMicros":200000000}}"#)
        // Play pressed; this app sent the old timestamp again.
        feed(service, #"{"type":"data","diff":true,"payload":{"playing":true,"playbackRate":1}}"#)
        let track = try #require(service.track)
        #expect(track.isPlaying)
        #expect(abs(track.elapsed(at: .now) - 10) < 1)  // not 10 minutes ahead
    }

    @Test func wakesExactlyWhenTheNextLineStarts() {
        let lines = LRC.parse("[00:01.00]a\n[00:05.00]b\n[00:10.00]c")
        let wait = LRC.secondsUntilNextLine(in: lines, at: 2.0, rate: 1)
        #expect(abs((wait ?? 0) - (5 - 2 - LRC.leadIn)) < 0.001)
        #expect(abs((LRC.secondsUntilNextLine(in: lines, at: 2.0, rate: 2) ?? 0) - (5 - 2 - LRC.leadIn) / 2) < 0.001)
        #expect(LRC.secondsUntilNextLine(in: lines, at: 11, rate: 1) == nil)  // after the last line
    }

    @Test func downloadsGoStraightIntoDownloads() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let downloads = DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json"))
        #expect(downloads.folder == URL.downloadsDirectory)
    }
}
