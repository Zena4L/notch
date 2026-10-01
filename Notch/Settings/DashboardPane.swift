import SwiftUI

/// Settings › Dashboard: which widgets, in what order, and their options.
struct DashboardPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(isOn: $settings.dashboardEnabled) {
                    Text("Dashboard")
                    Text("Widgets in the island · ⌥⌘I")
                }
                Toggle(isOn: $settings.dashboardOnIdle) {
                    Text("Open it when nothing else is going on")
                    Text("Clicking or hovering the empty island shows the dashboard")
                }
                .disabled(!settings.dashboardEnabled)
                Picker("Rows", selection: $settings.dashboardMaxRows) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.dashboardEnabled)
            }

            Section {
                ForEach(DashboardWidget.allCases, id: \.self) { widget in
                    WidgetRow(widget: widget)
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Each row has four slots; wide widgets take two. Widgets that don't fit in your rows are left out.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!settings.dashboardEnabled)

            Section("System") {
                Picker(selection: $settings.statsInterval) {
                    Text("Every second").tag(1)
                    Text("Every 2 seconds").tag(2)
                    Text("Every 5 seconds").tag(5)
                } label: {
                    Text("Update CPU, memory and network")
                    Text("Only while the dashboard is open")
                }
            }

            Section {
                Toggle("Use my location", isOn: $settings.weatherUsesLocation)
                if !settings.weatherUsesLocation {
                    LabeledContent("City") {
                        TextField("City", text: $settings.weatherCity, prompt: Text("e.g. Accra"))
                            .labelsHidden()
                            .frame(width: 200)
                    }
                }
                Picker("Temperature", selection: $settings.temperatureUnit) {
                    Text("Automatic").tag(TemperatureUnit.automatic)
                    Text("°C").tag(TemperatureUnit.celsius)
                    Text("°F").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Weather")
            } footer: {
                Text("From Open-Meteo. Your location is rounded to about 1 km before it's sent, and only used when the dashboard opens.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.clipboardHistory) {
                    Text("Keep clipboard history")
                    Text("Recent copied text, in memory only — gone when Notch quits")
                }
                if settings.clipboardHistory {
                    Picker("Remember", selection: $settings.clipboardLimit) {
                        Text("10 items").tag(10)
                        Text("20 items").tag(20)
                        Text("50 items").tag(50)
                    }
                    Toggle("Skip passwords from password managers", isOn: $settings.clipboardIgnoreConcealed)
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Text("macOS may ask whether Notch can read what other apps copy; choose Allow.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dashboard")
    }
}

/// One widget: on/off, and ↑/↓ to move it among the ones that are on.
private struct WidgetRow: View {
    let widget: DashboardWidget
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let enabled = settings.dashboardWidgets
        let index = enabled.firstIndex(of: widget)
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(Theme.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(widget.width == 2 ? "Wide" : "Small").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let index {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == enabled.count - 1)
            }
            Toggle("", isOn: Binding(
                get: { index != nil },
                set: { on in
                    if on, index == nil { settings.dashboardWidgets.append(widget) }
                    if !on { settings.dashboardWidgets.removeAll { $0 == widget } }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .buttonStyle(.borderless)
    }

    private func move(_ index: Int, by offset: Int) {
        var list = settings.dashboardWidgets
        guard list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        settings.dashboardWidgets = list
    }

    private var title: String {
        switch widget {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        case .battery: "Battery"
        case .weather: "Weather"
        case .calendar: "Today's events"
        case .clipboard: "Clipboard history"
        }
    }

    private var symbol: String {
        switch widget {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .network: "network"
        case .battery: "battery.75percent"
        case .weather: "cloud.sun"
        case .calendar: "calendar"
        case .clipboard: "doc.on.clipboard"
        }
    }
}
