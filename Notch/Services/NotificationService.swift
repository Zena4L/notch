import AppKit
import ApplicationServices
import Observation

/// Notifications from WhatsApp, Slack, Teams, Mail and other apps, in the island: read them,
/// reply, use the app's own buttons (Mark as Read, Archive…) or dismiss them, without opening
/// the app.
///
/// macOS has no API for reading other apps' notifications, so this reads the banners macOS
/// shows through Accessibility, the same permission as the volume overlay. Actions press the
/// banner's own buttons, so a reply goes through the app's inline reply. Banners are found by
/// what they offer (text and a Close action), not by a fixed layout, because Apple changes
/// that layout between macOS versions. Nothing is saved: notifications are kept in memory
/// and are gone when Notch quits.
@Observable
final class NotificationService {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let app: String
        let title: String
        let subtitle: String?
        let body: String
        let date: Date
        /// The app's own buttons, like "Mark as Read" or "Archive" (Reply and Close aside).
        var actions: [String]
        var canReply: Bool
        /// The banner is still on screen, so its buttons can be pressed.
        var isLive: Bool
        var isSample = false

        /// The app's icon, for the peek and the list.
        var icon: NSImage {
            if let url = NotificationService.appURL(named: app) { return NSWorkspace.shared.icon(forFile: url.path) }
            return NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil) ?? NSImage()
        }
    }

    enum ReplyResult: Equatable {
        case sent
        /// Couldn't send from the island: the app was opened and the reply copied, ready to paste.
        case openedApp
    }

    /// Newest first.
    private(set) var items: [Item] = []
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored var onArrive: ((Item) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observer: AXObserver?
    @ObservationIgnored private var appElement: AXUIElement?
    @ObservationIgnored private var elements: [UUID: AXUIElement] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    /// Recently seen content, so a banner that's re-laid out isn't announced twice.
    @ObservationIgnored private var recent: [(key: String, expires: Date)] = []
    /// What the last banner looked like to Accessibility, for Settings › Copy Diagnostics.
    @ObservationIgnored private(set) var lastBannerTree = ""

    static let notificationCenterID = "com.apple.notificationcenterui"
    static let limit = 30
    /// More new banners than this in one look means the Notification Center panel is open.
    static let burst = 3
    /// Chat and mail apps shown when "All apps" is off.
    static let defaultApps = ["WhatsApp", "Slack", "Microsoft Teams", "Mail", "Messages", "Microsoft Outlook", "Discord", "Telegram", "Signal"]

    init(settings: SettingsStore) {
        self.settings = settings
        tokens.append(NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(["notificationsEnabled"]) else { return }
            MainActor.assumeIsolated { self?.update() }
        })
        // Accessibility access changed for some app; ours may be among them.
        tokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.refreshTrust()
                }
            }
        })
        // Notification Center restarts now and then (and after `killall NotificationCenter`).
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard id == Self.notificationCenterID else { return }
            MainActor.assumeIsolated {
                self?.stop()
                self?.update()
            }
        })
        update()
    }

    // MARK: Permission

    func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
        update()
    }

    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Watching for banners

    private func update() {
        let on = settings.notificationsEnabled && isTrusted
        if on, observer == nil {
            start()
        } else if !on {
            stop()
        }
    }

    private func start() {
        guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterID).first else { return }
        let pid = center.processIdentifier
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        appElement = app
        scan()
    }

    private func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        pollTask?.cancel()
        pollTask = nil
        for i in items.indices { items[i].isLive = false }
        elements = [:]
    }

    /// Runs on the main run loop, where the observer's source was added.
    nonisolated private static let callback: AXObserverCallback = { _, _, _, refcon in
        let address = UInt(bitPattern: refcon)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<NotificationService>.fromOpaque(pointer).takeUnretainedValue().bannersMayHaveChanged()
        }
    }

    private func bannersMayHaveChanged() {
        // Banners fill in their text a moment after their window appears.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            scan()
        }
    }

    /// Looks over Notification Center's windows; polls twice a second only while banners show.
    private func scan() {
        guard let appElement else { return }
        let windows = Self.elements(appElement, kAXWindowsAttribute)
        var banners: [AXUIElement] = []
        for window in windows { Self.collectBanners(window, depth: 0, into: &banners) }

        // Which of ours are still on screen.
        for i in items.indices where items[i].isLive && !items[i].isSample {
            let alive = elements[items[i].id].map { element in banners.contains { CFEqual($0, element) } } ?? false
            if !alive {
                items[i].isLive = false
                elements[items[i].id] = nil
            }
        }

        recent.removeAll { $0.expires < .now }
        let running = Self.runningAppNames()
        var fresh: [(Item, AXUIElement, String)] = []
        for banner in banners where !elements.values.contains(where: { CFEqual($0, banner) }) {
            guard let item = Self.read(banner, runningApps: running) else { continue }
            let key = "\(item.app)|\(item.title)|\(item.body)"
            guard !recent.contains(where: { $0.key == key }) else { continue }
            fresh.append((item, banner, key))
        }
        if fresh.count > Self.burst {
            // Several at once is the Notification Center panel listing old ones, not new banners.
            for (_, _, key) in fresh { recent.append((key, .now.addingTimeInterval(600))) }
        } else {
            for (item, banner, key) in fresh {
                recent.append((key, .now.addingTimeInterval(30)))
                guard shouldShow(item) else { continue }
                lastBannerTree = Self.describe(banner)
                add(item, element: banner)
            }
        }

        if windows.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        } else if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.scan()
                }
            }
        }
    }

    private func shouldShow(_ item: Item) -> Bool {
        if settings.notificationsAllApps { return true }
        let app = item.app.lowercased()
        return settings.notificationApps.contains { chosen in
            let chosen = chosen.lowercased()
            return app == chosen || app.contains(chosen) || chosen.contains(app)
        }
    }

    private func add(_ item: Item, element: AXUIElement?) {
        items.insert(item, at: 0)
        if items.count > Self.limit {
            for old in items.suffix(from: Self.limit) { elements[old.id] = nil }
            items.removeLast(items.count - Self.limit)
        }
        if let element { elements[item.id] = element }
        onArrive?(item)
        // Move it into the notch: a banner with nothing to press goes straight away. One with
        // Reply or other buttons stays until it's used (pressing needs it on screen) or times out.
        if settings.notificationsHideBanner, let element, !item.canReply, item.actions.isEmpty {
            Self.perform("Close", on: element)
        }
    }

    // MARK: Acting on them

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    /// Opens the app, at the conversation when the banner is still there.
    func open(_ id: UUID) {
        guard let item = item(id) else { return }
        if let element = elements[id], AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            markHandled(id)
        } else {
            Self.activate(app: item.app)
        }
    }

    /// Presses one of the app's own buttons, like "Mark as Read".
    @discardableResult
    func perform(_ action: String, on id: UUID) -> Bool {
        guard let item = item(id) else { return false }
        if item.isSample {
            markHandled(id)
            return true
        }
        guard let element = elements[id], Self.perform(action, on: element) else { return false }
        markHandled(id)
        return true
    }

    func dismiss(_ id: UUID) {
        if let element = elements[id] { Self.perform("Close", on: element) }
        elements[id] = nil
        items.removeAll { $0.id == id }
    }

    func clearAll() {
        for id in items.map(\.id) { dismiss(id) }
    }

    /// Replies through the app's own inline reply on the banner. If the banner has gone, opens
    /// the app with the reply on the clipboard instead.
    func reply(_ id: UUID, text: String) async -> ReplyResult {
        guard let item = item(id) else { return .openedApp }
        if item.isSample {
            try? await Task.sleep(for: .milliseconds(500))
            markHandled(id)
            return .sent
        }
        if let element = elements[id], Self.perform("Reply", on: element) {
            // The banner swaps in a text field.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(150))
                let window = Self.element(element, kAXWindowAttribute)
                if let field = Self.find(in: element, roles: [kAXTextFieldRole, kAXTextAreaRole]) ?? window.flatMap({ Self.find(in: $0, roles: [kAXTextFieldRole, kAXTextAreaRole]) }) {
                    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
                    try? await Task.sleep(for: .milliseconds(100))
                    if Self.send(from: field, banner: window ?? element) {
                        markHandled(id)
                        return .sent
                    }
                    break
                }
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        open(id)
        return .openedApp
    }

    private func markHandled(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isLive = false
        items[index].actions = []
        items[index].canReply = false
        elements[id] = nil
    }

    // MARK: Try it

    /// Settings › Try it: a pretend WhatsApp message. Replying to it just pretends to send.
    func showSample() {
        let item = Item(
            app: "WhatsApp", title: "Ama", subtitle: nil, body: "Are we still on for lunch at 1? 🍜",
            date: .now, actions: ["Mark as Read"], canReply: true, isLive: true, isSample: true
        )
        add(item, element: nil)
    }

    // MARK: Diagnostics

    /// What Notification Center looks like to Accessibility right now, and the last banner
    /// Notch read. It can include the text of notifications.
    func diagnostics() -> String {
        var report = "Notch notifications · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · trusted=\(isTrusted) watching=\(observer != nil)\n"
        if let appElement {
            for window in Self.elements(appElement, kAXWindowsAttribute) { report += Self.describe(window) }
        }
        report += "\nLast banner:\n" + (lastBannerTree.isEmpty ? "(none yet)" : lastBannerTree)
        return report
    }
}

