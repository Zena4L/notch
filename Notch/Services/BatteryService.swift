import Foundation
import IOKit.ps
import Observation

/// Battery level and charger state. macOS tells us when anything changes,
/// so there's no polling.
@Observable
final class BatteryService {
    /// Percentage, or nil on Macs without a battery.
    private(set) var level: Int?
    private(set) var isCharging = false
    private(set) var isPluggedIn = false

    @ObservationIgnored var onPluggedIn: ((Int) -> Void)?
    @ObservationIgnored var onUnplugged: ((Int) -> Void)?
    @ObservationIgnored var onLowBattery: ((Int) -> Void)?

    /// Minutes until empty (on battery) or full (charging), when macOS has an estimate.
    var minutesRemaining: Int? {
        let estimate = IOPSGetTimeRemainingEstimate()
        guard estimate > 0 else { return nil }  // unknown, or plugged in with no estimate
        return Int(estimate / 60)
    }

    private static let lowThresholds = [10, 20]

    @ObservationIgnored private var source: CFRunLoopSource?
    /// The lowest threshold we've already warned about since the charger was last connected.
    @ObservationIgnored private var warnedThreshold: Int?

    init() {
        refresh(notify: false)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.refresh(notify: true) }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
    }

    private func refresh(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            level = nil
            return
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let wasPluggedIn = isPluggedIn

            level = percent
            isPluggedIn = pluggedIn
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false

            if notify, pluggedIn, !wasPluggedIn { onPluggedIn?(percent) }
            if notify, !pluggedIn, wasPluggedIn { onUnplugged?(percent) }
            checkLowBattery(percent, pluggedIn: pluggedIn, notify: notify)
            return
        }
        level = nil
    }

    private func checkLowBattery(_ percent: Int, pluggedIn: Bool, notify: Bool) {
        if pluggedIn {
            warnedThreshold = nil
            return
        }
        // Warn once at 20%, then once more at 10%.
        guard let threshold = Self.lowThresholds.first(where: { percent <= $0 }),
              threshold < (warnedThreshold ?? .max)
        else { return }
        warnedThreshold = threshold
        if notify { onLowBattery?(percent) }
    }
}
