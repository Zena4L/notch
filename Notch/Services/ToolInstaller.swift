import CryptoKit
import Foundation
import Observation

/// Sets up the tools video downloads need (yt-dlp, FFmpeg and Deno) with one click: no
/// Homebrew, no Terminal.
///
/// Everything goes into ~/Library/Application Support/Notch/Tools, and every file is checked
/// against a SHA-256 checksum before it's used. FFmpeg and Deno are pinned to builds tested with
/// this version of Notch. yt-dlp follows its latest release, because sites change often, and is
/// checked against that release's published checksums. After unpacking, each tool runs once:
/// macOS inspects a new program the first time it runs (about 20 s for yt-dlp), and doing that
/// here keeps the first real download quick.
@Observable
final class ToolInstaller {
    nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
        case ytDLP, ffmpeg, deno

        var id: Self { self }
        var title: String {
            switch self {
            case .ytDLP: "yt-dlp"
            case .ffmpeg: "FFmpeg"
            case .deno: "Deno"
            }
        }
        var role: String {
            switch self {
            case .ytDLP: "Video engine"
            case .ffmpeg: "Converter"
            case .deno: "YouTube helper"
            }
        }
        var symbol: String {
            switch self {
            case .ytDLP: "play.rectangle.fill"
            case .ffmpeg: "waveform"
            case .deno: "curlybraces"
            }
        }
    }

    enum Step: Equatable {
        case waiting, downloading, verifying, unpacking, preparing, ready, failed
    }

    struct Part: Equatable {
        var step: Step = .waiting
        var received: Int64 = 0
        var total: Int64 = 0
    }

    enum Phase: Equatable {
        case idle, running, finished
        case failed(String)
    }

    /// One zip to download. A tool can have several (FFmpeg comes with ffprobe).
    struct Asset: Sendable {
        enum Install: Sendable, Equatable {
            /// Single programs at the top of the zip, installed into Tools/bin.
            case binaries([String])
            /// A whole folder with its program, installed as Tools/<folder>.
            case folder(String, executable: String)
        }

        let tool: Tool
        let url: URL
        /// Expected checksum, or nil to read it from `checksumsURL`.
        var sha256: String?
        /// A SHA2-256SUMS file that lists this zip by name.
        var checksumsURL: URL?
        /// Roughly how big it is, for progress before the server answers.
        let size: Int64
        let install: Install
        /// Other places with the same file, tried when `url` is slow or down. Same checksum.
        var mirrors: [URL] = []
    }

    private(set) var phase: Phase = .idle
    private(set) var parts: [Tool: Part] = [:]
    /// Bytes per second across all downloads.
    private(set) var speed: Double?
    /// A background yt-dlp update is in progress.
    private(set) var isUpdating = false

    /// Called on the main actor when tools were installed or updated.
    @ObservationIgnored var onInstalled: (() -> Void)?
    /// Whether it's safe to swap yt-dlp right now (no download using it).
    @ObservationIgnored var canSwap: () -> Bool = { true }

    @ObservationIgnored let folder: URL
    @ObservationIgnored private let assets: [Asset]
    @ObservationIgnored private let downloader: DirectDownloader
    @ObservationIgnored private var fetches: [UUID: Fetch] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSample: (date: Date, bytes: Int64)?

    private struct Fetch {
        let destination: URL
        let progress: @MainActor (Int64, Int64?) -> Void
        let continuation: CheckedContinuation<URL, Error>
    }

    static let defaultFolder = URL.applicationSupportDirectory
        .appendingPathComponent("Notch", isDirectory: true)
        .appendingPathComponent("Tools", isDirectory: true)

    init(folder: URL = ToolInstaller.defaultFolder, assets: [Asset] = ToolInstaller.standardAssets, configuration: URLSessionConfiguration = .default) {
        self.folder = folder
        self.assets = assets
        // Give up on a stalled connection after 30 s of silence (then retry), not URLSession's 60.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        downloader = DirectDownloader(configuration: configuration)
        resetParts()
        downloader.handlers = .init(
            response: { _, response in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                return (200..<300).contains(status)
            },
            progress: { [weak self] id, written, expected in self?.fetches[id]?.progress(written, expected) },
            finished: { [weak self] id, location in self?.fetched(id, location: location) },
            failed: { [weak self] id, error in
                guard let fetch = self?.fetches.removeValue(forKey: id) else { return }
                fetch.continuation.resume(throwing: error ?? URLError(.badServerResponse))
            }
        )
    }

    // MARK: Where things go

    var binFolder: URL { folder.appendingPathComponent("bin", isDirectory: true) }

    /// The installed program for each tool, if it's there.
    var installed: [Tool: URL] {
        var found: [Tool: URL] = [:]
        for asset in assets {
            guard found[asset.tool] == nil, let program = program(for: asset),
                  FileManager.default.isExecutableFile(atPath: program.path) else { continue }
            found[asset.tool] = program
        }
        return found
    }

    var isInstalled: Bool { Set(installed.keys) == Set(assets.map(\.tool)) }

    /// Total download size, for the Set Up button.
    var downloadSize: Int64 { assets.reduce(0) { $0 + $1.size } }

    /// How much disk space the tools use.
    func diskUsage() -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    private func program(for asset: Asset) -> URL? {
        switch asset.install {
        case .binaries(let names): names.first.map { binFolder.appendingPathComponent($0) }
        case .folder(let name, let executable): folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent(executable)
        }
    }

    private func programs(for asset: Asset) -> [URL] {
        switch asset.install {
        case .binaries(let names): names.map { binFolder.appendingPathComponent($0) }
        case .folder: program(for: asset).map { [$0] } ?? []
        }
    }

    // MARK: Installing

    /// Overall progress, 0…1: downloading is most of it, then checking and preparing.
    var fraction: Double {
        let total = parts.values.reduce(0) { $0 + max($1.total, 1) }
        // Tools already in place count as fully downloaded.
        let received = parts.values.reduce(0) { $0 + ($1.step == .ready ? max($1.total, 1) : min($1.received, max($1.total, 1))) }
        let ready = parts.values.filter { $0.step == .ready }.count
        let downloaded = total > 0 ? Double(received) / Double(total) : 0
        return min(1, downloaded * 0.85 + Double(ready) / Double(max(parts.count, 1)) * 0.15)
    }

    func install() {
        guard phase != .running else { return }
        phase = .running
        resetParts()
        speed = nil
        lastSample = nil
        // After a failed attempt, keep what's already in place and fetch only the rest.
        let missing = Set(assets.map(\.tool)).subtracting(installed.keys)
        for tool in Set(assets.map(\.tool)).subtracting(missing) { set(tool, step: .ready) }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // All at once; if one fails, stop the others.
                let jobs = missing.map { tool in Task { try await self.install(tool) } }
                try await withTaskCancellationHandler {
                    do {
                        for job in jobs { try await job.value }
                    } catch {
                        jobs.forEach { $0.cancel() }
                        throw error
                    }
                } onCancel: {
                    jobs.forEach { $0.cancel() }
                }
                cleanUpStaging()
                phase = .finished
                onInstalled?()
            } catch is CancellationError {
                cleanUpStaging()
                phase = .idle
                resetParts()
            } catch {
                cleanUpStaging()
                cancelFetches()
                phase = .failed(Self.friendly(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        cancelFetches()
    }

    /// After the "You're all set" moment.
    func acknowledge() {
        if phase == .finished { phase = .idle }
    }

    /// Back to the start after a failure.
    func dismissError() {
        if case .failed = phase {
            phase = .idle
            resetParts()
        }
    }

    /// Deletes the tools (Settings › Remove). Homebrew's, if any, are left alone.
    func remove() {
        guard phase != .running, !isUpdating else { return }
        try? FileManager.default.removeItem(at: folder)
        phase = .idle
        resetParts()
        onInstalled?()
    }

    private func install(_ tool: Tool) async throws {
        let mine = assets.filter { $0.tool == tool }
        var staged: [(Asset, URL)] = []
        for asset in mine {
            try Task.checkCancellation()
            staged.append((asset, try await stage(asset, reportingTo: tool)))
        }
        set(tool, step: .preparing)
        try await place(staged)
        try await warmUp(staged.map(\.0))
        set(tool, step: .ready)
    }

    /// Downloads, checks and unpacks one zip into a staging folder.
    private func stage(_ asset: Asset, reportingTo tool: Tool?) async throws -> URL {
        let staging = folder.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        if let tool { set(tool, step: .downloading) }
        let expected = try await expectedChecksum(for: asset)
        let zip = try await fetchWithRetries([asset.url] + asset.mirrors, to: staging.appendingPathComponent(asset.url.lastPathComponent)) { [weak self] written, total in
            guard let self, let tool else { return }
            self.received(written, total: total, for: asset, tool: tool)
        }

        if let tool { set(tool, step: .verifying) }
        let actual = try await Task.detached { try Self.sha256(of: zip) }.value
        guard actual.lowercased() == expected.lowercased() else { throw InstallError.checksum(asset.tool) }

        if let tool { set(tool, step: .unpacking) }
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        let status = try await Self.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path]).status
        guard status == 0 else { throw InstallError.unpack(asset.tool) }
        try? FileManager.default.removeItem(at: zip)
        return unpacked
    }

    /// Moves unpacked tools into place. Each replace is a quick rename.
    private func place(_ staged: [(Asset, URL)]) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binFolder, withIntermediateDirectories: true)
        // Don't pull yt-dlp out from under a running download.
        while !canSwap() { try await Task.sleep(for: .seconds(2)) }
        for (asset, unpacked) in staged {
            switch asset.install {
            case .binaries(let names):
                for name in names {
                    let source = unpacked.appendingPathComponent(name)
                    guard fm.fileExists(atPath: source.path) else { throw InstallError.unpack(asset.tool) }
                    try Self.replace(binFolder.appendingPathComponent(name), with: source)
                }
            case .folder(let name, let executable):
                guard fm.fileExists(atPath: unpacked.appendingPathComponent(executable).path) else { throw InstallError.unpack(asset.tool) }
                try Self.replace(folder.appendingPathComponent(name, isDirectory: true), with: unpacked)
            }
        }
    }

    /// The first run of a new program is slow while macOS checks it; get that over with now.
    private func warmUp(_ assets: [Asset]) async throws {
        for asset in assets {
            for program in programs(for: asset) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
                let flag = program.lastPathComponent.hasPrefix("ff") ? "-version" : "--version"
                guard try await Self.run(program, [flag]).status == 0 else { throw InstallError.run(asset.tool) }
            }
        }
    }

    // MARK: Updating yt-dlp

    /// Fetches a newer yt-dlp if there is one. Quiet: a failure just tries again next time.
    func updateYtDLP() async {
        guard phase != .running, !isUpdating, let asset = assets.first(where: { $0.tool == .ytDLP }),
              let current = installed[.ytDLP] else { return }
        isUpdating = true
        defer { isUpdating = false; cleanUpStaging() }
        do {
            let installedVersion = try await Self.run(current, ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let latest = try await Self.latestYtDLPVersion()
            guard let latest, latest != installedVersion else { return }
            let unpacked = try await stage(asset, reportingTo: nil)
            // Run it once from staging, so the slow first launch happens before it's in use.
            if case .folder(_, let executable) = asset.install {
                _ = try await Self.run(unpacked.appendingPathComponent(executable), ["--version"])
            }
            try await place([(asset, unpacked)])
            onInstalled?()
        } catch {
            NSLog("Notch: couldn't update yt-dlp: \(error.localizedDescription)")
        }
    }

    nonisolated static func latestYtDLPVersion() async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String
    }

    // MARK: Plumbing

    private func expectedChecksum(for asset: Asset) async throws -> String {
        if let sha = asset.sha256 { return sha }
        guard let list = asset.checksumsURL else { throw InstallError.checksum(asset.tool) }
        let file = try await fetch(list, to: folder.appendingPathComponent(".staging/\(UUID().uuidString)-SUMS")) { _, _ in }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: file)
        guard let sha = Self.checksum(named: asset.url.lastPathComponent, in: text) else { throw InstallError.checksum(asset.tool) }
        return sha
    }

    /// Retries dropped or stalled connections, carrying on from where they stopped, and moves
    /// to a mirror if the same source fails twice.
    private func fetchWithRetries(_ urls: [URL], to destination: URL, progress: @escaping @MainActor (Int64, Int64?) -> Void) async throws -> URL {
        var resumeData: Data?
        var source = 0
        var failuresHere = 0
        for attempt in 1...Self.attempts {
            do {
                return try await fetch(urls[source], to: destination, resumingFrom: resumeData, progress: progress)
            } catch let error as URLError where attempt < Self.attempts && Self.isWorthRetrying(error) {
                failuresHere += 1
                if failuresHere >= 2, source + 1 < urls.count {
                    source += 1
                    failuresHere = 0
                    resumeData = nil  // only good for the same server
                } else {
                    resumeData = DirectDownloader.resumeData(from: error) ?? resumeData
                }
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
        throw URLError(.networkConnectionLost)
    }

    static let attempts = 4

    nonisolated static func isWorthRetrying(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost]
            .contains(error.code)
    }

    private func fetch(_ url: URL, to destination: URL, resumingFrom resumeData: Data? = nil, progress: @escaping @MainActor (Int64, Int64?) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetches[id] = Fetch(destination: destination, progress: progress, continuation: continuation)
                if let resumeData {
                    downloader.resume(id, from: resumeData)
                } else {
                    downloader.start(id, request: URLRequest(url: url))
                }
            }
        } onCancel: { [downloader] in
            downloader.cancel(id)
        }
    }

    private func fetched(_ id: UUID, location: URL) {
        guard let fetch = fetches.removeValue(forKey: id) else { return }
        do {
            try FileManager.default.createDirectory(at: fetch.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: fetch.destination)
            try FileManager.default.moveItem(at: location, to: fetch.destination)
            fetch.continuation.resume(returning: fetch.destination)
        } catch {
            fetch.continuation.resume(throwing: error)
        }
    }

    private func cancelFetches() {
        for id in fetches.keys { downloader.cancel(id) }
    }

    private func received(_ written: Int64, total: Int64?, for asset: Asset, tool: Tool) {
        // Several zips can feed one tool; track each by URL and add them up.
        assetBytes[asset.url] = (written, total ?? asset.size)
        let mine = assets.filter { $0.tool == tool }
        parts[tool]?.received = mine.reduce(0) { $0 + (assetBytes[$1.url]?.received ?? 0) }
        parts[tool]?.total = mine.reduce(0) { $0 + (assetBytes[$1.url]?.total ?? $1.size) }

        let all = assetBytes.values.reduce(0) { $0 + $1.received }
        let now = Date.now
        if let last = lastSample {
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed >= 1 {
                speed = Double(all - last.bytes) / elapsed
                lastSample = (now, all)
            }
        } else {
            lastSample = (now, all)
        }
    }

    @ObservationIgnored private var assetBytes: [URL: (received: Int64, total: Int64)] = [:]

    private func set(_ tool: Tool, step: Step) {
        parts[tool]?.step = step
    }

    private func resetParts() {
        assetBytes = [:]
        var fresh: [Tool: Part] = [:]
        for asset in assets {
            fresh[asset.tool, default: Part()].total += asset.size
        }
        for (tool, _) in installed where fresh[tool] != nil && phase != .running {
            fresh[tool]?.step = .ready
        }
        parts = fresh
    }

    private func cleanUpStaging() {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".staging", isDirectory: true))
    }

    enum InstallError: LocalizedError {
        case checksum(Tool), unpack(Tool), run(Tool)

        var errorDescription: String? {
            switch self {
            case .checksum(let tool): "\(tool.title) didn't pass its safety check, so it wasn't installed"
            case .unpack(let tool): "Couldn't unpack \(tool.title)"
            case .run(let tool): "\(tool.title) didn't start on this Mac"
            }
        }
    }

    nonisolated static func friendly(_ error: Error) -> String {
        if let error = error as? InstallError { return error.errorDescription ?? "Setup failed" }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline. Connect to the internet and try again"
            case .timedOut: return "The download timed out. Try again"
            default: return "Couldn't download the tools. Try again in a moment"
            }
        }
        return error.localizedDescription
    }

    // MARK: Helpers

    /// Finds `name` in a "checksum  filename" list like yt-dlp's SHA2-256SUMS.
    nonisolated static func checksum(named name: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            if fields.last.map({ $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }) == name,
               fields[0].count == 64 { return String(fields[0]) }
        }
        return nil
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Swaps in a new file or folder; the old one goes only once the new one is in place.
    nonisolated static func replace(_ target: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: target)
        }
    }

    nonisolated static func run(_ program: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - What to download

extension ToolInstaller {
    /// FFmpeg from martin-riedl.de (static builds, signed) and Deno from its official CDN are
    /// pinned with their checksums. To move to newer builds, update the URLs and checksums here.
    static var standardAssets: [Asset] {
        let ytDLP = Asset(
            tool: .ytDLP,
            url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!,
            checksumsURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!,
            size: 53_923_637,
            install: .folder("yt-dlp", executable: "yt-dlp_macos")
        )
        let ffmpegBase = "https://ffmpeg.martin-riedl.de/download/macos"
        // Deno's own CDN is much faster than GitHub's downloads; GitHub is the backup.
        let denoBase = "https://dl.deno.land/release/v2.9.7"
        let denoMirror = "https://github.com/denoland/deno/releases/download/v2.9.7"
        #if arch(arm64)
        return [
            ytDLP,
            Asset(tool: .ffmpeg, url: URL(string: "\(ffmpegBase)/arm64/1789931890_9.0.2/ffmpeg.zip")!,
                  sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924", size: 28_395_699, install: .binaries(["ffmpeg"])),
            Asset(tool: .ffmpeg, url: URL(string: "\(ffmpegBase)/arm64/1789931890_9.0.2/ffprobe.zip")!,
                  sha256: "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6", size: 28_317_701, install: .binaries(["ffprobe"])),
            Asset(tool: .deno, url: URL(string: "\(denoBase)/deno-aarch64-apple-darwin.zip")!,
                  sha256: "5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c", size: 38_469_316, install: .binaries(["deno"]),
                  mirrors: [URL(string: "\(denoMirror)/deno-aarch64-apple-darwin.zip")!]),
        ]
        #else
        return [
            ytDLP,
            Asset(tool: .ffmpeg, url: URL(string: "\(ffmpegBase)/amd64/1789931006_9.0.2/ffmpeg.zip")!,
                  sha256: "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4", size: 33_816_391, install: .binaries(["ffmpeg"])),
            Asset(tool: .ffmpeg, url: URL(string: "\(ffmpegBase)/amd64/1789931006_9.0.2/ffprobe.zip")!,
                  sha256: "2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd", size: 33_719_233, install: .binaries(["ffprobe"])),
            Asset(tool: .deno, url: URL(string: "\(denoBase)/deno-x86_64-apple-darwin.zip")!,
                  sha256: "95daaff11c116a52ad54785e7914c8e9c9cdcaba793c5ed929c74ca2d8e6259a", size: 42_295_422, install: .binaries(["deno"]),
                  mirrors: [URL(string: "\(denoMirror)/deno-x86_64-apple-darwin.zip")!]),
        ]
        #endif
    }
}
