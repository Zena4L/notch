import AppKit
import ImageIO
import Observation
import SwiftUI

/// What's playing in any app (Music, Spotify, browsers, Podcasts…).
///
/// Since macOS 15.4 only Apple-entitled processes may read MediaRemote, so we run the
/// bundled mediaremote-adapter through the system's /usr/bin/perl, which is allowed to.
/// It streams one JSON line per change — no polling.
@Observable
final class NowPlayingService {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var bundleIdentifier: String?
        /// Elapsed time as of `timestamp`.
        var elapsed: TimeInterval
        var timestamp: Date
        var playbackRate: Double
        var isPlaying: Bool

        func elapsed(at date: Date) -> TimeInterval {
            guard isPlaying else { return elapsed }
            let position = elapsed + date.timeIntervalSince(timestamp) * (playbackRate > 0 ? playbackRate : 1)
            return duration > 0 ? min(position, duration) : position
        }

        /// Same song, ignoring playback position.
        func isSameSong(as other: Track) -> Bool {
            title == other.title && artist == other.artist && album == other.album
        }
    }

    private(set) var track: Track?
    private(set) var artwork: NSImage?
    private(set) var tint: Color = NowPlayingService.defaultTint

    /// True while playing, and for a short grace period after pausing,
    /// so pausing doesn't make the island snap shut instantly.
    private(set) var isActive = false

    /// Fired when a different song starts playing.
    @ObservationIgnored var onTrackChange: (() -> Void)?

    static let defaultTint = Color(red: 1, green: 138 / 255, blue: 107 / 255)  // #ff8a6b

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    @ObservationIgnored private var process: Process?
    /// We hold the write end; the watchdog exits (and stops the adapter) when it closes.
    @ObservationIgnored private var lifeline: Pipe?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var payload: [String: Any] = [:]
    @ObservationIgnored private var lastArtworkData: String?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var restartCount = 0
    @ObservationIgnored private var isStopping = false

    private let adapter: (script: URL, framework: URL)?

    /// Runs the adapter as a child of a tiny Perl watchdog that blocks reading stdin.
    /// If Notch quits, crashes or is force-stopped from Xcode, the pipe closes,
    /// the read returns, and the watchdog stops the adapter — no orphaned processes.
    private static let watchdog = #"""
        my $pid = fork();
        if ($pid == 0) { exec('/usr/bin/perl', @ARGV); exit 1; }
        $SIG{CHLD} = sub { exit 0 };
        $SIG{TERM} = sub { kill 'TERM', $pid; exit 0 };
        1 while sysread(STDIN, my $buf, 1024);
        kill 'TERM', $pid;
        """#

    init(settings: SettingsStore = .shared, startStream: Bool = true) {
        self.settings = settings
        if let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") {
            adapter = (base.appendingPathComponent("mediaremote-adapter.pl"),
                       base.appendingPathComponent("MediaRemoteAdapter.framework"))
        } else {
            adapter = nil
        }
        guard startStream else { return }
        if settings.nowPlayingEnabled { self.startStream() }
        // Turning Now Playing off in Settings stops the background reader entirely.
        settingsObserver = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(["nowPlayingEnabled"]) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setStreaming(self.settings.nowPlayingEnabled)
            }
        }
    }

    func stop() {
        isStopping = true
        process?.terminate()
    }

    private func setStreaming(_ on: Bool) {
        if on {
            guard process == nil else { return }
            isStopping = false
            restartCount = 0
            startStream()
        } else if process != nil {
            stop()
            apply([:])
        }
    }

    // MARK: Controls

    func togglePlayPause() { send(2) }
    func nextTrack() { send(4) }
    func previousTrack() { send(5) }
    func toggleShuffle() { send(6) }

    func seek(to seconds: TimeInterval) {
        run(["seek", String(Int(max(0, seconds) * 1_000_000))])
        // Update locally right away so the progress bar doesn't jump back.
        if var t = track {
            t.elapsed = seconds
            t.timestamp = .now
            track = t
        }
    }

    func openSourceApp() {
        guard let id = track?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func send(_ command: Int) {
        run(["send", String(command)])
    }

    private func run(_ arguments: [String]) {
        guard let adapter else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [adapter.script.path, adapter.framework.path] + arguments
        try? p.run()
    }

    // MARK: Stream

    private func startStream() {
        guard let adapter, FileManager.default.fileExists(atPath: adapter.script.path) else {
            NSLog("Notch: MediaRemoteAdapter is missing from the app bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.watchdog, adapter.script.path, adapter.framework.path, "stream", "--debounce=100", "--micros"]

        let out = Pipe()
        let lifeline = Pipe()
        p.standardInput = lifeline
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(data) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.streamEnded() }
            }
        }

        do {
            try p.run()
            process = p
            self.lifeline = lifeline
        } catch {
            NSLog("Notch: couldn't start the Now Playing stream: \(error.localizedDescription)")
        }
    }

    private func streamEnded() {
        process = nil
        lifeline = nil
        guard !isStopping, restartCount < 5 else { return }
        restartCount += 1
        let delay = Double(restartCount * restartCount)  // 1, 4, 9… seconds
        Task {
            try? await Task.sleep(for: .seconds(delay))
            startStream()
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    /// Internal so tests can feed it adapter output.
    func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data"
        else { return }
        restartCount = 0

        let diff = object["diff"] as? Bool ?? false
        guard let update = object["payload"] as? [String: Any], !update.isEmpty else {
            if !diff { apply([:]) }
            return
        }
        var merged = diff ? payload : [:]
        for (key, value) in update {
            if value is NSNull { merged.removeValue(forKey: key) } else { merged[key] = value }
        }
        apply(merged)
    }

    private func apply(_ payload: [String: Any]) {
        self.payload = payload

        guard let title = payload["title"] as? String, !title.isEmpty else {
            track = nil
            artwork = nil
            lastArtworkData = nil
            tint = Self.defaultTint
            setActive(false)
            return
        }

        // `--micros` gives microsecond timing; whole seconds would let lyrics drift by up to a second.
        func seconds(_ micros: String, _ plain: String) -> Double? {
            (payload[micros] as? Double).map { $0 / 1_000_000 } ?? payload[plain] as? Double
        }
        var timestamp = (payload["timestampEpochMicros"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000_000) }
            ?? (payload["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
            ?? .now
        let isPlaying = payload["playing"] as? Bool ?? false
        let elapsed = seconds("elapsedTimeMicros", "elapsedTime") ?? 0

        // Some apps don't refresh the timestamp when you press play after a pause; the old one
        // would make the position jump ahead by however long it was paused.
        if isPlaying, let old = track, !old.isPlaying, old.timestamp == timestamp, abs(old.elapsed - elapsed) < 0.5 {
            timestamp = .now
        }

        let new = Track(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: seconds("durationMicros", "duration") ?? 0,
            bundleIdentifier: payload["bundleIdentifier"] as? String,
            elapsed: elapsed,
            timestamp: timestamp,
            playbackRate: payload["playbackRate"] as? Double ?? 1,
            isPlaying: isPlaying
        )

        let isNewSong = track.map { !$0.isSameSong(as: new) } ?? false
        if track != new { track = new }
        updateArtwork(payload["artworkData"] as? String)
        setActive(new.isPlaying)
        if isNewSong, new.isPlaying { onTrackChange?() }
    }

    private func updateArtwork(_ base64: String?) {
        guard base64 != lastArtworkData else { return }
        lastArtworkData = base64
        guard let base64, let data = Data(base64Encoded: base64), let image = Self.thumbnail(from: data) else {
            artwork = nil
            tint = Self.defaultTint
            return
        }
        artwork = image
        tint = image.islandTint ?? Self.defaultTint
    }

    /// Artwork often arrives at 1000 px or more, but the island never shows it above 68 pt.
    /// Decoding straight to a small thumbnail saves memory and makes the tint quicker.
    static func thumbnail(from data: Data, maxPixels: Int = 192) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Points = pixels / 2, so it's sharp on Retina displays.
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
    }

    private func setActive(_ playing: Bool) {
        graceTask?.cancel()
        if playing {
            isActive = true
        } else if track == nil {
            isActive = false
        } else if isActive {
            let grace = settings.pausedGraceSeconds
            guard grace > 0 else {
                isActive = false
                return
            }
            graceTask = Task {
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled else { return }
                isActive = false
            }
        }
    }
}

private extension NSImage {
    /// The artwork's average colour, brightened so it reads well on black.
    var islandTint: Color? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        )
        guard let bitmap else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .medium
        draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()

        guard let average = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Greys stay grey; colours get a boost.
        let saturation = s < 0.1 ? s : min(1, max(s * 1.3, 0.45))
        return Color(hue: h, saturation: saturation, brightness: max(b, 0.85))
    }
}
