import SwiftUI

/// The Dashboard tab: a grid of widgets, four small slots per row (wide widgets take two).
/// System readings run only while this is on screen.
struct DashboardView: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let settings = coordinator.settings
        let rows = DashboardLayout.rows(settings.dashboardWidgets, maxRows: settings.dashboardMaxRows)

        VStack(spacing: DashboardLayout.spacing) {
            if settings.dashboardWidgets.isEmpty {
                Text("Choose widgets in Settings › Dashboard")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: DashboardLayout.spacing) {
                    ForEach(row, id: \.self) { widget in
                        WidgetCard(widget: widget)
                            .frame(width: width(for: widget))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: DashboardLayout.rowHeight)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { coordinator.stats.setVisible(true) }
        .onDisappear { coordinator.stats.setVisible(false) }
        .task { await coordinator.weather.refreshIfNeeded() }
    }

    /// 496 pt of content width, split into four slots.
    private func width(for widget: DashboardWidget) -> CGFloat {
        let slot = (540 - 44 - 3 * DashboardLayout.spacing) / 4
        return slot * CGFloat(widget.width) + DashboardLayout.spacing * CGFloat(widget.width - 1)
    }
}

private struct WidgetCard: View {
    let widget: DashboardWidget

    var body: some View {
        Group {
            switch widget {
            case .cpu: CPUWidget()
            case .memory: MemoryWidget()
            case .storage: StorageWidget()
            case .network: NetworkWidget()
            case .battery: BatteryWidget()
            case .weather: WeatherWidget()
            case .calendar: CalendarWidget()
            case .clipboard: ClipboardWidget()
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Building blocks

private struct WidgetHeader: View {
    let title: String
    let symbol: String
    var tint: Color = .white.opacity(0.55)

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}

private struct BigValue: View {
    let text: String
    var unit: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(text)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !unit.isEmpty {
                Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A thin bar showing how full something is.
private struct Meter: View {
    let fraction: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(tint).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}

/// A tiny line graph of recent values, scaled to its own maximum.
private struct Sparkline: View {
    let values: [Double]
    var maxValue: Double?
    var tint: Color = .white

    var body: some View {
        GeometryReader { g in
            let peak = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let count = SystemStatsService.historyLength
            let step = g.size.width / CGFloat(max(count - 1, 1))
            let offset = CGFloat(count - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: g.size.height * (1 - CGFloat(min(v / peak, 1))))
            }
            ZStack {
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: g.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(points) }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private func bytes(_ value: Double, style: ByteCountFormatter.CountStyle = .memory) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: style)
}

/// "12.3" and "MB/s" separately, so the number can animate.
private func rate(_ bytesPerSecond: Double) -> (String, String) {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = bytesPerSecond, index = 0
    while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
    return (value < 10 && index > 0 ? String(format: "%.1f", value) : String(Int(value)), units[index])
}

// MARK: - System widgets

private struct CPUWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let stats = coordinator.stats
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "CPU", symbol: "cpu")
            BigValue(text: "\(Int(stats.reading.cpu * 100))", unit: "%")
            Sparkline(values: stats.cpuHistory, maxValue: 1, tint: Theme.green)
        }
    }
}

private struct MemoryWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let r = coordinator.stats.reading
        let fraction = r.memoryTotal > 0 ? r.memoryUsed / r.memoryTotal : 0
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Memory", symbol: "memorychip")
            BigValue(text: String(format: "%.1f", r.memoryUsed / 1_073_741_824), unit: "GB")
            Spacer(minLength: 0)
            Meter(fraction: fraction, tint: fraction > 0.85 ? Theme.orange : Theme.blue)
            Text("of \(bytes(r.memoryTotal))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct StorageWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let r = coordinator.stats.reading
        let used = r.storageTotal > 0 ? 1 - r.storageFree / r.storageTotal : 0
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Storage", symbol: "internaldrive")
            BigValue(text: bytes(r.storageFree, style: .file).components(separatedBy: " ").first ?? "–",
                     unit: (bytes(r.storageFree, style: .file).components(separatedBy: " ").last ?? "") + " free")
            Spacer(minLength: 0)
            Meter(fraction: used, tint: used > 0.9 ? Theme.red : .white.opacity(0.85))
            Text("of \(bytes(r.storageTotal, style: .file))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct NetworkWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let r = coordinator.stats.reading
        let down = rate(r.downloadRate), up = rate(r.uploadRate)
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(title: "Network", symbol: "network")
            HStack(spacing: 3) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.blue)
                BigValue(text: down.0, unit: down.1)
            }
            HStack(spacing: 3) {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.orange)
                Text("\(up.0) \(up.1)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            Sparkline(values: coordinator.stats.networkHistory, tint: Theme.blue)
        }
    }
}

