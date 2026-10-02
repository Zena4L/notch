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

    // MARK: Plain files

    @Test func sortsFilesIntoKinds() {
        #expect(FileKind.of(filename: "report.PDF") == .document)
        #expect(FileKind.of(filename: "download", mime: "application/pdf") == .document)
        #expect(FileKind.of(filename: "", mime: "image/webp") == .image)
        #expect(FileKind.of(filename: "backup.tar.gz") == .archive)
        #expect(FileKind.of(filename: "Setup.dmg") == .installer)
        #expect(FileKind.of(filename: "clip.mov") == .media)
        #expect(FileKind.of(filename: "Book.xlsx", mime: "application/octet-stream") == .document)
        #expect(FileKind.of(filename: "data.bin", mime: "application/octet-stream") == .other)
        #expect(FileKind.of(filename: "page", mime: "text/html; charset=utf-8") == .other)
    }

    @Test func routesPastedFileLinksPastYtDLP() throws {
        #expect(DownloadService.isFileLink(try #require(URL(string: "https://site.com/files/a.pdf"))))
        #expect(DownloadService.isFileLink(try #require(URL(string: "https://site.com/Setup.dmg?v=2"))))
        #expect(!DownloadService.isFileLink(try #require(URL(string: "https://youtu.be/abc"))))
        #expect(!DownloadService.isFileLink(try #require(URL(string: "https://x.com/user/status/123"))))
        #expect(!DownloadService.isFileLink(try #require(URL(string: "https://site.com/video.mp4"))))  // yt-dlp handles media
    }

    @Test func cleansFileNames() {
        #expect(DownloadService.cleanFileName("report.pdf") == "report.pdf")
        #expect(DownloadService.cleanFileName("/Users/me/Downloads/report.pdf") == "report.pdf")
        #expect(DownloadService.cleanFileName("..hidden") == "hidden")
        #expect(DownloadService.cleanFileName("a:b\u{7}.txt") == "a-b.txt")
        #expect(DownloadService.cleanFileName("   ") == nil)
        #expect(DownloadService.cleanFileName(String(repeating: "x", count: 300) + ".pdf")?.hasSuffix(".pdf") == true)
    }

    @Test func picksAFreeFileName() {
        let taken: Set<String> = ["/tmp/Notch/a.zip", "/tmp/Notch/a (1).zip", "/tmp/Notch/b.tar.gz", "/tmp/Notch/README"]
        let exists = { (url: URL) in taken.contains(url.path) }
        #expect(DownloadService.uniqueFileName("new.pdf", in: folder, exists: exists) == "new.pdf")
        #expect(DownloadService.uniqueFileName("a.zip", in: folder, exists: exists) == "a (2).zip")
        #expect(DownloadService.uniqueFileName("b.tar.gz", in: folder, exists: exists) == "b (1).tar.gz")
        #expect(DownloadService.uniqueFileName("README", in: folder, exists: exists) == "README (1)")
    }

    @Test func loadsHistoryFromBeforePlainFiles() throws {
        let json = #"[{"id":"6B1F2E4C-1D5A-4C8E-9C34-2F1D3B4A5C6D","sourceURL":"https://youtu.be/x","title":"x","quality":"best","created":0,"status":"done"}]"#
        let items = try JSONDecoder().decode([DownloadService.Item].self, from: Data(json.utf8))
        #expect(items.first?.isDirect == false)
        #expect(items.first?.expectedBytes == nil)
    }

    @Test func takesOverAFileFromTheBrowser() async throws {
        let (downloads, _, folder) = makeDirectService()
        StubProtocol.set("https://files.example.com/report.pdf", status: 200, mime: "application/pdf", body: Data("%PDF-1.4 hello".utf8))

        let accepted = await downloads.takeOver(BridgeDownload(
            url: "https://files.example.com/report.pdf", filename: "report.pdf",
            referrer: "https://example.com/page", mime: "application/pdf", cookies: "session=abc"
        ))
        #expect(accepted)
        let item = try await finished(downloads)
        #expect(item.status == .done)
        #expect(item.isDirect)
        #expect(item.filePath == folder.appendingPathComponent("report.pdf").path)
        #expect(try Data(contentsOf: try #require(item.fileURL)) == Data("%PDF-1.4 hello".utf8))
        #expect(StubProtocol.lastHeaders["Cookie"] == "session=abc")
        #expect(StubProtocol.lastHeaders["Referer"] == "https://example.com/page")
        // Marked as from the web, so Gatekeeper still checks it.
        let quarantine = try #require(item.fileURL).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Notch")

        // Same name again → "report (1).pdf".
        #expect(await downloads.takeOver(BridgeDownload(url: "https://files.example.com/report.pdf", filename: "report.pdf")))
        let second = try await finished(downloads)
        #expect(second.filePath == folder.appendingPathComponent("report (1).pdf").path)
    }

    @Test func leavesDownloadsWithTheBrowserWhenItCant() async throws {
        let (downloads, settings, _) = makeDirectService()
        StubProtocol.set("https://files.example.com/expired.zip", status: 403, mime: "text/plain", body: Data())
        StubProtocol.set("https://files.example.com/login.pdf", status: 200, mime: "text/html", body: Data("<html>".utf8))
        StubProtocol.set("https://files.example.com/photo.png", status: 200, mime: "image/png", body: Data([1, 2, 3]))

        #expect(await !downloads.takeOver(BridgeDownload(url: "https://files.example.com/expired.zip", filename: "expired.zip")))
        // A sign-in page where the browser expected a PDF.
        #expect(await !downloads.takeOver(BridgeDownload(url: "https://files.example.com/login.pdf", filename: "login.pdf", mime: "application/pdf")))
        settings.takeoverKinds = [.document]
        #expect(await !downloads.takeOver(BridgeDownload(url: "https://files.example.com/photo.png", filename: "photo.png")))
        settings.browserTakeover = false
        #expect(await !downloads.takeOver(BridgeDownload(url: "https://files.example.com/report.pdf", filename: "report.pdf")))
        #expect(downloads.items.isEmpty)
    }

    @Test func pastedFileLinksDownloadWithoutYtDLP() async throws {
        let (downloads, _, folder) = makeDirectService()
        StubProtocol.set("https://files.example.com/notes.txt", status: 200, mime: "text/plain", body: Data("hi".utf8))
        #expect(downloads.download("https://files.example.com/notes.txt"))
        let item = try await finished(downloads)
        #expect(item.status == .done)
        #expect(item.filePath == folder.appendingPathComponent("notes.txt").path)
    }

    // MARK: Following the browser

    @Test func namesBrowserDownloads() {
        let folder = URL(fileURLWithPath: "/tmp/Notch")
        func name(_ file: String, _ source: String? = nil) -> String? {
            BrowserDownloadWatcher.displayName(for: folder.appendingPathComponent(file), source: source)
        }
        #expect(name("report.pdf.download") == "report.pdf")      // Safari
        #expect(name("photo.jpg.crdownload") == "photo.jpg")      // Chrome, once named
        #expect(name("Unconfirmed 972689.crdownload") == "Download")
        #expect(name("Unconfirmed 1.crdownload", "https://images.pexels.com/photos/1/pexels-photo.jpeg") == "pexels-photo.jpeg")
        #expect(name("setup.dmg.part") == "setup.dmg")            // Firefox
        #expect(BrowserDownloadWatcher.isDownload(folder.appendingPathComponent("a.zip.crdownload"), operation: nil))
        #expect(BrowserDownloadWatcher.isDownload(folder.appendingPathComponent("a.zip"), operation: .downloading))
        #expect(!BrowserDownloadWatcher.isDownload(folder.appendingPathComponent("a.zip"), operation: .copying))  // Finder copying in
    }

    @Test func readsWhenAFileWasDownloaded() {
        #expect(BrowserDownloadWatcher.quarantineDate("0081;6abfa74f;Safari;3492F8D9-82FD-42EC-8A99-86F3DF539D0A") == Date(timeIntervalSince1970: 0x6abfa74f))
        #expect(BrowserDownloadWatcher.quarantineDate("0083;6abfa74f;;") == Date(timeIntervalSince1970: 0x6abfa74f))
        #expect(BrowserDownloadWatcher.quarantineDate("garbage") == nil)
        #expect(BrowserDownloadWatcher.quarantineDate("0081;zz;Safari") == nil)
    }

    @Test func findsTheFinishedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchFollow-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("old.txt"))
        let before: Set<String> = ["old.txt"]

        // Safari: the temporary name minus ".download".
        try Data("pdf".utf8).write(to: folder.appendingPathComponent("report.pdf"))
        #expect(BrowserDownloadWatcher.finalFile(for: folder.appendingPathComponent("report.pdf.download"), in: folder, before: before)?.lastPathComponent == "report.pdf")

        // Chrome: "Unconfirmed …" is renamed at the end, so take the newest new file.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("report.pdf"))
        try Data("zip".utf8).write(to: folder.appendingPathComponent("archive.zip"))
        #expect(BrowserDownloadWatcher.finalFile(for: folder.appendingPathComponent("Unconfirmed 12.crdownload"), in: folder, before: before)?.lastPathComponent == "archive.zip")

        // Nothing new: no file.
        #expect(BrowserDownloadWatcher.finalFile(for: folder.appendingPathComponent("gone.zip.crdownload"), in: folder, before: before.union(["archive.zip"])) == nil)
    }

    @Test func followsABrowserDownload() throws {
        let (downloads, _, folder) = makeDirectService()
        var finished: [DownloadService.Item] = []
        downloads.onFinished = { finished.append($0) }
        let id = UUID()
        downloads.addFollowed(id, title: "Download", sourceURL: nil)
        downloads.followProgress(id, written: 50, expected: 100, title: "photo.jpg")
        #expect(downloads.items.first?.title == "photo.jpg")
        #expect(downloads.items.first?.isActive == true)
        #expect(downloads.progress[id]?.bytes == 50)

        let file = folder.appendingPathComponent("photo.jpg")
        downloads.followFinished(id, file: file)
        #expect(downloads.items.first?.status == .done)
        #expect(downloads.items.first?.filePath == file.path)
        #expect(finished.count == 1)  // peeks like any other download
    }

    @Test func cancellingAFollowedDownloadAsksTheBrowser() {
        let (downloads, _, _) = makeDirectService()
        var cancelled: [UUID] = []
        downloads.cancelFollowed = { cancelled.append($0) }
        let withLink = UUID(), withoutLink = UUID()
        downloads.addFollowed(withLink, title: "a.zip", sourceURL: "https://example.com/a.zip")
        downloads.addFollowed(withoutLink, title: "b.zip", sourceURL: nil)

        downloads.cancel(withLink)
        #expect(cancelled == [withLink])
        downloads.followEnded(withLink)  // the browser stops publishing: keep the cancelled tile
        #expect(downloads.items.first { $0.id == withLink }?.status == .cancelled)
        #expect(downloads.items.first { $0.id == withLink }?.canRetry == true)

        // Cancelled in the browser itself (or handed to Notch by the extension): just goes away.
        downloads.followEnded(withoutLink)
        #expect(!downloads.items.contains { $0.id == withoutLink })
    }

    private func makeDirectService() -> (DownloadService, SettingsStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDirect-\(UUID())", isDirectory: true)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        settings.downloadFolder = folder.path
        settings.browserTakeover = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let downloads = DownloadService(
            settings: settings,
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json"),
            sessionConfiguration: configuration
        )
        return (downloads, settings, folder)
    }

    /// Waits for the newest item to stop downloading.
    private func finished(_ downloads: DownloadService) async throws -> DownloadService.Item {
        for _ in 0..<200 {
            if let item = downloads.items.first, !item.isActive { return item }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(downloads.items.first)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}

/// Answers URLSession requests from a table instead of the network.
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, String, Data)] = [:]
    nonisolated(unsafe) private static var headers: [String: String] = [:]

    static func set(_ url: String, status: Int, mime: String, body: Data) {
        lock.withLock { responses[url] = (status, mime, body) }
    }

    static var lastHeaders: [String: String] { lock.withLock { headers } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, mime, body) = Self.lock.withLock({ Self.responses[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        Self.lock.withLock { Self.headers = request.allHTTPHeaderFields ?? [:] }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": "\(body.count)",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
