import AppKit
import Foundation
import Testing
@testable import Notch

@MainActor
struct OptimizationTests {
    @MainActor final class Recorder { var keys: [String?] = [] }

    @Test func settingsChangesSayWhichKeyChanged() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let recorder = Recorder()
        let token = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: settings, queue: nil) { note in
            let key = note.userInfo?[SettingsStore.changedKey] as? String
            MainActor.assumeIsolated { recorder.keys.append(key) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.weatherCity = "Accra"
        settings.timerShortcut = .none
        settings.resetToDefaults()
        #expect(recorder.keys == ["weatherCity", "timerShortcut", nil])

        func note(_ key: String?) -> Notification {
            Notification(name: .settingsDidChange, userInfo: key.map { [SettingsStore.changedKey: $0] })
        }
        // Typing a city no longer wakes Calendar or the windows.
        #expect(note("weatherCity").affects(["weatherCity"]))
        #expect(!note("weatherCity").affects(["calendarEnabled", "displayMode"]))
        #expect(note("timerShortcut").affects(suffix: "Shortcut"))
        #expect(note(nil).affects(["anything"]))  // a reset affects everyone
    }

    @Test func artworkIsDecodedSmall() throws {
        // A 1200 × 1200 PNG, like real album art.
        let big = NSImage(size: NSSize(width: 1200, height: 1200), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        let rep = try #require(NSBitmapImageRep(data: big.tiffRepresentation!))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let thumb = try #require(NowPlayingService.thumbnail(from: png))
        let pixels = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(pixels.width, pixels.height) <= 192)
        #expect(thumb.size.width == CGFloat(pixels.width) / 2)  // sharp on Retina
    }

    @Test func longTitlesScrollWithCoreAnimation() {
        let view = MarqueeView()
        view.frame = NSRect(x: 0, y: 0, width: 80, height: 20)
        view.configure(text: "A very long song title that cannot possibly fit", font: .systemFont(ofSize: 14), color: .white, animates: true)
        view.layout()
        #expect(view.layer?.sublayers?.first?.animation(forKey: "marquee") != nil)

        view.configure(text: "Short", font: .systemFont(ofSize: 14), color: .white, animates: true)
        view.layout()
        #expect(view.layer?.sublayers?.first?.animation(forKey: "marquee") == nil)  // nothing to scroll
    }
}