private struct BatteryWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator

    var body: some View {
        let battery = coordinator.battery
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: battery.isPluggedIn ? "Charging" : "Battery",
                         symbol: battery.isPluggedIn ? "bolt.fill" : "battery.75percent",
                         tint: battery.isPluggedIn ? Theme.green : .white.opacity(0.55))
            if let level = battery.level {
                BigValue(text: "\(level)", unit: "%")
                Spacer(minLength: 0)
                Meter(fraction: Double(level) / 100, tint: level <= 20 && !battery.isPluggedIn ? Theme.red : Theme.green)
                Text(remaining).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            } else {
                Text("No battery").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var remaining: String {
        let battery = coordinator.battery
        guard let minutes = battery.minutesRemaining else { return battery.isPluggedIn ? "On power" : "Estimating…" }
        let text = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return battery.isCharging ? "\(text) to full" : "\(text) left"
    }
}

// MARK: - Weather

private struct WeatherWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        switch coordinator.weather.state {
        case .ready(let w):
            let look = WeatherService.describe(w.code, isDay: w.isDay)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    WidgetHeader(title: w.place, symbol: "location.fill")
                    Text("\(Int(w.temperature.rounded()))°")
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text("H \(Int(w.high.rounded()))°  L \(Int(w.low.rounded()))°")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: look.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 30))
                    Text(look.text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
            }
        case .loading:
            VStack(alignment: .leading) {
                WidgetHeader(title: "Weather", symbol: "cloud.sun")
                Spacer()
                ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity)
                Spacer()
            }
        case .needsSetup, .failed:
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(title: "Weather", symbol: "cloud.sun")
                Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                Button("Set Location…") {
                    coordinator.collapse()
                    NSApp.activate()
                    openSettings()
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 6, padding: 4))
                .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    private var message: String {
        if case .failed(let text) = coordinator.weather.state { return text }
        return "Type a city or allow your location in Settings › Dashboard"
    }
}

// MARK: - Calendar

private struct CalendarWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator
    @State private var events: [CalendarService.Upcoming] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WidgetHeader(title: Date.now.formatted(.dateTime.weekday(.wide).day().month()), symbol: "calendar", tint: Theme.red)
            if !coordinator.settings.calendarEnabled || !coordinator.calendar.isAuthorized {
                Text("Turn on Calendar in Settings › Activities").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            } else if events.isEmpty {
                Text("Nothing else today").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(events.prefix(3)) { event in
                    HStack(spacing: 7) {
                        Capsule()
                            .fill(event.color.map { Color(cgColor: $0) } ?? Theme.blue)
                            .frame(width: 3, height: 14)
                        Text(event.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let url = event.joinURL, event.start.timeIntervalSinceNow < 15 * 60 {
                            Button("Join") { NSWorkspace.shared.open(url) }
                                .buttonStyle(IslandButtonStyle(cornerRadius: 5, padding: 3))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.blue)
                        } else {
                            Text(event.start <= .now ? "Now" : event.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
        }
        .onAppear { events = coordinator.calendar.upcomingToday() }
    }
}

// MARK: - Clipboard

private struct ClipboardWidget: View {
    @Environment(IslandCoordinator.self) private var coordinator
    @State private var copiedID: UUID?

    var body: some View {
        let clipboard = coordinator.clipboard
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                WidgetHeader(title: "Clipboard", symbol: "doc.on.clipboard")
                Spacer()
                if !clipboard.entries.isEmpty {
                    Button("Clear") { clipboard.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            if !coordinator.settings.clipboardHistory {
                Text("Turn on clipboard history in Settings › Dashboard").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            } else if clipboard.entries.isEmpty {
                Text("Copy some text and it shows up here").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(clipboard.entries) { entry in
                            Button {
                                clipboard.copy(entry)
                                copiedID = clipboard.entries.first?.id
                            } label: {
                                HStack {
                                    Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if copiedID == entry.id {
                                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(IslandButtonStyle(cornerRadius: 5, padding: 3))
                            .help("Click to copy again")
                        }
                    }
                }
            }
        }
    }
}
