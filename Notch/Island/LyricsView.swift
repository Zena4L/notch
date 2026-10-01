import SwiftUI

/// The Lyrics tab: a small header with the song, then lyrics that follow along.
struct LyricsView: View {
    let track: NowPlayingService.Track

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let lyrics = coordinator.lyrics
        let nowPlaying = coordinator.nowPlaying

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { nowPlaying.openSourceApp() } label: {
                    ArtworkView(image: nowPlaying.artwork, size: 34, cornerRadius: 8)
                }
                .buttonStyle(.plain)
                TrackTitles(track: track, titleSize: 13.5, artistSize: 12, scrolls: true)
                Waveform(isPlaying: track.isPlaying, tint: coordinator.waveformTint, style: .small)
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Group {
                switch lyrics.content {
                case .loading:
                    ProgressView().controlSize(.small)
                case .synced(let lines):
                    SyncedLyrics(lines: lines, track: track)
                case .plain(let text):
                    ScrollView(showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 14)
                    }
                    .padding(.horizontal, 24)
                    .fadedEdges()
                case .instrumental:
                    message("Instrumental", symbol: "pianokeys")
                case .notFound:
                    message("No lyrics found for this song", symbol: "text.page.slash")
                case .failed:
                    VStack(spacing: 8) {
                        message("Couldn't load lyrics", symbol: "wifi.exclamationmark")
                        Button("Try Again") { Task { await lyrics.load(for: track, retry: true) } }
                            .buttonStyle(IslandButtonStyle(cornerRadius: 6, padding: 6))
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TransportControls(track: track)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        // Fetch only when this tab is on screen, and again when the song changes.
        .task(id: LyricsService.key(for: track)) {
            await lyrics.load(for: track)
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(Theme.secondaryText)
    }
}

/// Time-synced lines: the current one is bright and centred, neighbours fade with distance.
/// Click a line to jump there.
///
/// Instead of checking the time over and over, it works out when the next line starts and
/// sleeps until exactly then — precise, and nearly free while a long line is being sung.
private struct SyncedLyrics: View {
    let lines: [LyricsService.Line]
    let track: NowPlayingService.Track

    @Environment(IslandCoordinator.self) private var coordinator
    @State private var current: Int?

    var body: some View {
        LyricLines(lines: lines, current: current) { line in
            coordinator.nowPlaying.seek(to: line.time)
        }
        // Restarts whenever the song, position, or play state changes (play, pause, seek, skip).
        .task(id: track) {
            current = LRC.currentIndex(in: lines, at: track.elapsed(at: .now))
            while track.isPlaying, !Task.isCancelled {
                let elapsed = track.elapsed(at: .now)
                guard let wait = LRC.secondsUntilNextLine(in: lines, at: elapsed, rate: track.playbackRate) else { return }
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                let next = LRC.currentIndex(in: lines, at: track.elapsed(at: .now))
                if next != current {
                    withAnimation(.smooth(duration: 0.45)) { current = next }
                }
            }
        }
    }
}

private struct LyricLines: View {
    let lines: [LyricsService.Line]
    let current: Int?
    let onSelect: (LyricsService.Line) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white.opacity(opacity(for: line.id)))
                            .scaleEffect(line.id == current ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(line) }
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 50)
            }
            .fadedEdges()
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: current) { old, _ in scroll(proxy, animated: old != nil) }
        }
    }

    private func opacity(for id: Int) -> Double {
        guard let current else { return 0.45 }
        let distance = abs(id - current)
        return distance == 0 ? 1 : max(0.18, 0.55 - Double(distance - 1) * 0.12)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let current else { return }
        if animated {
            withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(current, anchor: .center) }
        } else {
            proxy.scrollTo(current, anchor: .center)
        }
    }
}

private extension View {
    /// Fades content out at the top and bottom edges.
    func fadedEdges() -> some View {
        mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}
