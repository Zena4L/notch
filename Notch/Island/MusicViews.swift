import AppKit
import SwiftUI

// MARK: - Compact, peek and bubble

struct CompactMusicView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let nowPlaying = coordinator.nowPlaying
        Ears(width: coordinator.metrics.width, style: coordinator.settings.compactStyle) {
            ArtworkView(image: nowPlaying.artwork, size: 22, cornerRadius: 6)
        } trailing: {
            Waveform(isPlaying: nowPlaying.track?.isPlaying == true, tint: coordinator.waveformTint, style: .small)
        }
    }
}

/// 430 × 92: confirms what just started, without a click.
struct TrackPeekView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let nowPlaying = coordinator.nowPlaying
        HStack(spacing: 12) {
            ArtworkView(image: nowPlaying.artwork, size: 40, cornerRadius: 9)
            TrackTitles(track: nowPlaying.track, titleSize: 14.5, artistSize: 13)
            Waveform(isPlaying: nowPlaying.track?.isPlaying == true, tint: coordinator.waveformTint, style: .small)
        }
        .padding(.horizontal, 18)
        .padding(.top, 44)
        .frame(width: 430, height: 92, alignment: .top)
    }
}

struct MusicBubbleContent: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        ArtworkView(image: coordinator.nowPlaying.artwork, size: 20, cornerRadius: 10)
    }
}

// MARK: - Expanded

/// 540 × 212: artwork, titles, waveform, progress and transport controls.
struct NowPlayingView: View {
    let track: NowPlayingService.Track

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let nowPlaying = coordinator.nowPlaying
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { nowPlaying.openSourceApp() } label: {
                    ArtworkView(image: nowPlaying.artwork, size: 68, cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .help("Open the app that's playing")
                TrackTitles(track: track, titleSize: 16, artistSize: 14, scrolls: true)
                Waveform(isPlaying: track.isPlaying, tint: coordinator.waveformTint, style: .large)
            }
            .padding(.top, 9)

            Scrubber(track: track)
                .padding(.top, 16)

            TransportControls(track: track)
                .padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct Scrubber: View {
    let track: NowPlayingService.Track

    @Environment(IslandCoordinator.self) private var coordinator
    @State private var dragFraction: Double?

    var body: some View {
        // Only ticks while this view is on screen, i.e. while the island is expanded.
        TimelineView(.periodic(from: track.timestamp, by: 1)) { context in
            let duration = max(track.duration, 0)
            let elapsed = dragFraction.map { $0 * duration } ?? track.elapsed(at: context.date)
            let fraction = duration > 0 ? elapsed / duration : 0

            HStack(spacing: 10) {
                Text(formatClock(elapsed.rounded(.down)))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geo.size.width * min(max(fraction, 0), 1))
                            .animation(dragFraction == nil ? .linear(duration: 1) : nil, value: fraction)
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { _ in
                                if let dragFraction, duration > 0 {
                                    coordinator.nowPlaying.seek(to: dragFraction * duration)
                                }
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 14)
                Text("-" + formatClock(max(duration - elapsed, 0).rounded(.up)))
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
        .disabled(track.duration <= 0)
    }
}

/// Shuffle on the left; previous / play / next centred; lyrics and AirPlay on the right —
/// the same row in the player and in the lyrics view, like Apple Music.
struct TransportControls: View {
    let track: NowPlayingService.Track

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let nowPlaying = coordinator.nowPlaying
        ZStack {
            HStack(spacing: 30) {
                ControlButton(symbol: "backward.fill", size: 20, label: "Previous") { nowPlaying.previousTrack() }
                ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 24, label: "Play or pause") {
                    nowPlaying.togglePlayPause()
                }
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30)
                ControlButton(symbol: "forward.fill", size: 20, label: "Next") { nowPlaying.nextTrack() }
            }
            HStack(spacing: 14) {
                ControlButton(symbol: "shuffle", size: 15, dim: true, label: "Shuffle") { nowPlaying.toggleShuffle() }
                Spacer()
                if coordinator.lyricsAvailable {
                    ControlButton(
                        symbol: "quote.bubble", size: 15, dim: !coordinator.showsLyrics,
                        isOn: coordinator.showsLyrics, label: coordinator.showsLyrics ? "Hide lyrics" : "Show lyrics"
                    ) {
                        coordinator.toggleLyrics()
                    }
                    .help(coordinator.showsLyrics ? "Hide lyrics" : "Lyrics")
                }
                ControlButton(symbol: "airplay.audio", size: 15, dim: true, label: "Output device") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var dim = false
    /// A toggle that's on gets a filled background, like Apple Music's lyrics button.
    var isOn = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? symbol + ".fill" : symbol)
                .font(.system(size: size))
                .foregroundStyle(isOn ? .black : dim ? .white.opacity(0.5) : .white)
                .frame(minWidth: 30, minHeight: 30)
                .background(isOn ? .white.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 8, padding: 2))
        .accessibilityLabel(label)
    }
}

