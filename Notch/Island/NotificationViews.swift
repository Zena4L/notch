import SwiftUI

/// A notification from another app, under the notch: who and what, then Reply, the app's own
/// buttons (Mark as Read, Archive…), and Open. Reply turns the buttons into a text field.
struct NotificationPeekView: View {
    let id: UUID
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        if let item = coordinator.notifications.item(id) {
            VStack(alignment: .leading, spacing: 8) {
                NotificationSummary(item: item, bodyLines: 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.notifications.open(id)
                        coordinator.dismissPeek()
                    }
                NotificationActions(item: item) { coordinator.dismissPeek() }
            }
            .padding(.horizontal, 20)
            .padding(.top, coordinator.notchSize.height + 6)
            .frame(width: 468, height: 128, alignment: .top)
        }
    }
}

/// The Notifications tab: the last notifications, newest first, each with its buttons.
struct NotificationsView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let service = coordinator.notifications
        Group {
            if !service.isTrusted {
                placeholder("bell.badge", "Notifications need Accessibility access", "Turn it on in Settings › Activities › Notifications")
            } else if service.items.isEmpty {
                placeholder("bell", "Nothing new", coordinator.settings.notificationsAllApps
                            ? "Notifications from your apps show up here"
                            : "Notifications from WhatsApp, Slack, Teams, Mail and others show up here")
            } else {
                VStack(spacing: 6) {
                    HStack {
                        Text("\(service.items.count) recent")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button("Clear All") { service.clearAll() }
                            .font(.system(size: 11.5, weight: .medium))
                            .buttonStyle(IslandButtonStyle(cornerRadius: 5, padding: 4))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(service.items) { item in
                                NotificationRow(item: item)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22))
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotificationRow: View {
    let item: NotificationService.Item
    @Environment(IslandCoordinator.self) private var coordinator
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 0) {
                NotificationSummary(item: item, bodyLines: 1, iconSize: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.notifications.open(item.id)
                        coordinator.collapse()
                    }
                Button { coordinator.notifications.dismiss(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 10, padding: 0))
                .opacity(isHovered ? 1 : 0)
                .help("Dismiss")
            }
            if item.canReply || !item.actions.isEmpty {
                NotificationActions(item: item, showsOpen: false) {}
                    .padding(.leading, 38)
            }
        }
        .padding(9)
        .background(.white.opacity(isHovered ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
    }
}

/// Icon, sender and app, and the message.
private struct NotificationSummary: View {
    let item: NotificationService.Item
    var bodyLines = 2
    var iconSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(item.app) · \(item.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Text([item.subtitle, item.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(bodyLines)
            }
        }
    }
}

/// Reply, the app's own buttons and Open, or the reply field once Reply is pressed.
private struct NotificationActions: View {
    let item: NotificationService.Item
    var showsOpen = true
    /// After something was done with it.
    let done: () -> Void

    @Environment(IslandCoordinator.self) private var coordinator
    @State private var replying = false
    @State private var text = ""
    @State private var status: Status = .idle
    @FocusState private var focused: Bool

    private enum Status: Equatable { case idle, sending, sent, openedApp }

    var body: some View {
        Group {
            switch status {
            case .sent:
                Label("Sent", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.green)
                    .transition(.blurReplace)
            case .openedApp:
                Label("Opened \(item.app) · your reply is copied, paste it there", systemImage: "doc.on.clipboard")
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .transition(.blurReplace)
            case .idle, .sending:
                if replying { replyField } else { buttons }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .animation(.spring(duration: 0.35, bounce: 0.2), value: replying)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: status)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            if item.canReply {
                Chip(title: "Reply", symbol: "arrowshape.turn.up.left.fill", isPrimary: true) { startReply() }
            }
            ForEach(item.actions, id: \.self) { action in
                Chip(title: action, symbol: nil) {
                    coordinator.notifications.perform(action, on: item.id)
                    done()
                }
            }
            if showsOpen {
                Chip(title: "Open", symbol: "arrow.up.forward.app") {
                    coordinator.notifications.open(item.id)
                    done()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var replyField: some View {
        HStack(spacing: 6) {
            TextField("", text: $text, prompt: Text("Reply to \(item.title)…").foregroundStyle(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand(perform: cancelReply)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.12), in: Capsule())
                .disabled(status == .sending)
            Button(action: send) {
                Group {
                    if status == .sending {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    }
                }
                .frame(width: 26, height: 26)
                .background(text.isEmpty ? .white.opacity(0.12) : Theme.blue, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || status == .sending)
            .accessibilityLabel("Send")
            Button(action: cancelReply) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 11, padding: 0))
        }
    }

    private func startReply() {
        replying = true
        coordinator.holdPeek()
        coordinator.isTyping = true
        coordinator.requestKeyboard()
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    private func cancelReply() {
        replying = false
        text = ""
        coordinator.isTyping = false
        coordinator.releasePeek(after: .seconds(3))
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, status == .idle else { return }
        status = .sending
        Task {
            let result = await coordinator.notifications.reply(item.id, text: message)
            status = result == .sent ? .sent : .openedApp
            coordinator.isTyping = false
            if coordinator.settings.haptics, result == .sent {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            coordinator.releasePeek(after: .seconds(result == .sent ? 1.2 : 3))
            try? await Task.sleep(for: .seconds(2.5))
            replying = false
            text = ""
            status = .idle
            done()
        }
    }
}

private struct Chip: View {
    let title: String
    let symbol: String?
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isPrimary ? Theme.blue : .white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