// MARK: - Accessibility plumbing

extension NotificationService {
    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] { elements(element, kAXChildrenAttribute) }

    /// Action names as macOS reports them; custom ones look like "Name:Reply\nTarget:…".
    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String]) ?? []
    }

    /// "Name:Mark as Read\nTarget:0x0\nSelector:(null)" → "Mark as Read"; "AXPress" stays.
    nonisolated static func actionTitle(_ raw: String) -> String {
        guard raw.hasPrefix("Name:") else { return raw }
        let rest = raw.dropFirst(5)
        return String(rest.split(separator: "\n", maxSplits: 1).first ?? rest)
    }

    @discardableResult
    static func perform(_ title: String, on element: AXUIElement) -> Bool {
        guard let raw = actionNames(element).first(where: { actionTitle($0).caseInsensitiveCompare(title) == .orderedSame }) else { return false }
        return AXUIElementPerformAction(element, raw as CFString) == .success
    }

    /// A banner is the innermost element that has a Close action (or a notification subrole)
    /// and some text.
    @discardableResult
    static func collectBanners(_ element: AXUIElement, depth: Int, into banners: inout [AXUIElement]) -> Bool {
        guard depth < 12 else { return false }
        var foundBelow = false
        for child in children(element) {
            if collectBanners(child, depth: depth + 1, into: &banners) { foundBelow = true }
        }
        if foundBelow { return true }
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let hasClose = actionNames(element).contains { actionTitle($0) == "Close" }
        let looksLikeBanner = subrole.hasPrefix("AXNotificationCenter") && !subrole.contains("Stack")
        guard hasClose || looksLikeBanner, !texts(in: element).isEmpty else { return false }
        banners.append(element)
        return true
    }

    /// Visible text, top to bottom.
    static func texts(in element: AXUIElement, depth: Int = 0) -> [(text: String, identifier: String?)] {
        guard depth < 8 else { return [] }
        var found: [(String, String?)] = []
        if string(element, kAXRoleAttribute) == kAXStaticTextRole,
           let value = string(element, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            found.append((value, string(element, kAXIdentifierAttribute)))
        }
        for child in children(element) { found += texts(in: child, depth: depth + 1) }
        return found
    }

    static func find(in element: AXUIElement, roles: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 10 else { return nil }
        if let role = string(element, kAXRoleAttribute), roles.contains(role) { return element }
        for child in children(element) {
            if let match = find(in: child, roles: roles, depth: depth + 1) { return match }
        }
        return nil
    }

    /// Sends what's in the reply field: the banner's Send button, else Return.
    static func send(from field: AXUIElement, banner: AXUIElement) -> Bool {
        if let button = findButton(in: banner, titled: ["Send", "Reply"]),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success { return true }
        if AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success { return true }
        var pid: pid_t = 0
        AXUIElementGetPid(field, &pid)
        guard pid != 0, let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    static func findButton(in element: AXUIElement, titled titles: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 10 else { return nil }
        if string(element, kAXRoleAttribute) == kAXButtonRole {
            let label = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
            if titles.contains(where: { label.caseInsensitiveCompare($0) == .orderedSame }) { return element }
        }
        for child in children(element) {
            if let match = findButton(in: child, titled: titles, depth: depth + 1) { return match }
        }
        return nil
    }

    /// Turns a banner into an item: which app, its title and text, and its buttons.
    static func read(_ banner: AXUIElement, runningApps: [String]) -> Item? {
        var texts = Self.texts(in: banner).filter { !isTimestamp($0.text) }
        guard !texts.isEmpty else { return nil }
        let description = string(banner, kAXDescriptionAttribute) ?? ""

        // The app's name: a line that names a running app, or the start of the description
        // ("WhatsApp, Ama, Hi"), or the app icon's label.
        var app: String?
        if let index = texts.firstIndex(where: { line in runningApps.contains { $0.caseInsensitiveCompare(line.text) == .orderedSame } }), texts.count > 1 {
            app = texts.remove(at: index).text
        }
        if app == nil {
            app = runningApps.first { description.hasPrefix($0 + ",") || description == $0 }
        }
        if app == nil, let image = find(in: banner, roles: [kAXImageRole]), let label = string(image, kAXDescriptionAttribute), !label.isEmpty {
            app = label
        }

        func tagged(_ id: String) -> String? { texts.first { $0.identifier?.lowercased().contains(id) == true }?.text }
        let title = tagged("title") ?? texts[0].text
        let rest = texts.map(\.text).filter { $0 != title }
        let body = tagged("body") ?? rest.last ?? ""
        let subtitle = tagged("subtitle") ?? (rest.count >= 2 ? rest.first : nil)

        let names = actionNames(banner).map(actionTitle)
        let skip: Set<String> = ["Close", "Show Details", "Show", "Options", "Clear All", "Reply", "AXPress", "AXShowMenu", "AXRaise", "AXCancel", "AXConfirm"]
        let actions = names.filter { !skip.contains($0) && !$0.hasPrefix("AX") }
        return Item(
            app: app ?? "Notification", title: title, subtitle: subtitle, body: body == title ? "" : body,
            date: .now, actions: Array(actions.prefix(2)), canReply: names.contains("Reply"), isLive: true
        )
    }

    /// "now", "2m ago", "10:42", "Yesterday": the banner's time label, not its content.
    nonisolated static func isTimestamp(_ text: String) -> Bool {
        let t = text.lowercased()
        if ["now", "just now", "yesterday"].contains(t) { return true }
        return t.range(of: #"^\d{1,2}(:\d{2})?\s?(am|pm)?$|^\d+\s?(s|m|min|h|d|w)\s?ago$"#, options: .regularExpression) != nil
    }

    static func runningAppNames() -> [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
    }

    static func appURL(named name: String) -> URL? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let url = running.bundleURL { return url }
        for folder in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func activate(app name: String) {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            running.activate()
        } else if let url = appURL(named: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// An outline of an element and everything inside it, for diagnostics.
    static func describe(_ element: AXUIElement, depth: Int = 0) -> String {
        guard depth < 12 else { return "" }
        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute).map { " \($0)" } ?? ""
        let identifier = string(element, kAXIdentifierAttribute).map { " id=\($0)" } ?? ""
        let title = string(element, kAXTitleAttribute).map { " title=\"\($0.prefix(60))\"" } ?? ""
        let value = (attribute(element, kAXValueAttribute) as? String).map { " value=\"\($0.prefix(60))\"" } ?? ""
        let description = string(element, kAXDescriptionAttribute).map { " desc=\"\($0.prefix(80))\"" } ?? ""
        let actions = actionNames(element).map(actionTitle).filter { !$0.hasPrefix("AXScroll") }
        var line = String(repeating: "  ", count: depth) + role + subrole + identifier + title + value + description
        if !actions.isEmpty { line += " actions=\(actions)" }
        return line + "\n" + children(element).map { describe($0, depth: depth + 1) }.joined()
    }
}
