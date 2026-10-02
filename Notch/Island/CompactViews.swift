import QuickLookThumbnailing
import SwiftUI

/// Compact layout: one item in the left "ear" and one in the right, with the hardware
/// notch hiding the middle — or, in the "below" style, both in a band under the camera.
struct Ears<Leading: View, Trailing: View>: View {
    let width: CGFloat
    var style: CompactStyle = .beside
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let notchHeight = coordinator.notchSize.height
        if style == .below {
            VStack(spacing: 0) {
                Color.clear.frame(height: notchHeight)
                HStack(spacing: 0) {
                    leading
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 16)
                .frame(height: IslandState.belowBandHeight)
            }
            .frame(width: width)
        } else {
            // The camera housing hides the middle of the island, so each side gets a box that
            // stops at the notch's edge. Anything too wide shrinks instead of sliding under it.
            let ear = Self.earWidth(islandWidth: width, coordinator: coordinator)
            HStack(spacing: 0) {
                leading
                    .frame(width: ear, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                trailing
                    .frame(width: ear, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, Self.edgePadding)
            .frame(width: width, height: notchHeight)
        }
    }

    static var edgePadding: CGFloat { IslandState.earPadding }
    /// Breathing room between content and the camera housing.
    static var notchClearance: CGFloat { IslandState.notchClearance }

    static func earWidth(islandWidth: CGFloat, coordinator: IslandCoordinator) -> CGFloat {
        let notch = coordinator.hasNotch ? coordinator.notchSize.width : 0
        return max(0, (islandWidth - notch) / 2 - edgePadding - notchClearance)
    }
}

// MARK: - Compact activities

struct CompactActivityView: View {
    let activity: Activity

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        switch activity {
        case .music: CompactMusicView()
        case .download: CompactDownloadView()
        case .countdown, .stopwatch: timerBody
        }
    }

    private var timerBody: some View {
        let timers = coordinator.timers
        return Ears(width: coordinator.metrics.width, style: coordinator.settings.compactStyle) {
            Image(systemName: activity == .countdown ? "timer" : "stopwatch")
                .font(.system(size: 15, weight: .semibold))
        } trailing: {
            Group {
                switch activity {
                case .countdown:
                    if let c = timers.countdown { CountdownText(countdown: c) }
                case .stopwatch:
                    if let s = timers.stopwatch { StopwatchText(stopwatch: s) }
                case .music, .download:
                    EmptyView()
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
        }
        .foregroundStyle(Theme.orange)
    }
}

/// Counts down without any timer of our own: SwiftUI redraws the text once a second
/// only while it's on screen.
struct CountdownText: View {
    let countdown: TimerService.Countdown

    var body: some View {
        if let remaining = countdown.pausedRemaining {
            Text(formatClock(remaining)).opacity(0.6)
        } else {
            Text(timerInterval: min(.now, countdown.endDate)...countdown.endDate, countsDown: true)
        }
    }
}

struct StopwatchText: View {
    let stopwatch: TimerService.Stopwatch

    var body: some View {
        if let elapsed = stopwatch.pausedElapsed {
            Text(formatClock(elapsed)).opacity(0.6)
        } else {
            Text(stopwatch.startDate, style: .timer)
        }
    }
}

// MARK: - Split bubble

/// The detached circle showing a second activity, iOS-style.
struct BubbleView: View {
    let activity: Activity
    let size: CGFloat

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: size / 2, bottomTrailingRadius: size / 2)
                .fill(.black)
            switch activity {
            case .countdown:
                if let c = coordinator.timers.countdown {
                    TimelineView(.periodic(from: c.endDate, by: 1)) { context in
                        ProgressRing(progress: c.progress(at: context.date), lineWidth: 3)
                            .frame(width: 16, height: 16)
                    }
                }
            case .stopwatch:
                Image(systemName: "stopwatch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.orange)
            case .music:
                MusicBubbleContent()
            case .download:
                DownloadProgressRing(size: 16)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Peeks

struct PeekView: View {
    let peek: Peek

    var body: some View {
        switch peek {
        case .charging(let level):
            Ears(width: 408) {
                Text("Charging").font(.system(size: 14, weight: .semibold))
            } trailing: {
                BatteryReadout(level: level).foregroundStyle(Theme.green)
            }
        case .unplugged(let level):
            Ears(width: 408) {
                Text("On Battery").font(.system(size: 14, weight: .semibold))
            } trailing: {
                BatteryReadout(level: level)
            }
        case .lowBattery(let level):
            Ears(width: 408) {
                Text("Low Battery").font(.system(size: 14, weight: .semibold))
            } trailing: {
                BatteryReadout(level: level).foregroundStyle(Theme.red)
            }
        case .timerDone:
            Ears(width: 300) {
                Image(systemName: "timer").font(.system(size: 15, weight: .semibold))
            } trailing: {
                Text("Done").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Theme.orange)
        case .trackChange:
            TrackPeekView()
        case .meeting:
            MeetingPeekView()
        case .hud(let kind, let level, let muted):
            HUDPeekView(kind: kind, level: level, muted: muted)
        case .downloadDone:
            DownloadPeekView(succeeded: true)
        case .downloadFailed:
            DownloadPeekView(succeeded: false)
        case .notification(let id):
            NotificationPeekView(id: id)
        }
    }
}

/// Volume and brightness: the icon on the left, the percentage on the right, and the level
/// as a glowing strip along the island's bottom edge, just below the camera — nothing hides
/// behind the notch.
private struct HUDPeekView: View {
    let kind: HUDService.Kind
    let level: Int
    let muted: Bool

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let shown = muted ? 0 : level
        VStack(spacing: 0) {
            Ears(width: coordinator.metrics.width) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            } trailing: {
                Text(muted ? "Muted" : "\(level)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(level)))
                    .foregroundStyle(muted ? Theme.secondaryText : .white)
            }
            ProgressLip(fraction: Double(shown) / 100, tint: kind == .brightness ? Theme.orange : .white)
                .frame(height: IslandState.hudLip)
        }
        .animation(.snappy(duration: 0.18), value: level)
        .animation(.snappy(duration: 0.18), value: muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .volume ? (muted ? "Muted" : "Volume \(level)%") : "Brightness \(level)%")
    }

    private var symbol: String {
        switch kind {
        case .volume:
            if muted || level == 0 { return "speaker.slash.fill" }
            return level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness:
            return level < 50 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

/// A thin level or progress strip along the bottom edge of the island, with a soft glow.
struct ProgressLip: View {
    let fraction: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { g in
            let inset: CGFloat = 18
            let width = max(0, g.size.width - inset * 2)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: width * min(max(fraction, 0), 1))
                    .shadow(color: tint.opacity(0.6), radius: 4)
            }
            .frame(width: width, height: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 2)
        }
    }
}

private struct BatteryReadout: View {
    let level: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("\(level)%")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            BatteryIcon(level: level)
        }
    }
}

/// A 30 × 15 battery drawn to the design guide, filled to `level`.
struct BatteryIcon: View {
    let level: Int

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(lineWidth: 1.5)
                    .opacity(0.6)
                RoundedRectangle(cornerRadius: 2.2)
                    .frame(width: max(2, 19.5 * CGFloat(min(level, 100)) / 100), height: 9.4)
                    .padding(.leading, 2.8)
            }
            .frame(width: 25, height: 13.5)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 2, height: 5)
                .opacity(0.6)
        }
        .accessibilityLabel("Battery \(level) percent")
    }
}

