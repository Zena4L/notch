import Foundation
import Testing
@testable import Notch

@MainActor
struct DownloadTests {
    private let folder = URL(fileURLWithPath: "/tmp/Notch")

    @Test func acceptsPastedLinks() {
        #expect(DownloadService.webURL(from: "  https://x.com/user/status/123  ")?.host() == "x.com")
        #expect(DownloadService.webURL(from: "youtu.be/abc123")?.absoluteString == "https://youtu.be/abc123")
        #expect(DownloadService.webURL(from: "https://www.youtube.com/watch?v=abc then some text")?.host() == "www.youtube.com")
        #expect(DownloadService.webURL(from: "hello world") == nil)
        #expect(DownloadService.webURL(from: "ftp://example.com/file") == nil)
        #expect(DownloadService.webURL(from: "") == nil)
    }

    @Test func buildsQuickTimeFriendlyVideoArguments() {
        let args = DownloadService.arguments(
            url: "https://youtu.be/x", quality: .p1080, compatibility: .quickTime,
            naming: .title, folder: folder, cookies: .none, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        )
        #expect(value(after: "-S", in: args) == "res:1080,vcodec:h264,res,acodec:aac")
        #expect(value(after: "--merge-output-format", in: args) == "mp4")
        #expect(value(after: "-o", in: args) == "/tmp/Notch/%(title).180B.%(ext)s")
        #expect(value(after: "--ffmpeg-location", in: args) == "/opt/homebrew/bin/ffmpeg")
        #expect(!args.contains("--cookies-from-browser"))
        #expect(args.suffix(2) == ["--", "https://youtu.be/x"])  // the link can never be read as an option
    }

    @Test func buildsAudioAndCookieArguments() {
        let args = DownloadService.arguments(
            url: "https://x.com/a/status/1", quality: .audio, compatibility: .highest,
            naming: .titleAndID, folder: folder, cookies: .safari, ffmpeg: nil
        )
        #expect(value(after: "--audio-format", in: args) == "mp3")
        #expect(args.contains("-x"))
        #expect(!args.contains("--merge-output-format"))
        #expect(value(after: "--cookies-from-browser", in: args) == "safari")
        #expect(value(after: "-o", in: args)?.contains("[%(id)s]") == true)
    }

    @Test func parsesProgressLines() {
        #expect(ProgressParser.Line("NOTCH_TITLE My video") == .title("My video"))
        #expect(ProgressParser.Line("NOTCH_SIZE 1000") == .size(1000))
        #expect(ProgressParser.Line("NOTCH_THUMB NA") == .other)
        #expect(ProgressParser.Line("NOTCH_PROGRESS 500 NA 1000 2048.5 12") == .progress(downloaded: 500, total: 1000, speed: 2048.5, eta: 12))
        #expect(ProgressParser.Line("NOTCH_FILE /tmp/Notch/a.mp4") == .file("/tmp/Notch/a.mp4"))
        #expect(ProgressParser.Line("ERROR: [youtube] x: Private video") == .error("ERROR: [youtube] x: Private video"))
        #expect(ProgressParser.Line("[download] Destination: …") == .other)
    }

    @Test func combinesVideoAndAudioParts() {
        var parser = ProgressParser()
        parser.expectedTotal = 1000  // 800 video + 200 audio
        #expect(parser.fraction(downloaded: 400, total: 800) == 0.4)
        _ = parser.fraction(downloaded: 800, total: 800)
        // Audio starts again from zero; overall keeps climbing.
        #expect(parser.fraction(downloaded: 100, total: 200) == 0.9)
        #expect(parser.fraction(downloaded: 200, total: 200) == 0.99)  // never 100% until the file is in place
    }

    @Test func explainsCommonErrors() {
        #expect(DownloadService.friendlyError("ERROR: Unsupported URL: https://example.com") == "This site isn't supported")
        #expect(DownloadService.friendlyError("ERROR: [youtube] x: Private video. Sign in if you've been granted access").contains("signed in"))
        #expect(DownloadService.friendlyError(nil) == "Download failed")
    }

    @Test func interruptedDownloadsCanBeRetriedAfterRelaunch() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let first = DownloadService(settings: settings, storeURL: store)
        #expect(first.download("https://youtu.be/abc"))
        #expect(!first.download("not a link"))

        let relaunched = DownloadService(settings: settings, storeURL: store)
        let item = try #require(relaunched.items.first)
        #expect(item.sourceURL == "https://youtu.be/abc")
        // Queued or mid-download when Notch quit → shown as failed with a retry hint.
        #expect(item.status == .failed || !relaunched.tools.isReady)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}
