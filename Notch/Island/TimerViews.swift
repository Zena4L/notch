import SwiftUI

/// The Timer tab: the running countdown or stopwatch, or presets to start one.
struct TimerTabView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let timers = coordinator.timers
        Group {
            switch coordinator.focusedTimer {
            case .countdown:
                if let c = timers.countdown { CountdownCard(countdown: c) }
            case .stopwatch:
                if let s = timers.stopwatch { StopwatchCard(stopwatch: s) }
            case nil, .music, .download:
                TimerPresets()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CountdownCard: View {
    let countdown: TimerService.Countdown

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let timers = coordinator.timers
        TimelineView(.periodic(from: countdown.endDate, by: 1)) { context in
            TimerCardLayout(
                progress: countdown.progress(at: context.date),
                time: formatClock(countdown.remaining(at: context.date), padMinutes: true),
                subtitle: countdown.isPaused
                    ? "Timer · paused"
                    : "Timer · ends at \(countdown.endDate.formatted(date: .omitted, time: .shortened))"
            ) {
                CircleButton(title: "Cancel", style: .neutral) { timers.cancelCountdown() }
                if countdown.isPaused {
                    CircleButton(title: "Resume", style: .accent) { timers.resumeCountdown() }
                } else {
                    CircleButton(title: "Pause", style: .accent) { timers.pauseCountdown() }
                }
            }
        }
    }
}

private struct StopwatchCard: View {
    let stopwatch: TimerService.Stopwatch

    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let timers = coordinator.timers
        TimelineView(.periodic(from: stopwatch.startDate, by: 1)) { context in
            let elapsed = stopwatch.elapsed(at: context.date)
            TimerCardLayout(
                // The ring sweeps once a minute.
                progress: elapsed.truncatingRemainder(dividingBy: 60) / 60,
                time: formatClock(elapsed.rounded(.down), padMinutes: true),
                subtitle: stopwatch.isPaused ? "Stopwatch · paused" : "Stopwatch"
            ) {
                CircleButton(title: "Reset", style: .neutral) { timers.resetStopwatch() }
                if stopwatch.isPaused {
                    CircleButton(title: "Resume", style: .accent) { timers.resumeStopwatch() }
                } else {
                    CircleButton(title: "Pause", style: .accent) { timers.pauseStopwatch() }
                }
            }
        }
    }
}

/// Ring, large time and subtitle on the left; two round buttons on the right.
private struct TimerCardLayout<Buttons: View>: View {
    let progress: Double
    let time: String
    let subtitle: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(spacing: 22) {
            ProgressRing(progress: progress, lineWidth: 7)
                .frame(width: 77, height: 77)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(time)
                    .font(.system(size: 46, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Theme.orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: time)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { buttons }
        }
        .padding(.horizontal, 28)
        .padding(.top, 15)
    }
}

private struct TimerPresets: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ForEach(coordinator.settings.timerPresets, id: \.self) { minutes in
                    CircleButton(title: "\(minutes) min", style: .accent) {
                        coordinator.startCountdown(minutes: minutes)
                    }
                }
                CircleButton(symbol: "stopwatch", style: .neutral) {
                    coordinator.startStopwatch()
                }
                .accessibilityLabel("Start stopwatch")
            }
            Text("Start a timer · ⌥⌘T for \(coordinator.settings.quickTimerMinutes) min")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 22)
    }
}

// MARK: - Shared pieces

struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    var color: Color = Theme.orange

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

struct CircleButton: View {
    enum Style { case neutral, accent }

    private let title: String?
    private let symbol: String?
    private let style: Style
    private let action: () -> Void

    init(title: String, style: Style, action: @escaping () -> Void) {
        self.title = title
        self.symbol = nil
        self.style = style
        self.action = action
    }

    init(symbol: String, style: Style, action: @escaping () -> Void) {
        self.title = nil
        self.symbol = symbol
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                } else if let title {
                    Text(title).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(style == .accent ? Theme.orange : .white)
            .frame(width: 52, height: 52)
            .background(style == .accent ? Theme.orange.opacity(0.22) : .white.opacity(0.14), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
