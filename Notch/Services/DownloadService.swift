import AppKit
import Observation

/// Saves videos (or their audio) from X, YouTube and the 1,000+ other sites yt-dlp supports.
///
/// yt-dlp and ffmpeg come from Homebrew; Notch can install and update them. Each download
/// runs yt-dlp with machine-readable progress lines, one job at a time. History is kept in
/// Application Support so finished files stay in the tab across relaunches.
@Observable
final class DownloadService {
    enum Status: String, Codable {
        case queued, downloading, finishing, done, failed, cancelled
    }

    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        let sourceURL: String
        var title: String
        var filePath: String?
        var thumbnailURL: String?
        var quality: DownloadQuality
        let created: Date
        var status: Status
        var errorMessage: String?

        var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
        var isActive: Bool { status == .downloading || status == .finishing }
    }

    struct Progress: Equatable {
        /// 0…1, or nil while the size isn't known yet.
        var fraction: Double?
        /// Bytes per second.
        var speed: Double?
        /// Seconds left.
        var eta: Int?
    }

    struct Tools: Equatable {
        var ytDLP: URL?
        var ffmpeg: URL?
        var brew: URL?
        var isReady: Bool { ytDLP != nil && ffmpeg != nil }
    }

    enum ToolTask: Equatable {
        case idle
        case running(String, lastLine: String)
        case failed(String)
    }

    /// Newest first.
    private(set) var items: [Item] = []
    private(set) var progress: [UUID: Progress] = [:]
    private(set) var tools = DownloadService.findTools()
    private(set) var toolTask: ToolTask = .idle

    var activeItem: Item? { items.first(where: \.isActive) }
    var finishedItems: [Item] { items.filter { $0.status == .done } }

    @ObservationIgnored var onFinished: ((Item) -> Void)?
    @ObservationIgnored var onFailed: ((Item) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var parser = ProgressParser()
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var cancelling: Set<UUID> = []
    @ObservationIgnored private var lastProgressUpdate = Date.distantPast
    @ObservationIgnored private var outBuffer = LineBuffer()
    @ObservationIgnored private var errBuffer = LineBuffer()
    @ObservationIgnored private var brewBuffer = LineBuffer()

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    private static let lastUpdateKey = "downloaderLastUpdate"

    init(settings: SettingsStore, storeURL: URL? = nil) {
        self.settings = settings
        self.storeURL = storeURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("downloads.json")
        load()
    }

    var folder: URL {
        settings.downloadFolder.isEmpty
            ? URL.downloadsDirectory
            : URL(fileURLWithPath: settings.downloadFolder, isDirectory: true)
    }

    // MARK: Downloads

    /// Accepts anything that looks like a web link. Returns false if it doesn't.
    @discardableResult
    func download(_ text: String, quality: DownloadQuality? = nil) -> Bool {
        guard let url = Self.webURL(from: text) else { return false }
        let item = Item(
            id: UUID(), sourceURL: url.absoluteString, title: url.host() ?? url.absoluteString,
            filePath: nil, thumbnailURL: nil, quality: quality ?? settings.downloadQuality,
            created: .now, status: .queued, errorMessage: nil
        )
        items.insert(item, at: 0)
        save()
        startNext()
        return true
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].isActive, let process {
            cancelling.insert(id)
            process.interrupt()  // yt-dlp stops cleanly on SIGINT
        } else if items[index].status == .queued {
            items[index].status = .cancelled
            save()
        }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive else { return }
        items[index].status = .queued
        items[index].errorMessage = nil
        save()
        startNext()
    }

    /// Removes from the list; with `trash`, also moves the file to the Trash.
    func remove(_ ids: Set<UUID>, trash: Bool = false) {
        for id in ids {
            if let item = items.first(where: { $0.id == id }) {
                if item.isActive { cancel(id) }
                if trash, let url = item.fileURL { NSWorkspace.shared.recycle([url]) }
            }
        }
        items.removeAll { ids.contains($0.id) && !$0.isActive }
        save()
    }

    func clearFinished() {
        items.removeAll { [.done, .failed, .cancelled].contains($0.status) }
        save()
    }

    /// Drops finished items whose files were deleted or moved. Called when the tab opens.
    func pruneMissing() {
        let before = items.count
        items.removeAll { $0.status == .done && !FileManager.default.fileExists(atPath: $0.filePath ?? "") }
        if items.count != before { save() }
    }

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    private func startNext() {
        guard process == nil, tools.isReady,
              let index = items.lastIndex(where: { $0.status == .queued })  // oldest queued first
        else { return }
        run(index)
    }

    private func run(_ index: Int) {
        guard let ytDLP = tools.ytDLP else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let id = items[index].id
        items[index].status = .downloading
        progress[id] = Progress()
        parser = ProgressParser()
        lastError = nil

        let p = Process()
        p.executableURL = ytDLP
        p.arguments = Self.arguments(
            url: items[index].sourceURL, quality: items[index].quality,
            compatibility: settings.videoCompatibility, naming: settings.fileNaming,
            folder: folder, cookies: settings.cookieBrowser, ffmpeg: tools.ffmpeg
        )
        p.environment = Self.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        outBuffer = LineBuffer()
        errBuffer = LineBuffer()
        let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(data, isError: false, id: id) }
            }
        }
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(data, isError: true, id: id) }
            }
        }
        p.terminationHandler = { [weak self] process in
            // Read whatever's left (e.g. the final file path) before reporting the result.
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            let restOut = outHandle.readDataToEndOfFile()
            let restErr = errHandle.readDataToEndOfFile()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.received(restOut, isError: false, id: id)
                    self?.received(restErr, isError: true, id: id)
                    self?.finished(id: id, status: status)
                }
            }
        }
        do {
            try p.run()
            process = p
            save()
        } catch {
            items[index].status = .failed
            items[index].errorMessage = "Couldn't start yt-dlp"
            save()
        }
    }

    private func received(_ data: Data, isError: Bool, id: UUID) {
        if isError {
            errBuffer.feed(data) { handle(line: $0, id: id) }
        } else {
            outBuffer.feed(data) { handle(line: $0, id: id) }
        }
    }

    private func handle(line: String, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch ProgressParser.Line(line) {
        case .title(let title):
            items[index].title = title
        case .thumbnail(let url):
            items[index].thumbnailURL = url
        case .size(let bytes):
            parser.expectedTotal = bytes
        case .progress(let downloaded, let total, let speed, let eta):
            let next = Progress(fraction: parser.fraction(downloaded: downloaded, total: total), speed: speed, eta: eta)
            // yt-dlp reports ~10× a second; only redraw when the percentage moves or a moment has passed.
            let old = progress[id]
            let percentChanged = old?.fraction.map { Int($0 * 100) } != next.fraction.map { Int($0 * 100) }
            if percentChanged || Date.now.timeIntervalSince(lastProgressUpdate) > 1 {
                progress[id] = next
                lastProgressUpdate = .now
            }
        case .postProcessing:
            items[index].status = .finishing
        case .file(let path):
            items[index].filePath = path
        case .error(let message):
            lastError = message
        case .other:
            break
        }
    }

    private func finished(id: UUID, status: Int32) {
        process = nil
        progress[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return startNext() }

        if cancelling.remove(id) != nil {
            items[index].status = .cancelled
        } else if status == 0, let path = items[index].filePath, FileManager.default.fileExists(atPath: path) {
            items[index].status = .done
            onFinished?(items[index])
        } else {
            items[index].status = .failed
            items[index].errorMessage = Self.friendlyError(lastError)
            onFailed?(items[index])
        }
        save()
        startNext()
        updateToolsIfDue()
    }

    // MARK: Tools

    static func findTools() -> Tools {
        func find(_ name: String) -> URL? {
            searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return Tools(ytDLP: find("yt-dlp"), ffmpeg: find("ffmpeg"), brew: find("brew"))
    }

    func refreshTools() {
        let found = Self.findTools()
        if found != tools { tools = found }
        startNext()
    }

    /// `brew install yt-dlp ffmpeg` — a few minutes the first time (ffmpeg is large).
    func installTools() {
        runBrew(["install", "yt-dlp", "ffmpeg"], title: "Installing yt-dlp and ffmpeg…")
    }

    func updateTools() {
        runBrew(["upgrade", "yt-dlp"], title: "Updating yt-dlp…")
    }

    /// At most once a day, and never during a download.
    func updateToolsIfDue() {
        guard settings.autoUpdateDownloader, tools.isReady, tools.brew != nil, process == nil, toolTask == .idle else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastUpdateKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 24 * 3600 else { return }
        UserDefaults.standard.set(Date.now, forKey: Self.lastUpdateKey)
        updateTools()
    }

    private func runBrew(_ arguments: [String], title: String) {
        guard let brew = tools.brew, case .idle = toolTask else { return }
        toolTask = .running(title, lastLine: "")
        let p = Process()
        p.executableURL = brew
        p.arguments = arguments
        var env = Self.environment
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        brewBuffer = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receivedBrew(data) }
            }
        }
        p.terminationHandler = { [weak self] process in
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.toolTask = ok ? .idle : .failed("Homebrew couldn't finish. Try `brew \(arguments.joined(separator: " "))` in Terminal.")
                    self.refreshTools()
                }
            }
        }
        do { try p.run() } catch { toolTask = .failed("Couldn't run Homebrew") }
    }

    private func receivedBrew(_ data: Data) {
        brewBuffer.feed(data) { line in
            guard case .running(let title, _) = toolTask else { return }
            toolTask = .running(title, lastLine: line)
        }
    }

    func dismissToolError() {
        if case .failed = toolTask { toolTask = .idle }
    }

    // MARK: Building the command

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    static func arguments(
        url: String, quality: DownloadQuality, compatibility: VideoCompatibility,
        naming: FileNaming, folder: URL, cookies: CookieBrowser, ffmpeg: URL?
    ) -> [String] {
        let name = naming == .title ? "%(title).180B.%(ext)s" : "%(title).160B [%(id)s].%(ext)s"
        var args = [
            "--quiet", "--progress", "--newline", "--no-playlist", "--no-mtime", "--no-simulate",
            "--progress-template", "download:NOTCH_PROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
            "--print", "before_dl:NOTCH_TITLE %(title)s",
            "--print", "before_dl:NOTCH_THUMB %(thumbnail)s",
            "--print", "before_dl:NOTCH_SIZE %(filesize,filesize_approx)s",
            "--print", "post_process:NOTCH_POST %(id)s",
            "--print", "after_move:NOTCH_FILE %(filepath)s",
            "-o", folder.appendingPathComponent(name).path,
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }

        switch quality {
        case .audio:
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        default:
            let cap: String? = switch quality {
            case .p1080: "res:1080"
            case .p720: "res:720"
            default: nil
            }
            // Format sorting: the first field matters most.
            let sort: [String] = compatibility == .quickTime
                ? [cap, "vcodec:h264", "res", "acodec:aac"].compactMap { $0 }
                : [cap ?? "res", "fps"]
            args += ["-f", "bv*+ba/b", "-S", sort.joined(separator: ","), "--merge-output-format", "mp4"]
        }
        if cookies != .none { args += ["--cookies-from-browser", cookies.rawValue] }
        return args + ["--", url]
    }

    /// Pulls the first http(s) link out of pasted text.
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        let withScheme = candidate.contains("://") ? candidate : "https://" + candidate
        guard let url = URL(string: withScheme), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(), host.contains(".")
        else { return nil }
        return url
    }

    static func friendlyError(_ raw: String?) -> String {
        guard let raw else { return "Download failed" }
        let lower = raw.lowercased()
        if lower.contains("unsupported url") { return "This site isn't supported" }
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") {
            return "Needs you to be signed in — choose your browser under Settings › Activities › Downloads"
        }
        if lower.contains("private") { return "This video is private" }
        if lower.contains("not available") || lower.contains("unavailable") { return "This video isn't available" }
        if lower.contains("ffmpeg") { return "ffmpeg is missing — install it from Settings" }
        if lower.contains("http error 403") || lower.contains("extract") {
            return "The site changed — update yt-dlp in Settings and try again"
        }
        return raw.replacingOccurrences(of: "ERROR: ", with: "")
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var stored = try? JSONDecoder().decode([Item].self, from: data)
        else { return }
        // Anything that was mid-download when Notch quit can be retried.
        for i in stored.indices where [.queued, .downloading, .finishing].contains(stored[i].status) {
            stored[i].status = .failed
            stored[i].errorMessage = "Interrupted — click to retry"
        }
        items = stored
        pruneMissing()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Notch: couldn't save downloads: \(error.localizedDescription)")
        }
    }
}

