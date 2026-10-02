import Foundation
import Testing
@testable import Notch

@MainActor
struct ToolInstallerTests {
    @Test func readsChecksumLists() {
        let list = """
        1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp
        07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8  yt-dlp_macos.zip
        0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202 *yt-dlp_macos
        """
        #expect(ToolInstaller.checksum(named: "yt-dlp_macos.zip", in: list) == "07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8")
        #expect(ToolInstaller.checksum(named: "yt-dlp_macos", in: list) == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202")
        #expect(ToolInstaller.checksum(named: "yt-dlp.exe", in: list) == nil)
    }

    @Test func standardAssetsArePinned() {
        let assets = ToolInstaller.standardAssets
        #expect(Set(assets.map(\.tool)) == Set(ToolInstaller.Tool.allCases))
        for asset in assets {
            #expect(asset.url.scheme == "https")
            // Every file is checked: pinned, or against the release's own checksum list.
            #expect(asset.sha256?.count == 64 || asset.checksumsURL != nil)
        }
    }

    @Test func installsVerifiesAndPreparesEachTool() async throws {
        let (installer, folder) = try makeInstaller(tamper: false)
        var notified = false
        installer.onInstalled = { notified = true }
        installer.install()
        try await waitUntilDone(installer)

        #expect(installer.phase == .finished)
        #expect(notified)
        #expect(installer.isInstalled)
        #expect(installer.parts.values.allSatisfy { $0.step == .ready })
        // Laid out where DownloadService looks for them.
        let tools = DownloadService.findTools(managed: folder)
        #expect(tools.ytDLP == folder.appendingPathComponent("yt-dlp/yt-dlp_macos"))
        #expect(tools.ffmpeg == folder.appendingPathComponent("bin/ffmpeg"))
        #expect(tools.deno == folder.appendingPathComponent("bin/deno"))
        #expect(tools.isManaged)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bin/ffprobe").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("yt-dlp/_internal/lib.txt").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".staging").path))

        installer.remove()
        #expect(!installer.isInstalled)
    }

    @Test func refusesAFileThatFailsItsCheck() async throws {
        let (installer, folder) = try makeInstaller(tamper: true)
        installer.install()
        try await waitUntilDone(installer)
        guard case .failed(let message) = installer.phase else { Issue.record("expected failure"); return }
        #expect(message.contains("safety check"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("bin/ffmpeg").path))
    }

    // MARK: Helpers

    /// Stand-in tools: tiny scripts zipped like the real downloads.
    private func makeInstaller(tamper: Bool) throws -> (ToolInstaller, URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("NotchTools-\(UUID())", isDirectory: true)
        let folder = work.appendingPathComponent("Tools", isDirectory: true)
        let base = "https://tools-\(UUID().uuidString.prefix(8)).example.com"

        func script(_ name: String, in dir: URL) throws {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try "#!/bin/sh\necho \(name) 1.0\n".write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        func zip(_ source: URL, _ name: String) throws -> Data {
            let out = work.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", source.path, out.path]
            try p.run()
            p.waitUntilExit()
            return try Data(contentsOf: out)
        }

        let ytSource = work.appendingPathComponent("src-yt", isDirectory: true)
        try script("yt-dlp_macos", in: ytSource)
        try fm.createDirectory(at: ytSource.appendingPathComponent("_internal"), withIntermediateDirectories: true)
        try "x".write(to: ytSource.appendingPathComponent("_internal/lib.txt"), atomically: true, encoding: .utf8)
        var zips: [String: Data] = ["yt-dlp_macos.zip": try zip(ytSource, "yt-dlp_macos.zip")]
        for name in ["ffmpeg", "ffprobe", "deno"] {
            let dir = work.appendingPathComponent("src-\(name)", isDirectory: true)
            try script(name, in: dir)
            zips["\(name).zip"] = try zip(dir, "\(name).zip")
        }

        func sha(_ name: String) throws -> String {
            let file = work.appendingPathComponent(name)
            return try ToolInstaller.sha256(of: file)
        }
        for (name, data) in zips { StubProtocol.set("\(base)/\(name)", status: 200, mime: "application/zip", body: data) }
        // yt-dlp's checksum comes from a list, like the real release.
        StubProtocol.set("\(base)/SHA2-256SUMS", status: 200, mime: "text/plain", body: Data("\(try sha("yt-dlp_macos.zip"))  yt-dlp_macos.zip\n".utf8))

        let assets: [ToolInstaller.Asset] = [
            .init(tool: .ytDLP, url: URL(string: "\(base)/yt-dlp_macos.zip")!, checksumsURL: URL(string: "\(base)/SHA2-256SUMS")!,
                  size: 1000, install: .folder("yt-dlp", executable: "yt-dlp_macos")),
            .init(tool: .ffmpeg, url: URL(string: "\(base)/ffmpeg.zip")!, sha256: tamper ? String(repeating: "0", count: 64) : try sha("ffmpeg.zip"),
                  size: 1000, install: .binaries(["ffmpeg"])),
            .init(tool: .ffmpeg, url: URL(string: "\(base)/ffprobe.zip")!, sha256: try sha("ffprobe.zip"), size: 1000, install: .binaries(["ffprobe"])),
            .init(tool: .deno, url: URL(string: "\(base)/deno.zip")!, sha256: try sha("deno.zip"), size: 1000, install: .binaries(["deno"])),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (ToolInstaller(folder: folder, assets: assets, configuration: configuration), folder)
    }

    private func waitUntilDone(_ installer: ToolInstaller) async throws {
        for _ in 0..<500 where installer.phase == .running {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
