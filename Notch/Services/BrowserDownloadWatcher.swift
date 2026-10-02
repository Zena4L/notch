import Foundation

/// Shows the downloads Safari, Chrome, Brave, Edge and Arc make in the island, with no extension.
///
/// Browsers publish each download's progress to the system (that's how Finder draws the bar on
/// a file that's still arriving). We subscribe to it for the Downloads folder, so we learn
/// about a download as it starts, how far along it is, and can cancel it. The browser still
/// does the downloading. Progress is read twice a second, only while something is downloading.
///
/// Chrome-based browsers don't publish progress for downloads that finish within about a
/// second (a photo, a small PDF), so we also watch the folder: a new file the browser has just
/// marked as downloaded from the web shows up as a finished download.
final class BrowserDownloadWatcher {
    private let settings: SettingsStore
    private let downloads: DownloadService
    private let folder: URL
    private var subscription: Any?
    private var tracked: [UUID: Tracked] = [:]
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var folderSource: DispatchSourceFileSystemObject?
    private var knownNames: Set<String> = []

    /// Progress is thread-safe; this lets us hand it to the main actor.
    nonisolated final class Box: @unchecked Sendable {
        let progress: Progress
        init(_ progress: Progress) { self.progress = progress }
    }

    private struct Tracked {
        let box: Box
        let started: Date
        /// What was in the folder before, to find the file if the browser renames it at the end.
        let before: Set<String>
        var shown = false
        var lastFile: URL?
        var lastWritten: Int64 = 0
    }

    /// How long a download must run before it appears, so ones the extension hands to Notch
    /// (paused, then cancelled by the browser) don't flash up twice.
    static let showAfter: TimeInterval = 1
    /// How long a new file sits before we look at it, so progress-tracked downloads (which
    /// resolve their file 0.5 s after finishing) claim it first and Safari can finish unzipping.
    static let settleDelay: TimeInterval = 1.5
    /// Only files the browser marked as downloaded this recently count as new downloads.
    static let recentWindow: TimeInterval = 120
    nonisolated static let temporarySuffixes = [".download", ".crdownload", ".part"]

    init(settings: SettingsStore, downloads: DownloadService, folder: URL = .downloadsDirectory) {
        self.settings = settings
        self.downloads = downloads
        self.folder = folder
        downloads.cancelFollowed = { [weak self] id in self?.tracked[id]?.box.progress.cancel() }
        observer = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(["followBrowserDownloads", "downloadsEnabled"]) else { return }
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let on = settings.followBrowserDownloads && settings.downloadsEnabled
        if on, subscription == nil {
            subscription = Progress.addSubscriber(forFileURL: folder, withPublishingHandler: Self.handler { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            })
            watchFolder()
        } else if !on, let subscription {
            Progress.removeSubscriber(subscription)
            self.subscription = nil
            folderSource?.cancel()
            folderSource = nil
            for id in tracked.keys { downloads.followEnded(id) }
            tracked = [:]
            stopTimer()
        }
    }

    private enum Event {
        case published(UUID, Box)
        case unpublished(UUID)
    }

    /// Built outside the main actor: Foundation calls it on its own queue.
    nonisolated private static func handler(_ send: @escaping @Sendable (Event) -> Void) -> Progress.PublishingHandler {
        { progress in
            let id = UUID()
            let box = Box(progress)
            DispatchQueue.main.async { send(.published(id, box)) }
            return { DispatchQueue.main.async { send(.unpublished(id)) } }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .published(let id, let box):
            guard box.progress.kind == .file || box.progress.kind == nil else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            tracked[id] = Tracked(box: box, started: .now, before: Set(names))
            startTimer()
            poll()
        case .unpublished(let id):
            guard let entry = tracked.removeValue(forKey: id) else { return }
            if tracked.isEmpty { stopTimer() }
            finish(id, entry)
        }
    }

