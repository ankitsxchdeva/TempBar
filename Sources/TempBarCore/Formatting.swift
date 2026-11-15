import Foundation

public enum Format {
    /// HA reports in whatever unit the instance uses; everything here displays in °F.
    public static func fahrenheit(_ value: Double, unit: String?) -> Double {
        guard let unit, unit.contains("C") else { return value }
        return value * 9 / 5 + 32
    }

    public static func degrees(_ value: Double?) -> String {
        guard let value else { return "--" }
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// The menu bar text, e.g. "71°/58°".
    public static func menuTitle(indoorF: Double?, outdoorF: Double?) -> String {
        "\(degrees(indoorF))/\(degrees(outdoorF))"
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    /// EPA US AQI bands.
    public static func aqiCategory(_ aqi: Double) -> String {
        switch aqi {
        case ..<51: "Good"
        case ..<101: "Moderate"
        case ..<151: "Unhealthy for sensitive groups"
        case ..<201: "Unhealthy"
        case ..<301: "Very unhealthy"
        default: "Hazardous"
        }
    }

    public static func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalized + 22.5) / 45) % 8]
    }

    /// WMO weather interpretation codes, as returned by Open-Meteo.
    public static func conditions(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "Sunny" : "Clear"
        case 1: isDay ? "Mostly sunny" : "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81, 82: "Rain showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Unknown"
        }
    }

    /// "heat_cool" -> "Heat/Cool"
    public static func hvacMode(_ mode: String) -> String {
        mode.split(separator: "_").map { $0.capitalized }.joined(separator: "/")
    }
}