// MARK: - Shared pieces

struct TrackTitles: View {
    let track: NowPlayingService.Track?
    let titleSize: CGFloat
    let artistSize: CGFloat
    /// Long titles scroll instead of being cut off.
    var scrolls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if scrolls {
                MarqueeText(text: track?.title ?? "Nothing playing", size: titleSize)
            } else {
                Text(track?.title ?? "Nothing playing")
                    .font(.system(size: titleSize, weight: .semibold))
            }
            Text(track?.artist ?? "")
                .font(.system(size: artistSize))
                .foregroundStyle(Theme.secondaryText)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(red: 1, green: 0.48, blue: 0.35), Color(red: 0.77, green: 0.24, blue: 0.48), Color(red: 0.23, green: 0.16, blue: 0.42)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Five bouncing bars tinted with the artwork colour.
///
/// Animated with Core Animation, which runs in the system's render server rather than
/// in our process — so the bars cost almost no CPU while music plays.
struct Waveform: NSViewRepresentable {
    enum Style {
        case small, large

        var barWidth: CGFloat { self == .small ? 3 : 3.5 }
        var gap: CGFloat { self == .small ? 2.5 : 3 }
        var height: CGFloat { self == .small ? 18 : 26 }
        var width: CGFloat { barWidth * 5 + gap * 4 }
    }

    let isPlaying: Bool
    let tint: Color
    let style: Style

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> WaveformLayerView {
        WaveformLayerView(style: style)
    }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        view.update(color: NSColor(tint), animating: isPlaying && !reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformLayerView, context: Context) -> CGSize? {
        CGSize(width: style.width, height: style.height)
    }
}

final class WaveformLayerView: NSView {
    private static let durations: [CFTimeInterval] = [0.9, 0.7, 1.1, 0.8, 1.0]
    private static let offsets: [CFTimeInterval] = [0, 0.2, 0.5, 0.3, 0.6]
    private static let restingScale: CGFloat = 0.35

    private let style: Waveform.Style
    private var bars: [CALayer] = []
    private var isAnimating = false

    init(style: Waveform.Style) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: style.width, height: style.height))
        wantsLayer = true
        for _ in 0..<5 {
            let bar = CALayer()
            bar.cornerRadius = style.barWidth / 2
            bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: Self.restingScale))
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (style.barWidth + style.gap) + style.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    func update(color: NSColor, animating: Bool) {
        for bar in bars { bar.backgroundColor = color.cgColor }
        guard animating != isAnimating else { return }
        isAnimating = animating

        for (i, bar) in bars.enumerated() {
            if animating {
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.3
                bounce.toValue = 1.0
                bounce.duration = Self.durations[i] / 2
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timeOffset = Self.offsets[i]
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(bounce, forKey: "bounce")
            } else {
                bar.removeAnimation(forKey: "bounce")
            }
        }
    }
}
