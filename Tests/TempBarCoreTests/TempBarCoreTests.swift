import Foundation
import Testing
@testable import TempBarCore

@Suite struct HomeAssistantProtocolTests {
    private func parse(_ json: String) throws -> HAIncoming { try HAIncoming.parse(Data(json.utf8)) }

    @Test func websocketURL() {
        #expect(HomeAssistantClient.websocketURL(for: URL(string: "https://ha.example.com")!)?.absoluteString == "wss://ha.example.com/api/websocket")
        #expect(HomeAssistantClient.websocketURL(for: URL(string: "http://homeassistant.local:8123/")!)?.absoluteString == "ws://homeassistant.local:8123/api/websocket")
        #expect(HomeAssistantClient.websocketURL(for: URL(string: "ftp://nope")!) == nil)
    }

    @Test func authMessages() throws {
        #expect(try parse(#"{"type":"auth_required","ha_version":"2026.11.0"}"#) == .authRequired)
        #expect(try parse(#"{"type":"auth_ok"}"#) == .authOK)
        #expect(try parse(#"{"type":"auth_invalid","message":"Invalid access"}"#) == .authInvalid("Invalid access"))
    }

    @Test func getStatesResult() throws {
        let message = try parse(#"""
        {"id":2,"type":"result","success":true,"result":[
          {"entity_id":"sensor.t","state":"21.5","attributes":{"unit_of_measurement":"°C","device_class":"temperature"}},
          {"entity_id":"climate.c","state":"heat","attributes":{"temperature":70,"hvac_action":"heating"}}
        ]}
        """#)
        guard case .states(let states) = message else { Issue.record("expected states, got \(message)"); return }
        #expect(states.count == 2)
        #expect(states[0].numericValue == 21.5)
        #expect(states[0].unit == "°C")
        #expect(states[1].attributes["temperature"]?.double == 70)
    }

    @Test func subscribeResult() throws {
        #expect(try parse(#"{"id":1,"type":"result","success":true,"result":null}"#) == .result(success: true, error: nil))
        #expect(try parse(#"{"id":1,"type":"result","success":false,"error":{"code":"x","message":"nope"}}"#) == .result(success: false, error: "nope"))
    }

    @Test func stateChangedEvent() throws {
        let message = try parse(#"""
        {"id":1,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"sensor.t",
          "old_state":{"entity_id":"sensor.t","state":"70","attributes":{}},
          "new_state":{"entity_id":"sensor.t","state":"71","attributes":{}}}}}
        """#)
        #expect(message == .stateChanged(HAState(entityID: "sensor.t", state: "71")))
    }

    @Test func removedEntityIsIgnored() throws {
        #expect(try parse(#"{"id":1,"type":"event","event":{"data":{"entity_id":"sensor.t","new_state":null}}}"#) == .other)
    }

    @Test func unavailableStateHasNoValue() {
        #expect(HAState(entityID: "sensor.t", state: "unavailable").numericValue == nil)
    }
}

@Suite struct FormatTests {
    @Test func menuTitle() {
        #expect(Format.menuTitle(indoorF: 70.6, outdoorF: 58.2) == "71°/58°")
        #expect(Format.menuTitle(indoorF: nil, outdoorF: -3.6) == "--/-4°")
        #expect(Format.menuTitle(indoorF: -0.3, outdoorF: nil) == "0°/--")
    }

    @Test func fahrenheit() {
        #expect(Format.fahrenheit(20, unit: "°C") == 68)
        #expect(Format.fahrenheit(68, unit: "°F") == 68)
        #expect(Format.fahrenheit(68, unit: nil) == 68)
    }

    @Test func aqiBands() {
        #expect(Format.aqiCategory(0) == "Good")
        #expect(Format.aqiCategory(50) == "Good")
        #expect(Format.aqiCategory(51) == "Moderate")
        #expect(Format.aqiCategory(150) == "Unhealthy for sensitive groups")
        #expect(Format.aqiCategory(301) == "Hazardous")
    }

    @Test func compass() {
        #expect(Format.compass(0) == "N")
        #expect(Format.compass(350) == "N")
        #expect(Format.compass(90) == "E")
        #expect(Format.compass(225) == "SW")
        #expect(Format.compass(-45) == "NW")
    }

    @Test func labels() {
        #expect(Format.conditions(code: 0, isDay: false) == "Clear")
        #expect(Format.conditions(code: 63, isDay: true) == "Rain")
        #expect(Format.hvacMode("heat_cool") == "Heat/Cool")
    }
}

@Suite struct OpenMeteoTests {
    @Test func decodesBothResponses() throws {
        let forecast = #"""
        {"current":{"time":"2026-11-15T10:00","interval":900,"temperature_2m":58.2,"apparent_temperature":55.1,
          "relative_humidity_2m":61,"weather_code":2,"wind_speed_10m":8.4,"wind_direction_10m":315,"is_day":1}}
        """#
        let air = #"{"current":{"time":"2026-11-15T10:00","us_aqi":42,"pm2_5":6.3}}"#
        let result = try OpenMeteo.decode(forecast: Data(forecast.utf8), airQuality: Data(air.utf8))
        #expect(result.temperatureF == 58.2)
        #expect(result.weatherCode == 2)
        #expect(result.isDay)
        #expect(result.usAQI == 42)
        #expect(result.pm25 == 6.3)
    }

    @Test func missingAirQualityStillDecodes() throws {
        let forecast = #"""
        {"current":{"temperature_2m":30,"apparent_temperature":25,"relative_humidity_2m":80,
          "weather_code":71,"wind_speed_10m":12,"wind_direction_10m":10,"is_day":0}}
        """#
        let result = try OpenMeteo.decode(forecast: Data(forecast.utf8), airQuality: Data("garbage".utf8))
        #expect(result.temperatureF == 30)
        #expect(result.usAQI == nil)
    }
}

/// Hits real services. Run with: TEMPBAR_LIVE=https://your-ha-host swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TEMPBAR_LIVE"] != nil))
struct LiveTests {
    @Test func openMeteoReturnsCurrentConditions() async throws {
        let result = try await OpenMeteo.fetch(latitude: 41.88, longitude: -87.63)
        #expect((-60...130).contains(result.temperatureF))
        #expect(result.usAQI != nil)
    }

    /// Full handshake against a real server: connect, receive auth_required, get rejected for a bogus token.
    @MainActor @Test func homeAssistantRejectsBogusToken() async throws {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["TEMPBAR_LIVE"]!))
        let client = HomeAssistantClient()
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<HomeAssistantClient.Status, Never>) in
            var resumed = false
            client.onStatus = { status in
                if case .authFailed = status, !resumed { resumed = true; continuation.resume(returning: status) }
            }
            client.start(baseURL: url, token: "not-a-real-token")
        }
        client.onStatus = { _ in }
        client.stop()
        guard case .authFailed = status else { Issue.record("expected authFailed, got \(status)"); return }
    }
}
