import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings › Shortcuts: record your own key combinations, plus links for Shortcuts and scripts.
struct ShortcutsPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HotkeyStatus.self) private var status

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                row("Open or close the island", $settings.toggleShortcut, "toggle")
                row("Start a \(settings.quickTimerMinutes)-minute timer", $settings.timerShortcut, "timer")
                row("Play / pause", $settings.playPauseShortcut, "playPause")
                row("Show dashboard", $settings.dashboardShortcut, "dashboard")
                row("Show downloads", $settings.downloadsShortcut, "downloads")
            } footer: {
                Text("Shortcuts work everywhere and don't need Accessibility access. Click a shortcut, then press the new keys; Esc cancels.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Self.links, id: \.url) { link in
                    LabeledContent {
                        HStack {
                            Text(link.url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link.url, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                    } label: {
                        Text(link.title)
                    }
                }
            } header: {
                Text("Links")
            } footer: {
                Text("Use these in the Shortcuts app (Open URL) or Terminal (open \"notch://…\").")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }

    private func row(_ title: String, _ shortcut: Binding<KeyShortcut>, _ name: String) -> some View {
        LabeledContent {
            ShortcutRecorder(shortcut: shortcut)
        } label: {
            Text(title)
            if status.failed.contains(name) {
                Text("In use by another app — choose a different one").foregroundStyle(.red)
            }
        }
    }

    private static let links: [(title: String, url: String)] = [
        ("25-minute timer", "notch://timer?minutes=25"),
        ("Stopwatch", "notch://stopwatch"),
        ("Play / pause", "notch://play-pause"),
        ("Next track", "notch://next"),
        ("Previous track", "notch://previous"),
        ("Open or close", "notch://toggle"),
        ("Show dashboard", "notch://dashboard"),
        ("Show downloads", "notch://downloads"),
        ("Open Settings", "notch://settings"),
        ("Download a link", "notch://download?url=https%3A%2F%2Fyoutu.be%2F…"),
    ]
}

/// A button showing a shortcut like "⌥⌘N". Click it, then press keys to change it.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(isRecording ? "Type shortcut…" : (shortcut.isSet ? shortcut.displayString : "Not set")) {
                isRecording ? stop() : start()
            }
            .font(.system(size: 12, design: .rounded))
            .frame(minWidth: 110)
            if shortcut.isSet, !isRecording {
                Button {
                    shortcut = .none
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require ⌘, ⌥ or ⌃ so plain typing never becomes a global shortcut.
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            shortcut = KeyShortcut(keyCode: Int(event.keyCode), modifiers: flags.carbonModifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private extension NSEvent.ModifierFlags {
    var carbonModifiers: Int {
        var result = 0
        if contains(.command) { result |= cmdKey }
        if contains(.option) { result |= optionKey }
        if contains(.control) { result |= controlKey }
        if contains(.shift) { result |= shiftKey }
        return result
    }
}

extension KeyShortcut {
    /// "⌃⌥⇧⌘K" in the standard macOS order.
    var displayString: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[code] { return name }
        return character(for: code) ?? "Key \(code)"
    }

    /// The character the key types on the current keyboard layout (so it's right on AZERTY too).
    private static func character(for code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
