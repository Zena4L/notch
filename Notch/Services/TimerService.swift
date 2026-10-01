import Foundation
import Observation

/// A countdown timer and a stopwatch. Both are stored as dates rather than ticking
/// counters: views work out the time left when they draw, and the only scheduled
/// work is a single wake-up when the countdown ends.
@Observable
final class TimerService {
    struct Countdown: Equatable {
        let id = UUID()
        let duration: TimeInterval
        var endDate: Date
        var pausedRemaining: TimeInterval?

        var isPaused: Bool { pausedRemaining != nil }

        func remaining(at date: Date) -> TimeInterval {
            pausedRemaining ?? max(0, endDate.timeIntervalSince(date))
        }

        /// 1 when just started, 0 when done.
        func progress(at date: Date) -> Double {
            duration > 0 ? remaining(at: date) / duration : 0
        }
    }

    struct Stopwatch: Equatable {
        var startDate: Date
        var pausedElapsed: TimeInterval?

        var isPaused: Bool { pausedElapsed != nil }

        func elapsed(at date: Date) -> TimeInterval {
            pausedElapsed ?? max(0, date.timeIntervalSince(startDate))
        }
    }

    private(set) var countdown: Countdown?
    private(set) var stopwatch: Stopwatch?

    @ObservationIgnored var onCountdownFinished: (() -> Void)?
    @ObservationIgnored private var finishTask: Task<Void, Never>?

    // MARK: Countdown

    func startCountdown(seconds: TimeInterval) {
        countdown = Countdown(duration: seconds, endDate: .now + seconds)
        scheduleFinish()
    }

    func pauseCountdown() {
        guard var c = countdown, !c.isPaused else { return }
        c.pausedRemaining = c.remaining(at: .now)
        countdown = c
        finishTask?.cancel()
    }

    func resumeCountdown() {
        guard var c = countdown, let remaining = c.pausedRemaining else { return }
        c.endDate = .now + remaining
        c.pausedRemaining = nil
        countdown = c
        scheduleFinish()
    }

    func cancelCountdown() {
        finishTask?.cancel()
        countdown = nil
    }

    private func scheduleFinish() {
        finishTask?.cancel()
        guard let c = countdown else { return }
        let id = c.id
        let delay = max(0, c.endDate.timeIntervalSinceNow)
        finishTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, countdown?.id == id else { return }
            finishCountdown()
        }
    }

    private func finishCountdown() {
        countdown = nil
        onCountdownFinished?()
    }

    // MARK: Stopwatch

    func startStopwatch() {
        stopwatch = Stopwatch(startDate: .now)
    }

    func pauseStopwatch() {
        guard var s = stopwatch, !s.isPaused else { return }
        s.pausedElapsed = s.elapsed(at: .now)
        stopwatch = s
    }

    func resumeStopwatch() {
        guard var s = stopwatch, let elapsed = s.pausedElapsed else { return }
        s.startDate = .now - elapsed
        s.pausedElapsed = nil
        stopwatch = s
    }

    func resetStopwatch() {
        stopwatch = nil
    }
}

/// "4:59", "04:59" or "1:04:59".
func formatClock(_ seconds: TimeInterval, padMinutes: Bool = false) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: padMinutes ? "%02d:%02d" : "%d:%02d", m, s)
}
