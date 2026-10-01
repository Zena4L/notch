import Darwin
import Foundation
import Observation

/// CPU, memory, storage and network readings for the dashboard.
///
/// Sampling only runs while a dashboard is on screen (views call `setVisible`), at the
/// interval chosen in Settings — so closed, it costs nothing.
@Observable
final class SystemStatsService {
    struct Reading: Equatable {
        var cpu: Double = 0  // 0…1
        var memoryUsed: Double = 0  // bytes
        var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
        var storageFree: Double = 0
        var storageTotal: Double = 0
        var downloadRate: Double = 0  // bytes per second
        var uploadRate: Double = 0
    }

    private(set) var reading = Reading()
    /// Recent values for the little graphs, oldest first.
    private(set) var cpuHistory: [Double] = []
    private(set) var networkHistory: [Double] = []

    static let historyLength = 30

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastCPU: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastNetwork: (received: UInt64, sent: UInt64, at: Date)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func setVisible(_ visible: Bool) {
        viewers = max(0, viewers + (visible ? 1 : -1))
        if viewers > 0, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled, let self {
                    self.sample()
                    try? await Task.sleep(for: .seconds(self.settings.statsInterval))
                }
            }
        } else if viewers == 0 {
            task?.cancel()
            task = nil
            lastNetwork = nil  // a stale baseline would give one bogus rate
        }
    }

    private func sample() {
        var r = reading
        if let cpu = Self.cpuTicks() {
            if let last = lastCPU, cpu.total > last.total {
                r.cpu = Double(cpu.busy - last.busy) / Double(cpu.total - last.total)
            }
            lastCPU = cpu
        }
        if let used = Self.memoryUsed() { r.memoryUsed = used }
        if let storage = Self.storage() { (r.storageFree, r.storageTotal) = storage }
        let now = Date()
        if let net = Self.networkBytes() {
            if let last = lastNetwork {
                let seconds = max(now.timeIntervalSince(last.at), 0.1)
                r.downloadRate = Double(Self.delta(net.received, last.received)) / seconds
                r.uploadRate = Double(Self.delta(net.sent, last.sent)) / seconds
            }
            lastNetwork = (net.received, net.sent, now)
        }
        reading = r
        cpuHistory = Array((cpuHistory + [r.cpu]).suffix(Self.historyLength))
        networkHistory = Array((networkHistory + [r.downloadRate + r.uploadRate]).suffix(Self.historyLength))
    }

    // MARK: Readings

    /// Busy and total CPU ticks since boot, across all cores.
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Roughly Activity Monitor's "Memory Used": app memory + wired + compressed.
    static func memoryUsed() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(sysconf(_SC_PAGESIZE))
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    static func storage() -> (free: Double, total: Double)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity else { return nil }
        return (Double(free), Double(total))
    }

    /// Total bytes in and out across Wi-Fi and Ethernet (en0, en1…).
    static func networkBytes() -> (received: UInt64, sent: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let p = pointer {
            let entry = p.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               String(cString: entry.ifa_name).hasPrefix("en"),
               let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                received += UInt64(data.ifi_ibytes)
                sent += UInt64(data.ifi_obytes)
            }
            pointer = entry.ifa_next
        }
        return (received, sent)
    }

    /// The interface counters are 32-bit and wrap at 4 GB.
    static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : new + (UInt64(UInt32.max) + 1) - old
    }
}
