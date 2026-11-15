import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings = Settings()
    @State private var token = ""
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Home Assistant URL", text: $settings.haURL, prompt: "https://homeassistant.local:8123")
            VStack(alignment: .leading, spacing: 2) {
                Text("Long-lived access token").font(.caption).foregroundStyle(.secondary)
                SecureField(model.hasToken ? "Saved. Paste a new one to replace it." : "Profile › Security in Home Assistant", text: $token)
            }

            Text("Entity IDs").font(.caption.bold()).padding(.top, 4)
            field("Indoor temperature", text: $settings.temperatureEntity, prompt: "sensor.living_room_temperature")
            field("Indoor humidity", text: $settings.humidityEntity, prompt: "sensor.living_room_humidity")
            field("Thermostat", text: $settings.climateEntity, prompt: "climate.thermostat")
            field("Indoor air quality (optional)", text: $settings.airQualityEntity, prompt: "sensor.air_quality_index")

            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in model.launchesAtLogin = newValue }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.update(settings: trimmed(settings), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 340)
        .onAppear {
            settings = model.settings
            launchAtLogin = model.launchesAtLogin
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden()
        }
    }

    private func trimmed(_ settings: Settings) -> Settings {
        var result = settings
        for keyPath in [\Settings.haURL, \.temperatureEntity, \.humidityEntity, \.climateEntity, \.airQualityEntity] {
            result[keyPath: keyPath] = result[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
