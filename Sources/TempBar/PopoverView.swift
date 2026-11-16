import SwiftUI
import TempBarCore

struct PopoverView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Both pages share one frame: the menu bar panel never shrinks after showing taller content.
            ZStack(alignment: .topLeading) {
                conditions
                    .opacity(showingHistory ? 0 : 1)
                    .allowsHitTesting(!showingHistory)
                    .accessibilityHidden(showingHistory)
                if showingHistory {
                    HistoryView(model: model)
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 14) {
            inside
            Divider()
            outside
        }
    }

    // MARK: Inside

    private var inside: some View {
        ConditionsSection(title: "Inside", updatedAt: model.indoorUpdatedAt, notice: insideNotice) {
            row("Temperature", Format.degrees(model.indoorF))
            row("Humidity", Format.percent(model.indoorHumidity))
            if let climate = model.climate {
                row("Thermostat", thermostatText(climate))
            }
            row("Air quality", indoorAirQuality)
        }
    }

    private var insideNotice: String? {
        switch model.haStatus {
        case .connected: nil
        case .idle: "Home Assistant isn't set up"
        case .connecting: "Connecting to Home Assistant…"
        case .authFailed: "Home Assistant rejected the token. Update it in Settings."
        case .disconnected: "Can't reach Home Assistant. Is Tailscale connected?"
        }
    }

    private func thermostatText(_ climate: HAState) -> String {
        guard climate.isAvailable else { return "Unavailable" }
        guard climate.state != "off" else { return "Off" }
        var parts = [Format.hvacMode(climate.state)]
        if let target = climate.attributes["temperature"]?.double {
            parts.append("set \(Format.degrees(target))")
        } else if let low = climate.attributes["target_temp_low"]?.double,
                  let high = climate.attributes["target_temp_high"]?.double {
            parts.append("\(Format.degrees(low))–\(Format.degrees(high))")
        }
        if let action = climate.attributes["hvac_action"]?.string {
            parts.append(action)
        }
        return parts.joined(separator: " · ")
    }

    private var indoorAirQuality: String {
        guard !model.settings.airQualityEntity.isEmpty else { return "No sensor" }
        guard let state = model.airQuality, let value = state.numericValue else { return "--" }
        let number = "\(Int(value.rounded()))"
        if state.deviceClass == "aqi" { return "\(number) · \(Format.aqiCategory(value))" }
        return [number, state.unit].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Outside

    private var outside: some View {
        ConditionsSection(title: "Outside", updatedAt: model.outdoor?.fetchedAt, notice: outsideNotice) {
            if let weather = model.outdoor {
                row("Temperature", "\(Format.degrees(weather.temperatureF)) · feels \(Format.degrees(weather.apparentF))")
                row("Conditions", Format.conditions(code: weather.weatherCode, isDay: weather.isDay))
                row("Humidity", Format.percent(weather.humidity))
                row("Wind", "\(Int(weather.windMph.rounded())) mph \(Format.compass(weather.windDirection))")
                if let aqi = weather.usAQI {
                    row("Air quality", "\(Int(aqi.rounded())) · \(Format.aqiCategory(aqi))")
                } else {
                    row("Air quality", "--")
                }
                if let pm25 = weather.pm25 {
                    row("PM2.5", "\(Int(pm25.rounded())) µg/m³")
                }
            }
        }
    }

    private var outsideNotice: String? {
        if model.location.isDenied {
            return "Location is off. Allow TempBar in System Settings › Privacy & Security › Location Services."
        }
        if let error = model.weatherError, model.outdoor == nil { return "Weather unavailable: \(error)" }
        if model.outdoor == nil { return "Waiting for location…" }
        return nil
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Refresh") {
                model.refreshAll()
                if showingHistory { Task { await model.refreshIndoorHistory() } }
            }
            Button(showingHistory ? "Now" : "History") { showingHistory.toggle() }
            Button("Settings…") {
                openWindow(id: SettingsView.windowID)
                NSApplication.shared.activate()
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct ConditionsSection<Rows: View>: View {
    let title: String
    let updatedAt: Date?
    let notice: String?
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let updatedAt {
                    Text(updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                rows
            }
        }
    }
}
