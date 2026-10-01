import AppKit
import Observation

/// Recent copied text, for the dashboard. Off by default; kept in memory only and gone
/// when Notch quits. macOS has no "clipboard changed" event, so while this is on we
/// glance at the clipboard's change counter once a second (reading only when it changes).
@Observable
final class ClipboardService {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Set when we put text back ourselves, so it isn't recorded twice.
    @ObservationIgnored private var ignoreChange: Int?

    private static let concealedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        observer = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(["dashboardEnabled", "clipboardHistory", "dashboardWidgets", "clipboardLimit"]) else { return }
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let on = settings.dashboardEnabled && settings.clipboardHistory && settings.dashboardWidgets.contains(.clipboard)
        if on, task == nil {
            lastChange = NSPasteboard.general.changeCount
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.check()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else if !on, task != nil {
            task?.cancel()
            task = nil
            entries = []
        }
        if entries.count > settings.clipboardLimit { entries = Array(entries.prefix(settings.clipboardLimit)) }
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if change == ignoreChange { return }
        if settings.clipboardIgnoreConcealed, let types = pasteboard.types, !Self.concealedTypes.isDisjoint(with: types) { return }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, date: .now), at: 0)
        if entries.count > settings.clipboardLimit { entries.removeLast(entries.count - settings.clipboardLimit) }
    }

    /// Puts an entry back on the clipboard, ready to paste.
    func copy(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        ignoreChange = pasteboard.changeCount
        entries.removeAll { $0.id == entry.id }
        entries.insert(Entry(text: entry.text, date: .now), at: 0)
    }

    func clear() { entries = [] }
}
