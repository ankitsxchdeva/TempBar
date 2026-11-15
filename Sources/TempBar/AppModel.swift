import AppKit
import ServiceManagement
import TempBarCore

struct Settings: Equatable {
    var haURL = ""
    var temperatureEntity = ""
    var humidityEntity = ""
    var climateEntity = ""
    var airQualityEntity = ""

    private static let keys = (
        haURL: "haURL", temperature: "temperatureEntity", humidity: "humidityEntity",
        climate: "climateEntity", airQuality: "airQualityEntity"
    )

    static func load(_ defaults: UserDefaults = .standard) -> Settings {
        Settings(
            haURL: defaults.string(forKey: keys.haURL) ?? "",
            temperatureEntity: defaults.string(forKey: keys.temperature) ?? "",
            humidityEntity: defaults.string(forKey: keys.humidity) ?? "",
            climateEntity: defaults.string(forKey: keys.climate) ?? "",
            airQualityEntity: defaults.string(forKey: keys.airQuality) ?? ""
        )
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(haURL, forKey: Self.keys.haURL)
        defaults.set(temperatureEntity, forKey: Self.keys.temperature)
        defaults.set(humidityEntity, forKey: Self.keys.humidity)
        defaults.set(climateEntity, forKey: Self.keys.climate)
        defaults.set(airQualityEntity, forKey: Self.keys.airQuality)
    }
}

@MainActor
@Observable
final class AppModel {
    private static let keychainService = "com.ankitsachdeva.tempbar"
    private static let keychainAccount = "home-assistant-token"
    private static let weatherInterval: Duration = .seconds(600)

    private(set) var settings = Settings.load()
    private(set) var haStatus: HomeAssistantClient.Status = .idle
    private(set) var indoorUpdatedAt: Date?
    private(set) var outdoor: OutdoorConditions?
    private(set) var weatherError: String?

    private(set) var temperature: HAState?
    private(set) var humidity: HAState?
    private(set) var climate: HAState?
    private(set) var airQuality: HAState?

    let location = LocationProvider()
    private let homeAssistant = HomeAssistantClient()
    private var weatherLoop: Task<Void, Never>?
    private var isFetchingWeather = false

    var hasToken: Bool { Keychain.read(service: Self.keychainService, account: Self.keychainAccount) != nil }

    init() {
        homeAssistant.onStatus = { [weak self] in self?.haStatus = $0 }
        homeAssistant.onState = { [weak self] in self?.apply($0) }
        location.onChange = { [weak self] _ in Task { await self?.refreshWeather() } }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }

        connectHomeAssistant()
        location.start()
        weatherLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.weatherInterval)
                await self?.refreshWeather()
            }
        }
    }

    // MARK: Derived values

    var indoorF: Double? {
        if let temperature, let value = temperature.numericValue {
            return Format.fahrenheit(value, unit: temperature.unit)
        }
        // Fall back to the thermostat's own reading; climate entities use the instance's unit.
        return climate?.attributes["current_temperature"]?.double
    }

    var indoorHumidity: Double? {
        humidity?.numericValue ?? climate?.attributes["current_humidity"]?.double
    }

    var menuTitle: String { Format.menuTitle(indoorF: indoorF, outdoorF: outdoor?.temperatureF) }

    var isConfigured: Bool { URL(string: settings.haURL)?.scheme != nil && hasToken }

    // MARK: Actions

    func refreshAll() {
        if haStatus != .connected { connectHomeAssistant() }
        Task { await refreshWeather() }
    }

    func update(settings newSettings: Settings, token: String?) {
        if let token, !token.isEmpty {
            try? Keychain.save(token, service: Self.keychainService, account: Self.keychainAccount)
        }
        newSettings.save()
        settings = newSettings
        connectHomeAssistant()
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    // MARK: Private

    private func connectHomeAssistant() {
        temperature = nil
        humidity = nil
        climate = nil
        airQuality = nil
        indoorUpdatedAt = nil
        guard let url = URL(string: settings.haURL), url.scheme != nil,
              let token = Keychain.read(service: Self.keychainService, account: Self.keychainAccount)
        else {
            homeAssistant.stop()
            return
        }
        homeAssistant.start(baseURL: url, token: token)
    }

    private func apply(_ state: HAState) {
        switch state.entityID {
        case settings.temperatureEntity: temperature = state
        case settings.humidityEntity: humidity = state
        case settings.climateEntity: climate = state
        case settings.airQualityEntity: airQuality = state
        default: return
        }
        indoorUpdatedAt = Date()
    }

    private func refreshWeather() async {
        guard let coordinate = location.coordinate, !isFetchingWeather else { return }
        isFetchingWeather = true
        defer { isFetchingWeather = false }
        do {
            outdoor = try await OpenMeteo.fetch(latitude: coordinate.latitude, longitude: coordinate.longitude)
            weatherError = nil
        } catch {
            weatherError = error.localizedDescription
        }
    }
}
