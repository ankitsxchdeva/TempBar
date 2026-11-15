import Foundation

public struct OutdoorConditions: Sendable, Equatable {
    public var temperatureF: Double
    public var apparentF: Double
    public var humidity: Double
    public var weatherCode: Int
    public var isDay: Bool
    public var windMph: Double
    public var windDirection: Double
    public var usAQI: Double?
    public var pm25: Double?
    public var fetchedAt: Date
}

/// Free weather + air quality API, no key needed: https://open-meteo.com
public enum OpenMeteo {
    struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let relativeHumidity2m: Double
            let weatherCode: Int
            let windSpeed10m: Double
            let windDirection10m: Double
            let isDay: Int

            // Spelled out: .convertFromSnakeCase would expect "temperature2M".
            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case relativeHumidity2m = "relative_humidity_2m"
                case weatherCode = "weather_code"
                case windSpeed10m = "wind_speed_10m"
                case windDirection10m = "wind_direction_10m"
                case isDay = "is_day"
            }
        }
        let current: Current
    }

    struct AirQualityResponse: Decodable {
        struct Current: Decodable {
            let usAqi: Double?
            let pm25: Double?

            enum CodingKeys: String, CodingKey {
                case usAqi = "us_aqi"
                case pm25 = "pm2_5"
            }
        }
        let current: Current
    }

    public static func forecastURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
        ]
        return components.url!
    }

    public static func airQualityURL(latitude: Double, longitude: Double) -> URL {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "us_aqi,pm2_5"),
        ]
        return components.url!
    }

    public static func decode(forecast: Data, airQuality: Data?, fetchedAt: Date = Date()) throws -> OutdoorConditions {
        let decoder = JSONDecoder()
        let current = try decoder.decode(ForecastResponse.self, from: forecast).current
        // Air quality is a bonus; temperature still shows if that request fails.
        let air = airQuality.flatMap { try? decoder.decode(AirQualityResponse.self, from: $0).current }
        return OutdoorConditions(
            temperatureF: current.temperature2m,
            apparentF: current.apparentTemperature,
            humidity: current.relativeHumidity2m,
            weatherCode: current.weatherCode,
            isDay: current.isDay == 1,
            windMph: current.windSpeed10m,
            windDirection: current.windDirection10m,
            usAQI: air?.usAqi,
            pm25: air?.pm25,
            fetchedAt: fetchedAt
        )
    }

    public static func fetch(latitude: Double, longitude: Double, session: URLSession = .shared) async throws -> OutdoorConditions {
        async let forecast = session.data(from: forecastURL(latitude: latitude, longitude: longitude))
        async let airQuality = session.data(from: airQualityURL(latitude: latitude, longitude: longitude))
        let forecastData = try await forecast.0
        let airData = try? await airQuality.0
        return try decode(forecast: forecastData, airQuality: airData)
    }
}
