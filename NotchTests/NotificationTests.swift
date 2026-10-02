import Foundation
import Testing
@testable import Notch

@MainActor
struct NotificationTests {
    @Test func readsActionNames() {
        #expect(NotificationService.actionTitle("Name:Mark as Read\nTarget:0x0\nSelector:(null)") == "Mark as Read")
        #expect(NotificationService.actionTitle("Name:Reply") == "Reply")
        #expect(NotificationService.actionTitle("AXPress") == "AXPress")
    }

    @Test func skipsTimeLabels() {
        for label in ["now", "Now", "2m ago", "10:42", "9:05 AM", "Yesterday", "3h ago"] {
            #expect(NotificationService.isTimestamp(label), "\(label)")
        }
        for text in ["Are we still on for lunch?", "Ama", "Meeting at 10:42 tomorrow", "2 new messages"] {
            #expect(!NotificationService.isTimestamp(text), "\(text)")
        }
    }

    @Test func sampleCanBeRepliedTo() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        let service = NotificationService(settings: settings)
        var arrived: [NotificationService.Item] = []
        service.onArrive = { arrived.append($0) }
        service.showSample()

        let item = try? #require(arrived.first)
        #expect(item?.isSample == true)
        #expect(item?.canReply == true)
        #expect(service.items.count == 1)

        let result = await service.reply(service.items[0].id, text: "Yes! See you there")
        #expect(result == .sent)
        #expect(service.items[0].canReply == false)  // handled: buttons go away
        #expect(service.items[0].actions.isEmpty)

        service.dismiss(service.items[0].id)
        #expect(service.items.isEmpty)
    }

    @Test func notificationPeekAndTab() {
        let id = UUID()
        let peek = Peek.notification(id)
        #expect(peek.isInteractive)
        #expect(IslandState.peek(peek).hasShadow)
        #expect(IslandState.peek(peek).contentKind != IslandState.peek(.notification(UUID())).contentKind)  // each one animates in
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        #expect(settings.notificationsEnabled == false)  // off until you turn it on
        #expect(settings.notificationApps.contains("WhatsApp"))
        #expect(settings.notificationsHideBanner)
    }
}
