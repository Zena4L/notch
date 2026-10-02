import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The Downloads tab: paste a link on top; downloads (videos, and files handed over by the
/// browser) and finished files below, with AirDrop and Share beside them.
struct DownloadsView: View {
    @Environment(IslandCoordinator.self) private var coordinator
    @State private var link = ""
    @State private var quality: DownloadQuality = .best
    @State private var invalid = false
    @State private var selection: Set<UUID> = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let downloads = coordinator.downloads
        VStack(spacing: 10) {
            linkBar(downloads)
            // Plain files don't need yt-dlp, so only block the list while a video is waiting for it.
            let needsTools = !downloads.tools.isReady || downloads.toolTask != .idle
            let videoWaiting = downloads.items.contains { !$0.isDirect && $0.status == .queued }
            if needsTools && (downloads.items.isEmpty || videoWaiting) {
                ToolsBanner()
            } else if downloads.items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 14) {
                    tiles(downloads)
                    actions(downloads)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { quality = coordinator.settings.downloadQuality }
        .onChange(of: fieldFocused) { _, focused in coordinator.isTyping = focused }
        .onChange(of: downloads.items) { _, items in selection.formIntersection(items.map(\.id)) }
    }

    // MARK: Link bar

    private func linkBar(_ downloads: DownloadService) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                TextField("", text: $link, prompt: Text("Paste a video or file link…").foregroundStyle(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { start(downloads) }
                    .onChange(of: link) { invalid = false }
                if link.isEmpty {
                    Button {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            link = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text("Paste").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(IslandButtonStyle(cornerRadius: 5, padding: 4))
                    .foregroundStyle(.white.opacity(0.75))
                } else {
                    Button { link = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(invalid ? Theme.red : .clear, lineWidth: 1))

            Menu {
                Picker("Quality", selection: $quality) {
                    Text("Best").tag(DownloadQuality.best)
                    Text("1080p").tag(DownloadQuality.p1080)
                    Text("720p").tag(DownloadQuality.p720)
                    Text("Audio only (MP3)").tag(DownloadQuality.audio)
                }
                .pickerStyle(.inline)
            } label: {
                Text(qualityLabel).font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(IslandButtonStyle(cornerRadius: 8, padding: 6))
            .fixedSize()
            .foregroundStyle(.white.opacity(0.85))

            Button { start(downloads) } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(canStart(downloads) ? Theme.blue : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(!canStart(downloads))
            .accessibilityLabel("Download")
        }
    }

    private var qualityLabel: String {
        switch quality {
        case .best: "Best"
        case .p1080: "1080p"
        case .p720: "720p"
        case .audio: "MP3"
        }
    }

    /// Videos need yt-dlp; links straight to a file (a PDF, a zip…) don't.
    private func canStart(_ downloads: DownloadService) -> Bool {
        guard !link.isEmpty else { return false }
        return downloads.tools.isReady || DownloadService.webURL(from: link).map(DownloadService.isFileLink) == true
    }

    private func start(_ downloads: DownloadService) {
        if downloads.download(link, quality: quality) {
            link = ""
        } else {
            invalid = true
            NSSound.beep()
        }
    }

    // MARK: Items

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.circle").font(.system(size: 22))
            Text(coordinator.settings.browserTakeover
                 ? "Download something in your browser, or paste a link and press ↩"
                 : "Copy a video or file link, then press Paste and ↩")
                .font(.system(size: 12.5))
        }
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tiles(_ downloads: DownloadService) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(downloads.items) { item in
                    DownloadTile(item: item, progress: downloads.progress[item.id], isSelected: selection.contains(item.id)) {
                        downloads.cancel(item.id)
                    }
                        .onTapGesture(count: 2) {
                            if let url = item.fileURL { NSWorkspace.shared.open(url) }
                        }
                        .onTapGesture {
                            switch item.status {
                            case .failed, .cancelled: downloads.retry(item.id)
                            case .done:
                                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                            default: break
                            }
                        }
                        .onDrag {
                            if let url = item.fileURL, item.status == .done { return NSItemProvider(object: url as NSURL) }
                            return NSItemProvider()
                        }
                        .contextMenu { menu(for: item, downloads) }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func menu(for item: DownloadService.Item, _ downloads: DownloadService) -> some View {
        if item.isActive || item.status == .queued {
            Button("Cancel Download") { downloads.cancel(item.id) }
        }
        if item.status == .done, let url = item.fileURL {
            Button("Open") { NSWorkspace.shared.open(url) }
            OpenWithMenu(file: url)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if (item.status == .failed || item.status == .cancelled) && item.canRetry {
            Button("Try Again") { downloads.retry(item.id) }
        }
        if !item.sourceURL.isEmpty {
            Button("Copy Original Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.sourceURL, forType: .string)
            }
        }
        Divider()
        Button("Remove from List") { downloads.remove([item.id]) }
        if item.status == .done {
            Button("Move to Trash", role: .destructive) { downloads.remove([item.id], trash: true) }
        }
        Button("Clear Finished") { downloads.clearFinished() }
    }

    @ViewBuilder
    private func actions(_ downloads: DownloadService) -> some View {
        let files = downloads.finishedItems
            .filter { selection.isEmpty || selection.contains($0.id) }
            .compactMap(\.fileURL)
        if !downloads.finishedItems.isEmpty {
            VStack(spacing: 8) {
                Button {
                    coordinator.collapse()
                    downloads.airDrop(files)
                } label: {
                    ActionLabel(title: "AirDrop", symbol: "dot.radiowaves.left.and.right", isPrimary: true)
                }
                .buttonStyle(.plain)
                ShareLink(items: files) {
                    ActionLabel(title: "Share", symbol: "square.and.arrow.up", isPrimary: false)
                }
                .buttonStyle(.plain)
                Button {
                    NSWorkspace.shared.open(downloads.folder)
                } label: {
                    ActionLabel(title: "Folder", symbol: "folder", isPrimary: false)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 110)
        }
    }
}

// MARK: - Tile

private struct DownloadTile: View {
    let item: DownloadService.Item
    let progress: DownloadService.Progress?
    let isSelected: Bool
    let onCancel: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Thumbnail(item: item)
                    .frame(width: 72, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .opacity(item.status == .done ? 1 : 0.55)
                overlay
            }
            .overlay(alignment: .topTrailing) {
                if item.isActive || item.status == .queued {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(isHovered ? 0.85 : 0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel download")
                }
            }
            Text(item.title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(statusLine)
                .font(.system(size: 10))
                .foregroundStyle(item.status == .failed ? Theme.red.opacity(0.9) : .white.opacity(0.45))
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(width: 96)
        .padding(.vertical, 7)
        .background(isSelected ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(item.errorMessage ?? item.sourceURL)
    }

    @ViewBuilder
    private var overlay: some View {
        switch item.status {
        case .downloading, .finishing:
            if let fraction = progress?.fraction, item.status == .downloading {
                ProgressRing(progress: fraction, lineWidth: 3, color: .white).frame(width: 24, height: 24)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        case .queued:
            Image(systemName: "clock").font(.system(size: 15, weight: .semibold))
        case .failed:
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.red)
        case .cancelled:
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
        case .done:
            if item.quality == .audio && !item.isFile {
                Image(systemName: "music.note").font(.system(size: 16, weight: .semibold)).shadow(radius: 3)
            }
        }
    }

    private var statusLine: String {
        switch item.status {
        case .queued: return "Waiting…"
        case .finishing: return "Finishing…"
        case .cancelled: return item.canRetry ? "Cancelled · retry" : "Cancelled"
        case .failed: return item.errorMessage ?? "Failed · retry"
        case .done:
            let size = (try? item.fileURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            return size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Done"
        case .downloading:
            guard let progress else { return "Starting…" }
            var parts: [String] = []
            if item.isFile, let bytes = progress.bytes {
                let done = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                parts.append(item.expectedBytes.map { "\(done) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? done)
            } else if let f = progress.fraction {
                parts.append("\(Int(f * 100))%")
            }
            if let eta = progress.eta, eta > 0 { parts.append(eta >= 60 ? "\(eta / 60)m left" : "\(eta)s left") }
            return parts.isEmpty ? "Downloading…" : parts.joined(separator: " · ")
        }
    }
}

/// The site's thumbnail while downloading; the file's own Quick Look thumbnail when done.
private struct Thumbnail: View {
    let item: DownloadService.Item
    @State private var fileThumbnail: NSImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let fileThumbnail {
                Image(nsImage: fileThumbnail).resizable().aspectRatio(contentMode: .fill)
            } else if item.isFile {
                Image(nsImage: Self.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(5)
            } else if let string = item.thumbnailURL, let url = URL(string: string) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
            } else {
                Image(systemName: item.quality == .audio ? "waveform" : "play.rectangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .task(id: item.status == .done ? item.filePath : nil) {
            guard item.status == .done, let url = item.fileURL else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 46), scale: 2, representationTypes: .thumbnail)
            fileThumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }

    /// The Finder icon for the file's type, while it downloads or when Quick Look has no preview.
    static func icon(for item: DownloadService.Item) -> NSImage {
        let ext = ((item.filePath ?? item.title) as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

/// "Open With" › the apps that can open this file, default first.
private struct OpenWithMenu: View {
    let file: URL

    var body: some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: file)
        if !apps.isEmpty {
            Menu("Open With") {
                ForEach(apps.prefix(12), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) {
                        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
    }
}

private struct ActionLabel: View {
    let title: String
    let symbol: String
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(title).font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 11)
        .background(isPrimary ? Theme.blue : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
    }
}

// MARK: - Tools banner

/// Shown until yt-dlp and ffmpeg are installed, and while Homebrew is working.
private struct ToolsBanner: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let downloads = coordinator.downloads
        VStack(spacing: 8) {
            switch downloads.toolTask {
            case .running(let title, let lastLine):
                ProgressView().controlSize(.small).tint(.white)
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(lastLine).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            case .failed(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.red).multilineTextAlignment(.center)
                Button("OK") { downloads.dismissToolError() }
                    .buttonStyle(IslandButtonStyle(cornerRadius: 6, padding: 6))
            case .idle:
                Text("Downloads need two free tools: yt-dlp and ffmpeg.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.8))
                if downloads.tools.brew != nil {
                    Button {
                        downloads.installTools()
                    } label: {
                        Text("Install with Homebrew")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            .background(Theme.blue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Text("Takes a few minutes the first time").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Install Homebrew from brew.sh first, then come back.")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { downloads.refreshTools() }
    }
}
