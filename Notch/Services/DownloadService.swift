import AppKit
import Observation

/// Saves videos (or their audio) from X, YouTube and the 1,000+ other sites yt-dlp supports,
/// and plain files (PDFs, archives, installers…) handed over by the browser extension or pasted.
///
/// yt-dlp and ffmpeg come from Homebrew; Notch can install and update them. Each video
/// download runs yt-dlp with machine-readable progress lines, one job at a time. Plain files
/// go through URLSession (`DirectDownloader`) and run side by side. History is kept in
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
        /// A plain file downloaded without yt-dlp. Optional so older history files still load.
        var direct: Bool?
        var expectedBytes: Int64?
        /// Downloaded by the browser itself; Notch only follows its progress.
        var followed: Bool?

        var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
        var isActive: Bool { status == .downloading || status == .finishing }
        var isDirect: Bool { direct == true }
        var isFollowed: Bool { followed == true }
        /// A plain file (not a yt-dlp video), whoever downloads it.
        var isFile: Bool { isDirect || isFollowed }
        /// Followed downloads can only be retried when the browser told us the link.
        var canRetry: Bool { !isFollowed || DownloadService.webURL(from: sourceURL) != nil }
        var kind: FileKind { FileKind.of(filename: filePath ?? title) }
    }

    struct Progress: Equatable {
        /// 0…1, or nil while the size isn't known yet.
        var fraction: Double?
        /// Bytes per second.
        var speed: Double?
        /// Seconds left.
        var eta: Int?
        /// Bytes so far (plain files only).
        var bytes: Int64?
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
    /// Asks the browser to stop a download Notch is following.
    @ObservationIgnored var cancelFollowed: ((UUID) -> Void)?

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

    @ObservationIgnored private let direct: DirectDownloader
    /// Cookie, Referer and User-Agent from the browser. In memory only, never saved.
    @ObservationIgnored private var directHeaders: [UUID: [String: String]] = [:]
    /// Items whose name came from the browser, so the server's suggestion doesn't replace it.
    @ObservationIgnored private var browserNamed: Set<UUID> = []
    @ObservationIgnored private var handoffs: [UUID: Handoff] = [:]
    @ObservationIgnored private var speedSamples: [UUID: SpeedSample] = [:]

    private struct Handoff {
        let continuation: CheckedContinuation<Bool, Never>
        let mime: String?
    }

    private struct SpeedSample {
        var date: Date
        var bytes: Int64
        var speed: Double?
    }

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    private static let lastUpdateKey = "downloaderLastUpdate"

    init(settings: SettingsStore, storeURL: URL? = nil, sessionConfiguration: URLSessionConfiguration = .default) {
        self.settings = settings
        self.storeURL = storeURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("downloads.json")
        direct = DirectDownloader(configuration: sessionConfiguration)
        load()
        direct.handlers = .init(
            response: { [weak self] in self?.directResponse($0, $1) ?? false },
            progress: { [weak self] in self?.directProgress($0, written: $1, expected: $2) },
            finished: { [weak self] in self?.directFinished($0, location: $1) },
            failed: { [weak self] in self?.directFailed($0, $1) }
        )
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
        if Self.isFileLink(url) {
            runDirect(addDirect(url: url, filename: nil, expectedBytes: nil))
            return true
        }
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
        if items[index].isFollowed {
            guard items[index].isActive else { return }
            cancelFollowed?(id)
            items[index].status = .cancelled
            progress[id] = nil
            save()
        } else if direct.isRunning(id) {
            direct.cancel(id)  // reported back through directFailed as cancelled
        } else if items[index].isActive, let process {
            cancelling.insert(id)
            process.interrupt()  // yt-dlp stops cleanly on SIGINT
        } else if items[index].status == .queued {
            items[index].status = .cancelled
            save()
        }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive else { return }
        if items[index].isFollowed {
            // The browser's copy is gone; Notch downloads it again itself.
            guard items[index].canRetry else { return }
            items[index].followed = nil
            items[index].direct = true
        }
        if items[index].isDirect {
            items[index].errorMessage = nil
            return runDirect(id)
        }
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
            publish(next, for: id)
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

    private func publish(_ next: Progress, for id: UUID) {
        // Progress arrives many times a second; only redraw when the percentage moves or a moment has passed.
        let old = progress[id]
        let percentChanged = old?.fraction.map { Int($0 * 100) } != next.fraction.map { Int($0 * 100) }
        if percentChanged || Date.now.timeIntervalSince(lastProgressUpdate) > 1 {
            progress[id] = next
            lastProgressUpdate = .now
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

    // MARK: Plain files

    /// From the browser extension: Notch downloads the file instead of the browser. Returns once
    /// the server has answered: true if Notch has it (the browser then drops its copy), false to
    /// let the browser carry on.
    func takeOver(_ request: BridgeDownload) async -> Bool {
        guard settings.browserTakeover, let url = Self.webURL(from: request.url) else { return false }
        var headers: [String: String] = [:]
        if let v = request.cookies, !v.isEmpty { headers["Cookie"] = v }
        if let v = request.referrer, !v.isEmpty { headers["Referer"] = v }
        if let v = request.userAgent, !v.isEmpty { headers["User-Agent"] = v }

        let id = addDirect(url: url, filename: request.filename, expectedBytes: request.totalBytes.flatMap { $0 > 0 ? $0 : nil })
        directHeaders[id] = headers
        // The extension gives up after 20 s and resumes its own copy, so never hold it longer.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.handoffTimeout))
            guard let self, let handoff = handoffs.removeValue(forKey: id) else { return }
            handoff.continuation.resume(returning: false)
            drop(id)
            direct.cancel(id)
        }
        return await withCheckedContinuation { continuation in
            handoffs[id] = Handoff(continuation: continuation, mime: request.mime)
            runDirect(id)
        }
    }

    static let handoffTimeout = 10.0

    /// A link straight to a file Notch can save itself (a PDF, a zip…) rather than a page for yt-dlp.
    static func isFileLink(_ url: URL) -> Bool {
        ![.other, .media].contains(FileKind.of(filename: url.lastPathComponent))
    }

    private func addDirect(url: URL, filename: String?, expectedBytes: Int64?) -> UUID {
        let browserName = filename.flatMap(Self.cleanFileName)
        let item = Item(
            id: UUID(), sourceURL: url.absoluteString,
            title: browserName ?? Self.cleanFileName(url.lastPathComponent) ?? url.host() ?? url.absoluteString,
            filePath: nil, thumbnailURL: nil, quality: settings.downloadQuality,
            created: .now, status: .downloading, errorMessage: nil, direct: true, expectedBytes: expectedBytes
        )
        if browserName != nil { browserNamed.insert(item.id) }
        items.insert(item, at: 0)
        save()
        return item.id
    }

    private func runDirect(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let url = URL(string: items[index].sourceURL) else { return }
        items[index].status = .downloading
        progress[id] = Progress()
        speedSamples[id] = nil
        var request = URLRequest(url: url)
        for (field, value) in directHeaders[id] ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
        direct.start(id, request: request)
    }

    /// Removes an item the browser keeps after all.
    private func drop(_ id: UUID) {
        items.removeAll { $0.id == id }
        progress[id] = nil
        directHeaders[id] = nil
        browserNamed.remove(id)
        save()
    }

    private func directResponse(_ id: UUID, _ response: URLResponse) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if !browserNamed.contains(id), let name = response.suggestedFilename.flatMap(Self.cleanFileName) {
            items[index].title = name
        }
        if response.expectedContentLength > 0 { items[index].expectedBytes = response.expectedContentLength }

        guard let handoff = handoffs.removeValue(forKey: id) else {
            if (200..<300).contains(status) { return true }
            items[index].status = .failed
            items[index].errorMessage = Self.httpError(status)
            progress[id] = nil
            onFailed?(items[index])
            save()
            return false
        }
        // An HTML page where the browser expected a file is usually a sign-in page: let the browser have it.
        let unexpectedPage = response.mimeType == "text/html" && handoff.mime?.contains("html") != true
        let kind = FileKind.of(filename: items[index].title, mime: response.mimeType ?? handoff.mime)
        let accepted = (200..<300).contains(status) && !unexpectedPage && settings.takeoverKinds.contains(kind)
        handoff.continuation.resume(returning: accepted)
        if accepted { save() } else { drop(id) }
        return accepted
    }

    private func directProgress(_ id: UUID, written: Int64, expected: Int64?) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let now = Date.now
        var sample = speedSamples[id] ?? SpeedSample(date: now, bytes: written)
        let elapsed = now.timeIntervalSince(sample.date)
        if elapsed >= 1 {
            sample.speed = Double(written - sample.bytes) / elapsed
            sample.date = now
            sample.bytes = written
        }
        speedSamples[id] = sample
        let total = expected ?? item.expectedBytes
        var eta: Int?
        if let total, let speed = sample.speed, speed > 0 { eta = Int(Double(max(total - written, 0)) / speed) }
        publish(Progress(fraction: total.map { min(Double(written) / Double(max($0, 1)), 0.99) }, speed: sample.speed, eta: eta, bytes: written), for: id)
    }

    private func directFinished(_ id: UUID, location: URL) {
        progress[id] = nil
        speedSamples[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(Self.uniqueFileName(items[index].title, in: folder))
            try FileManager.default.moveItem(at: location, to: destination)
            // URLSession's temporary files are private to us; browsers save files readable by others.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            if let source = URL(string: items[index].sourceURL) {
                Self.quarantine(destination, source: source, referrer: directHeaders[id]?["Referer"])
            }
            items[index].filePath = destination.path
            items[index].status = .done
            onFinished?(items[index])
        } catch {
            items[index].status = .failed
            items[index].errorMessage = "Couldn't save the file"
            onFailed?(items[index])
        }
        save()
    }

    private func directFailed(_ id: UUID, _ error: Error?) {
        progress[id] = nil
        speedSamples[id] = nil
        if let handoff = handoffs.removeValue(forKey: id) {
            // Couldn't even reach the server: the browser keeps its download.
            handoff.continuation.resume(returning: false)
            return drop(id)
        }
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        if (error as? URLError)?.code == .cancelled {
            items[index].status = .cancelled
        } else {
            items[index].status = .failed
            items[index].errorMessage = error?.localizedDescription ?? "Download failed"
            onFailed?(items[index])
        }
        save()
    }

    // MARK: Following the browser

    /// A download the browser started (see `BrowserDownloadWatcher`).
    func addFollowed(_ id: UUID, title: String, sourceURL: String?) {
        guard !items.contains(where: { $0.id == id }) else { return }
        items.insert(Item(
            id: id, sourceURL: sourceURL ?? "", title: title, filePath: nil, thumbnailURL: nil,
            quality: settings.downloadQuality, created: .now, status: .downloading, errorMessage: nil, followed: true
        ), at: 0)
        progress[id] = Progress()
        save()
    }

    func followProgress(_ id: UUID, written: Int64, expected: Int64?, title: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        if let title, title != items[index].title { items[index].title = title }
        if let expected, expected != items[index].expectedBytes { items[index].expectedBytes = expected }
        directProgress(id, written: written, expected: expected)
    }

    func followFinished(_ id: UUID, file: URL) {
        progress[id] = nil
        speedSamples[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        items[index].filePath = file.path
        items[index].title = file.lastPathComponent
        items[index].status = .done
        onFinished?(items[index])
        save()
    }

    /// The browser stopped without a file (cancelled there, or handed to Notch by the extension).
    func followEnded(_ id: UUID) {
        progress[id] = nil
        speedSamples[id] = nil
        guard let item = items.first(where: { $0.id == id }), item.isActive else { return }  // cancelled from Notch: keep it
        items.removeAll { $0.id == id }
        save()
    }

    static func httpError(_ status: Int) -> String {
        switch status {
        case 401, 403, 410: "Link expired — download it again in the browser"
        case 404: "File not found"
        default: "The server said no (\(status))"
        }
    }

    /// A safe single file name: no folders, no hidden-file dot, no control characters.
    static func cleanFileName(_ raw: String) -> String? {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        name = (name as NSString).lastPathComponent  // the browser may send a full path
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            name = String(stem.prefix(180)) + (ext.isEmpty ? "" : "." + ext)
        }
        return name.isEmpty || name == "/" ? nil : name
    }

    /// "report.pdf", then "report (1).pdf", "report (2).pdf"… like the browser does.
    static func uniqueFileName(_ name: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
        guard exists(folder.appendingPathComponent(name)) else { return name }
        let lower = name.lowercased()
        let compound = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"].first { lower.hasSuffix($0) && lower.count > $0.count }
        let ext = compound.map { String(name.suffix($0.count)) } ?? ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension)
        let stem = String(name.dropLast(ext.count))
        var n = 1
        while exists(folder.appendingPathComponent("\(stem) (\(n))\(ext)")) { n += 1 }
        return "\(stem) (\(n))\(ext)"
    }

    /// Marks the file as downloaded from the web, so Gatekeeper checks apps and disk images
    /// just as it would after a browser download.
    static func quarantine(_ file: URL, source: URL, referrer: String?) {
        var file = file
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Notch",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source,
        ]
        if let referrer = referrer.flatMap(URL.init(string:)) { properties[kLSQuarantineOriginURLKey as String] = referrer }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do { try file.setResourceValues(values) } catch { NSLog("Notch: couldn't mark download: \(error.localizedDescription)") }
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
        // A browser's unfinished download can't be followed again after a relaunch.
        stored.removeAll { $0.isFollowed && $0.status != .done }
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

/// What the browser extension sends for a download you clicked.
nonisolated struct BridgeDownload: Codable, Equatable, Sendable {
    var url: String
    var filename: String?
    var referrer: String?
    var mime: String?
    var totalBytes: Int64?
    var userAgent: String?
    var cookies: String?
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