// MARK: - Parsing yt-dlp's output

/// Turns yt-dlp's "NOTCH_…" lines into progress, and combines video + audio parts
/// (which yt-dlp downloads one after the other) into one overall fraction.
struct ProgressParser {
    enum Line: Equatable {
        case title(String)
        case thumbnail(String)
        case size(Double)
        case progress(downloaded: Double, total: Double?, speed: Double?, eta: Int?)
        case postProcessing
        case file(String)
        case error(String)
        case other

        init(_ raw: String) {
            func value(_ prefix: String) -> String? {
                raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : nil
            }
            func number(_ s: Substring) -> Double? { s == "NA" || s == "None" ? nil : Double(s) }

            if let v = value("NOTCH_TITLE ") {
                self = .title(v)
            } else if let v = value("NOTCH_THUMB ") {
                self = v == "NA" ? .other : .thumbnail(v)
            } else if let v = value("NOTCH_SIZE ") {
                self = Double(v).map(Line.size) ?? .other
            } else if let v = value("NOTCH_PROGRESS ") {
                let parts = v.split(separator: " ")
                guard parts.count == 5, let downloaded = number(parts[0]) else { self = .other; return }
                self = .progress(
                    downloaded: downloaded, total: number(parts[1]) ?? number(parts[2]),
                    speed: number(parts[3]), eta: number(parts[4]).map { Int($0) }
                )
            } else if raw.hasPrefix("NOTCH_POST") {
                self = .postProcessing
            } else if let v = value("NOTCH_FILE ") {
                self = .file(v)
            } else if raw.hasPrefix("ERROR:") {
                self = .error(raw)
            } else {
                self = .other
            }
        }
    }

    /// The whole download's size, when yt-dlp knows it up front.
    var expectedTotal: Double?
    private var finishedParts: Double = 0
    private var lastDownloaded: Double = 0
    private var lastTotal: Double = 0

    mutating func fraction(downloaded: Double, total: Double?) -> Double? {
        // A new part (e.g. the audio after the video) starts again from zero.
        if downloaded + 1 < lastDownloaded { finishedParts += lastTotal }
        lastDownloaded = downloaded
        lastTotal = total ?? lastTotal
        let done = finishedParts + downloaded
        if let expectedTotal, expectedTotal > 0 { return min(done / expectedTotal, 0.99) }
        guard let total, total > 0 else { return nil }
        return min(downloaded / total, 0.99)
    }
}

/// Splits a byte stream into lines.
struct LineBuffer {
    private var data = Data()

    mutating func feed(_ chunk: Data, _ onLine: (String) -> Void) {
        data.append(chunk)
        while let newline = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            data.removeSubrange(data.startIndex...newline)
            if !line.isEmpty { onLine(line) }
        }
    }
}