    // MARK: Polling

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        for (id, var entry) in tracked {
            let progress = entry.box.progress
            let file = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL
            if let file { entry.lastFile = file }
            guard let file = entry.lastFile, Self.isDownload(file, operation: progress.fileOperationKind) else {
                tracked[id] = entry
                continue
            }
            let written = max(progress.completedUnitCount, 0)
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            entry.lastWritten = written
            if !entry.shown, !progress.isPaused, Date.now.timeIntervalSince(entry.started) >= Self.showAfter {
                entry.shown = true
                let source = (progress.userInfo[ProgressUserInfoKey("NSProgressFileDownloadingSourceURL")] as? URL)?.absoluteString
                downloads.addFollowed(id, title: Self.displayName(for: file, source: source) ?? "Download", sourceURL: source)
            }
            if entry.shown {
                downloads.followProgress(id, written: written, expected: total, title: Self.displayName(for: file, source: nil, keepUnknown: false))
            }
            tracked[id] = entry
        }
    }

    private func finish(_ id: UUID, _ entry: Tracked) {
        let progress = entry.box.progress
        let temp = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL ?? entry.lastFile
        let complete = !progress.isCancelled && progress.totalUnitCount > 0 && progress.completedUnitCount >= progress.totalUnitCount
        guard complete, let temp, Self.isDownload(temp, operation: progress.fileOperationKind) else {
            if entry.shown { downloads.followEnded(id) }
            return
        }
        // Small files (a photo from Pexels) often finish before `showAfter`; show them anyway.
        // Only unfinished ones are held back, since those may be the extension's hand-offs.
        if !entry.shown {
            let source = (progress.userInfo[ProgressUserInfoKey("NSProgressFileDownloadingSourceURL")] as? URL)?.absoluteString
            downloads.addFollowed(id, title: Self.displayName(for: temp, source: source) ?? "Download", sourceURL: source)
        }
        // Browsers rename the file just after they stop publishing; give them a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let file = Self.finalFile(for: temp, in: self.folder, before: entry.before) {
                    self.downloads.followFinished(id, file: file)
                } else {
                    self.downloads.followEnded(id)
                }
            }
        }
    }

    // MARK: Watching the folder

    private func watchFolder() {
        let path = folder.path
        // The first look at Downloads waits while macOS asks for permission; never on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (names, fd) = Self.open(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.subscription != nil, self.folderSource == nil, fd >= 0 else {
                        if fd >= 0 { close(fd) }
                        return
                    }
                    self.knownNames = names
                    self.watch(fd)
                }
            }
        }
    }

    nonisolated private static func open(_ path: String) -> (Set<String>, Int32) {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        return (names, Darwin.open(path, O_EVTONLY))
    }

    private func watch(_ fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }

    private func folderChanged() {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let added = names.subtracting(knownNames)
        knownNames = names
        for name in added where !name.hasPrefix(".") && !Self.temporarySuffixes.contains(where: name.hasSuffix) {
            let file = folder.appendingPathComponent(name)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
                MainActor.assumeIsolated { self?.checkNewFile(file) }
            }
        }
    }

    private func checkNewFile(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path),
              !downloads.items.contains(where: { $0.filePath == file.path }),  // followed, or Notch saved it
              let marked = Self.quarantineDate(of: file), Date.now.timeIntervalSince(marked) < Self.recentWindow
        else { return }
        let id = UUID()
        downloads.addFollowed(id, title: file.lastPathComponent, sourceURL: Self.whereFrom(file))
        downloads.followFinished(id, file: file)
    }

    /// When the file was marked as downloaded from the web (the com.apple.quarantine attribute).
    nonisolated static func quarantineDate(of file: URL) -> Date? {
        attribute("com.apple.quarantine", of: file).flatMap { String(data: $0, encoding: .utf8) }.flatMap(quarantineDate)
    }

    /// "0081;6abfa74f;Safari;UUID": the second field is the time, in hex seconds since 1970.
    nonisolated static func quarantineDate(_ value: String) -> Date? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, let seconds = UInt64(fields[1], radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The link the browser saved the file from, if it recorded one.
    static func whereFrom(_ file: URL) -> String? {
        guard let data = attribute("com.apple.metadata:kMDItemWhereFroms", of: file),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return nil }
        return list.first { DownloadService.webURL(from: $0) != nil }
    }

    nonisolated private static func attribute(_ name: String, of file: URL) -> Data? {
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }

    // MARK: Files

    nonisolated static func isDownload(_ file: URL, operation: Progress.FileOperationKind?) -> Bool {
        operation == .downloading || temporarySuffixes.contains { file.lastPathComponent.hasSuffix($0) }
    }

    /// "report.pdf.download" → "report.pdf". Chrome's "Unconfirmed 12345.crdownload" has no real
    /// name yet, so we use the site's name (or "Download") until it does.
    nonisolated static func displayName(for file: URL, source: String?, keepUnknown: Bool = true) -> String? {
        let name = stripTemporarySuffix(file.lastPathComponent)
        if name.hasPrefix("Unconfirmed ") || name.isEmpty {
            guard keepUnknown else { return nil }
            return source.flatMap { URL(string: $0)?.lastPathComponent }.flatMap { $0.count > 1 ? $0 : nil } ?? "Download"
        }
        return name
    }

    nonisolated static func stripTemporarySuffix(_ name: String) -> String {
        for suffix in temporarySuffixes where name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        return name
    }

    /// Where the finished file ended up: the name without its temporary suffix, or else the
    /// newest new item in the folder (Chrome renames at the end; Safari may unzip archives).
    nonisolated static func finalFile(for temp: URL, in folder: URL, before: Set<String>) -> URL? {
        let fm = FileManager.default
        let stripped = temp.deletingLastPathComponent().appendingPathComponent(stripTemporarySuffix(temp.lastPathComponent))
        if stripped != temp, !stripped.lastPathComponent.hasPrefix("Unconfirmed "), fm.fileExists(atPath: stripped.path) {
            // Firefox creates an empty placeholder up front; only trust it once it has the data.
            let size = (try? stripped.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            if size != 0 { return stripped }
        }
        let new = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { !before.contains($0.lastPathComponent) && !temporarySuffixes.contains(where: $0.lastPathComponent.hasSuffix) }
        return new.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }
}
