import Foundation
import Observation

/// Lyrics from LRCLIB (lrclib.net), a free, open lyrics database.
///
/// This is Notch's only network request: the song's title, artist, album and length are
/// sent when you open the Lyrics tab — never in the background. Results are cached for
/// the session, so going back to a song costs nothing.
@Observable
final class LyricsService {
    struct Line: Equatable, Identifiable {
        let id: Int
        let time: TimeInterval
        let text: String
    }

    enum Content: Equatable {
        case loading
        case synced([Line])
        case plain(String)
        case instrumental
        case notFound
        case failed
    }

    /// Lyrics for `contentKey`'s song.
    private(set) var content: Content = .loading
    private(set) var contentKey: String?

    @ObservationIgnored private var cache: [String: Content] = [:]
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral  // no cookies, no disk cache
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Notch/1.0 (macOS Dynamic Island; lyrics on demand)"]
        return URLSession(configuration: config)
    }()

    static func key(for track: NowPlayingService.Track) -> String {
        "\(track.title)\u{1F}\(track.artist)\u{1F}\(track.album)"
    }

    /// Loads lyrics for `track`, from the cache if we've seen it.
    func load(for track: NowPlayingService.Track, retry: Bool = false) async {
        let key = Self.key(for: track)
        if !retry, let cached = cache[key] {
            contentKey = key
            content = cached
            return
        }
        contentKey = key
        content = .loading

        let result = await fetch(track)
        cache[key] = result == .failed ? nil : result  // let failures retry later
        // The song may have changed while we waited.
        if contentKey == key { content = result }
    }

    private func fetch(_ track: NowPlayingService.Track) async -> Content {
        // Exact match first (title, artist, album, length), then a looser search.
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        do {
            if let record: Record = try await request(exact.url!), let content = record.content {
                return content
            }
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: track.artist),
            ]
            let records: [Record] = try await request(search.url!) ?? []
            // Prefer synced lyrics with a length close to the song's.
            let best = records
                .filter { $0.content != nil }
                .sorted { a, b in
                    if (a.syncedLyrics != nil) != (b.syncedLyrics != nil) { return a.syncedLyrics != nil }
                    return abs((a.duration ?? 0) - track.duration) < abs((b.duration ?? 0) - track.duration)
                }
                .first
            return best?.content ?? .notFound
        } catch {
            return .failed
        }
    }

    /// Returns nil for 404 (no lyrics); throws for network errors.
    private func request<T: Decodable>(_ url: URL) async throws -> T? {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Record: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let duration: Double?

        var content: Content? {
            if let synced = syncedLyrics, case let lines = LRC.parse(synced), !lines.isEmpty { return .synced(lines) }
            if let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty { return .plain(plain) }
            if instrumental == true { return .instrumental }
            return nil
        }
    }
}

/// Parses LRC: "[01:23.45] line" — a line may carry several timestamps.
enum LRC {
    static func parse(_ text: String) -> [LyricsService.Line] {
        let stamp = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/
        var entries: [(TimeInterval, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let matches = line.matches(of: stamp)
            guard !matches.isEmpty else { continue }  // metadata like [ar:…] or junk
            let lyric = line[matches.last!.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(match.output.1) ?? 0
                let seconds = Double(match.output.2.replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, lyric))
            }
        }
        return entries
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricsService.Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// Song-seconds are converted to real seconds using the playback rate (e.g. podcasts at 1.5×).
    /// Returns nil after the last line.
    static func secondsUntilNextLine(in lines: [LyricsService.Line], at time: TimeInterval, rate: Double) -> TimeInterval? {
        let next = (currentIndex(in: lines, at: time) ?? -1) + 1
        guard lines.indices.contains(next) else { return nil }
        let songSeconds = lines[next].time - (time + leadIn)
        return max(0.02, songSeconds / (rate > 0 ? rate : 1))
    }

    /// Lines light up a touch early, which reads as "on time".
    static let leadIn: TimeInterval = 0.25

    /// Index of the line being sung at `time`, or nil before the first line.
    static func currentIndex(in lines: [LyricsService.Line], at time: TimeInterval) -> Int? {
        let t = time + leadIn
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= t { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}
