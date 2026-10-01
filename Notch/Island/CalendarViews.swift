import SwiftUI

// MARK: - Meeting peek

/// 456 × 108: "Design review · Starts in 5 min · Google Meet" with a Join button.
struct MeetingPeekView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        if let meeting = coordinator.calendar.meeting {
            HStack(alignment: .top, spacing: 12) {
                CalendarIcon(date: meeting.start)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(meeting.title).font(.system(size: 14.5, weight: .bold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(meeting.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(subtitle(for: meeting))
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }
                if meeting.joinURL != nil {
                    Button { coordinator.joinMeeting() } label: {
                        Text("Join")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 16)
                            .background(Theme.blue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxHeight: 42)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 46)
            .frame(width: 456, height: 108, alignment: .top)
        }
    }

    private func subtitle(for meeting: CalendarService.Meeting) -> String {
        let minutes = max(1, Int((meeting.start.timeIntervalSinceNow / 60).rounded()))
        let starts = meeting.start > .now ? "Starts in \(minutes) min" : "Starting now"
        if let place = meeting.serviceName ?? meeting.location, !place.isEmpty {
            return "\(starts) · \(place)"
        }
        return starts
    }
}

private struct CalendarIcon: View {
    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.19))
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.black)
        }
        .frame(width: 42, height: 42)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
    }
}
