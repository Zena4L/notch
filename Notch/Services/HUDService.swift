import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Observation

/// Replaces the system volume and brightness overlay.
///
/// An event tap catches the media keys (volume up/down/mute, brightness up/down) before
/// macOS does; we change the level ourselves and show it in the island. Keys we can't
/// handle — say, an HDMI output without volume control — pass through to macOS untouched.
/// Event taps need Accessibility permission, so this is off until you turn it on.
@Observable
final class HUDService {
    enum Kind: Hashable { case volume, brightness }

    private(set) var isTrusted = AXIsProcessTrusted()
    @ObservationIgnored var onChange: ((Kind, Double, Bool) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(settings: SettingsStore) {
        self.settings = settings
        observers.append(NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(["hudEnabled", "hudVolume", "hudBrightness"]) else { return }
            MainActor.assumeIsolated { self?.update() }
        })
        // macOS broadcasts this when any app's Accessibility access changes.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The new value lands slightly after the notification.
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.refreshTrust()
                }
            }
        })
        update()
    }

    // MARK: Permission

    func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt (a C global Swift 6 won't read directly).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
        update()
    }

    // MARK: Tap

    private func update() {
        let wanted = settings.hudEnabled && (settings.hudVolume || settings.hudBrightness) && isTrusted
        if wanted, tap == nil { start() }
        if !wanted, tap != nil { stop() }
    }

    private func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<HUDService>.fromOpaque(context).takeUnretainedValue()
            let consumed = MainActor.assumeIsolated { service.handle(type: type, event: event) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        // NSEvent.EventType.systemDefined (14) carries the media keys.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14), callback: callback, userInfo: context
        ) else {
            NSLog("Notch: couldn't create the media key tap (Accessibility access?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns true to swallow the event (so macOS doesn't show its own overlay).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS switches a tap off if it's ever too slow; switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }

        let key = Int((ns.data1 & 0xFFFF_0000) >> 16)
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        // ⌥⇧ gives quarter steps, like the system.
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        let step = 1 / Double(settings.hudSteps) / (fine ? 4 : 1)

        switch key {
        case MediaKey.soundUp, MediaKey.soundDown, MediaKey.mute:
            guard settings.hudVolume else { return false }
            guard isDown else { return SystemVolume.isControllable }  // swallow key-ups too, if we own volume
            return changeVolume(key: key, step: step)
        case MediaKey.brightnessUp, MediaKey.brightnessDown:
            guard settings.hudBrightness else { return false }
            guard isDown else { return DisplayBrightness.isAvailable }
            return changeBrightness(up: key == MediaKey.brightnessUp, step: step)
        default:
            return false
        }
    }

    private func changeVolume(key: Int, step: Double) -> Bool {
        guard SystemVolume.isControllable, var level = SystemVolume.level else { return false }
        var muted = SystemVolume.isMuted

        switch key {
        case MediaKey.mute:
            muted.toggle()
        case MediaKey.soundUp:
            muted = false
            level = min(1, (level / step).rounded() * step + step)
        default:
            level = max(0, (level / step).rounded() * step - step)
            muted = level == 0
        }
        SystemVolume.level = level
        SystemVolume.isMuted = muted
        onChange?(.volume, level, muted)
        return true
    }

    private func changeBrightness(up: Bool, step: Double) -> Bool {
        guard var level = DisplayBrightness.level else { return false }
        level = up ? min(1, (level / step).rounded() * step + step) : max(0, (level / step).rounded() * step - step)
        DisplayBrightness.level = level
        onChange?(.brightness, level, false)
        return true
    }
}

/// NX_KEYTYPE_* values from IOKit's ev_keymap.h.
private enum MediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3
    static let mute = 7
}

// MARK: - Core Audio

/// The default output device's volume and mute, through Core Audio.
enum SystemVolume {
    private static var device: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// False for outputs like HDMI that don't let software change their volume.
    static var isControllable: Bool {
        guard let device else { return false }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioHardwareServiceIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static var level: Double? {
        get {
            guard let device else { return nil }
            var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return Double(value)
        }
        set {
            guard let device, let newValue else { return }
            var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value = Float32(newValue)
            AudioHardwareServiceSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    static var isMuted: Bool {
        get {
            guard let device else { return false }
            var address = address(kAudioDevicePropertyMute)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
            return value != 0
        }
        set {
            guard let device else { return }
            var address = address(kAudioDevicePropertyMute)
            var value = UInt32(newValue ? 1 : 0)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}

// MARK: - Display brightness

/// The built-in display's brightness, through the private DisplayServices framework.
/// Loaded at runtime; if it ever disappears, brightness keys simply go back to macOS.
enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setBrightness = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }

    private static var builtInDisplay: CGDirectDisplayID? {
        NSScreen.screens.map(\.displayID).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isAvailable: Bool { getBrightness != nil && setBrightness != nil && builtInDisplay != nil }

    static var level: Double? {
        get {
            guard let getBrightness, let display = builtInDisplay else { return nil }
            var value: Float = 0
            return getBrightness(display, &value) == 0 ? Double(value) : nil
        }
        set {
            guard let setBrightness, let display = builtInDisplay, let newValue else { return }
            _ = setBrightness(display, Float(newValue))
        }
    }
}