// MARK: - Downloads

/// Collapsed island while a download runs: an arrow on the left, the percentage on the right,
/// and progress as a strip along the bottom edge.
private struct CompactDownloadView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let downloads = coordinator.downloads
        let item = downloads.activeItem
        let fraction = item.flatMap { downloads.progress[$0.id]?.fraction }
        let below = coordinator.settings.compactStyle == .below
        VStack(spacing: 0) {
            Ears(width: coordinator.metrics.width, style: coordinator.settings.compactStyle) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.blue)
            } trailing: {
                Group {
                    if let fraction {
                        Text("\(Int(fraction * 100))%")
                            .contentTransition(.numericText(value: fraction))
                    } else if item?.status == .finishing {
                        Text("Saving")
                    } else {
                        DownloadProgressRing(size: 14)
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            }
            if !below {
                ProgressLip(fraction: fraction ?? 0, tint: Theme.blue)
                    .frame(height: IslandState.progressLip)
                    .opacity(fraction == nil ? 0.4 : 1)
            }
        }
        .animation(.snappy, value: fraction.map { Int($0 * 100) })
    }
}

struct DownloadProgressRing: View {
    let size: CGFloat
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let downloads = coordinator.downloads
        if let item = downloads.activeItem, let fraction = downloads.progress[item.id]?.fraction, item.status == .downloading {
            ProgressRing(progress: fraction, lineWidth: 3, color: Theme.blue).frame(width: size, height: size)
        } else {
            ProgressView().controlSize(.mini).tint(Theme.blue).frame(width: size, height: size)
        }
    }
}

/// 430 × 92, below the notch like the song-change peek: the file's thumbnail and title with
/// a Show button — or, if it failed, the reason with Retry. Stays open while hovered.
private struct DownloadPeekView: View {
    let succeeded: Bool
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let downloads = coordinator.downloads
        let item = downloads.items.first { $0.status == (succeeded ? .done : .failed) }
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                DownloadPeekThumbnail(item: item)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, succeeded ? Theme.green : Theme.red)
                    .background(Circle().fill(.black).padding(1))
                    .offset(x: 5, y: 5)
            }
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: item?.title ?? (succeeded ? "Downloaded" : "Download failed"), size: 14.5)
                    .frame(height: 18)
                Text(subtitle(item))
                    .font(.system(size: 12.5))
                    .foregroundStyle(succeeded ? Theme.secondaryText : Theme.red.opacity(0.9))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard let item else { return }
                if succeeded, let url = item.fileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    downloads.retry(item.id)
                }
                coordinator.dismissPeek()
            } label: {
                Text(succeeded ? "Show" : "Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(succeeded ? Theme.blue : .white.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(item == nil)
        }
        .padding(.horizontal, 18)
        .padding(.top, 44)
        .frame(width: 430, height: 92, alignment: .top)
    }

    private func subtitle(_ item: DownloadService.Item?) -> String {
        guard let item else { return succeeded ? "Saved" : "Something went wrong" }
        if !succeeded { return item.errorMessage ?? "Something went wrong" }
        let folder = item.fileURL?.deletingLastPathComponent().lastPathComponent ?? "Downloads"
        let size = (try? item.fileURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            .map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        return "Saved to \(folder)\(size)"
    }
}

/// The finished file's own thumbnail, else the site's, else a generic icon.
private struct DownloadPeekThumbnail: View {
    let item: DownloadService.Item?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.1)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let string = item?.thumbnailURL, let url = URL(string: string) {
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            } else {
                Image(systemName: item?.quality == .audio ? "waveform" : "play.rectangle.fill")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .task(id: item?.filePath) {
            guard let url = item?.fileURL, item?.status == .done else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
