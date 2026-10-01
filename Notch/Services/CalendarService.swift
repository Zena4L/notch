import AppKit
import EventKit
import Foundation
import Observation

/// Announces meetings five minutes before they start.
///
/// Event-driven: we schedule one wake-up for the next event and recompute
/// whenever the calendar database changes — no polling.
@Observable
final class CalendarService {
    struct Meeting: Equatable {
        let title: String
        let start: Date
        let joinURL: URL?
        let serviceName: String?
        let location: String?
    }

    private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    /// The meeting currently being announced.
    private(set) var meeting: Meeting?

    var isAuthorized: Bool { authorization == .fullAccess }

    @ObservationIgnored var onMeetingSoon: (() -> Void)?

    /// Calendars to choose from in Settings.
    private(set) var calendars: [CalendarInfo] = []

    struct CalendarInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let source: String
        let color: CGColor?
    }

    private var leadTime: TimeInterval { TimeInterval(max(settings.meetingLeadMinutes, 1) * 60) }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(settings: SettingsStore) {
        self.settings = settings
        observers.append(NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            // Re-reading the calendar is the expensive part; only do it for calendar settings.
            guard note.affects(["calendarEnabled", "excludedCalendarIDs", "meetingLeadMinutes", "meetingAlertAtStart"]) else { return }
            MainActor.assumeIsolated { self?.update() }
        })
        update()
    }

    // MARK: Access

    /// Shows the system prompt (first time only). Returns whether access was granted.
    @discardableResult
    func requestAccess() async -> Bool {
        let store = store ?? EKEventStore()
        self.store = store
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        refreshAuthorization()
        return granted
    }

    func refreshAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status != authorization else { return }
        authorization = status
        update()
    }

    struct Upcoming: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: CGColor?
        let joinURL: URL?
    }

    /// The rest of today's events, for the dashboard. Reads EventKit on demand only.
    func upcomingToday(limit: Int = 3) -> [Upcoming] {
        guard settings.calendarEnabled, isAuthorized, let store else { return [] }
        let now = Date()
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let excluded = Set(settings.excludedCalendarIDs)
        let calendars = store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: calendars)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && !$0.isDeclinedByMe }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                Upcoming(
                    id: event.announcementKey, title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                    color: event.calendar?.cgColor,
                    joinURL: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])?.url
                )
            }
    }

    /// A sample meeting for Settings › Try it, used only when nothing real is scheduled.
    func prepareSampleMeeting() {
        guard meeting == nil || meeting!.start < .now - 3600 else { return }
        meeting = Meeting(
            title: "Design review", start: .now + 5 * 60,
            joinURL: URL(string: "https://meet.google.com/"), serviceName: "Google Meet", location: nil
        )
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scheduling

    private func update() {
        scheduleTask?.cancel()
        guard settings.calendarEnabled, isAuthorized else {
            stopObservingStore()
            return
        }
        if store == nil { store = EKEventStore() }
        startObservingStore()
        reloadCalendars()
        schedule()
    }

    @ObservationIgnored private var storeObserver: NSObjectProtocol?

    private func startObservingStore() {
        guard storeObserver == nil, let store else { return }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadCalendars()
                self?.schedule()
            }
        }
    }

    private func reloadCalendars() {
        let list = (store?.calendars(for: .event) ?? [])
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: $0.cgColor) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        if list != calendars { calendars = list }
    }

    private func stopObservingStore() {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    private func schedule() {
        scheduleTask?.cancel()
        guard let store else { return }

        let now = Date()
        let excluded = Set(settings.excludedCalendarIDs)
        let included = store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
        guard !included.isEmpty else { return }
        let predicate = store.predicateForEvents(withStart: now - 60, end: now + 24 * 3600, calendars: included)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && !$0.isDeclinedByMe }

        // Each event can fire a reminder (lead time before) and, optionally, an alert at the start.
        var alerts: [(date: Date, key: String, event: EKEvent)] = []
        for event in events {
            let key = event.announcementKey
            if event.startDate > now { alerts.append((event.startDate - leadTime, key + "#lead", event)) }
            if settings.meetingAlertAtStart, event.startDate > now - 60 {
                alerts.append((event.startDate, key + "#start", event))
            }
        }
        guard let next = alerts.filter({ !announced.contains($0.key) }).min(by: { $0.date < $1.date }) else {
            // Nothing in the next day: look again later in case the day rolls over.
            sleep(until: now + 6 * 3600)
            return
        }

        if next.date <= now {
            announced.insert(next.key)
            announce(next.event)
            schedule()
        } else {
            sleep(until: next.date)
        }
    }

    private func sleep(until date: Date) {
        scheduleTask = Task {
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            schedule()  // re-read the calendar so changes since we slept are respected
        }
    }

    private func announce(_ event: EKEvent) {
        let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        meeting = Meeting(
            title: event.title ?? "Event",
            start: event.startDate,
            joinURL: link?.url,
            serviceName: link?.service,
            location: link == nil ? event.location : nil
        )
        onMeetingSoon?()
    }
}

/// Finds Zoom, Google Meet and Teams links in an event's URL, location or notes.
enum MeetingLink {
    private static let patterns: [(service: String, regex: Regex<Substring>)] = [
        ("Zoom", /https:\/\/[\w.-]*zoom\.us\/(?:j|my|w)\/[^\s<>"']+/),
        ("Google Meet", /https:\/\/meet\.google\.com\/[a-z0-9-]+/),
        ("Microsoft Teams", /https:\/\/teams\.(?:microsoft|live)\.com\/[^\s<>"']+/),
    ]

    static func find(in texts: [String?]) -> (url: URL, service: String)? {
        for text in texts.compactMap({ $0 }) {
            for (service, regex) in patterns {
                if let match = text.firstMatch(of: regex), let url = URL(string: String(match.output)) {
                    return (url, service)
                }
            }
        }
        return nil
    }
}

private extension EKEvent {
    var announcementKey: String {
        "\(calendarItemIdentifier)@\(startDate.timeIntervalSince1970)"
    }

    var isDeclinedByMe: Bool {
        attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
