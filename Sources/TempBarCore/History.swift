import Foundation

public struct TemperatureSample: Sendable, Equatable {
    public var date: Date
    public var fahrenheit: Double

    public init(date: Date, fahrenheit: Double) {
        self.date = date
        self.fahrenheit = fahrenheit
    }
}

extension [TemperatureSample] {
    /// The temperature at `date`, read off the line drawn through the samples (sorted by date).
    public func value(at date: Date) -> Double? {
        guard let first, let last else { return nil }
        if date <= first.date { return first.fahrenheit }
        guard let next = self.first(where: { $0.date >= date }) else { return last.fahrenheit }
        guard let previous = self.last(where: { $0.date < date }) else { return next.fahrenheit }
        let span = next.date.timeIntervalSince(previous.date)
        guard span > 0 else { return next.fahrenheit }
        let fraction = date.timeIntervalSince(previous.date) / span
        return previous.fahrenheit + (next.fahrenheit - previous.fahrenheit) * fraction
    }

    /// Drops samples before `start`, keeping the line's value there so it still begins at the edge.
    public func starting(at start: Date) -> [TemperatureSample] {
        guard let first, first.date < start else { return self }
        let kept = filter { $0.date > start }
        guard let edge = value(at: start) else { return kept }
        return [TemperatureSample(date: start, fahrenheit: edge)] + kept
    }
}

/// Recorded states from Home Assistant's recorder.
/// https://developers.home-assistant.io/docs/api/websocket/ (`history/history_during_period`)
public enum HAHistory {
    /// The request body, minus the message id. Attributes are kept so each row carries its own unit.
    public static func request(entityID: String, start: Date) -> [String: Any] {
        [
            "type": "history/history_during_period",
            "start_time": ISO8601DateFormatter().string(from: start),
            "entity_ids": [entityID],
        ]
    }

    /// Reads the response: `{entity_id: [{"s": state, "a": attributes, "lu": unix seconds}, ...]}`.
    /// With `attribute`, the reading comes from that attribute instead of the state (a thermostat's
    /// `current_temperature`), which is already in the instance's unit, like the live value.
    public static func samples(from result: JSONValue, entityID: String, attribute: String? = nil) -> [TemperatureSample] {
        var unit: String?
        var samples: [TemperatureSample] = []
        for row in result[entityID]?.array ?? [] {
            unit = row["a"]?["unit_of_measurement"]?.string ?? unit
            let reading = if let attribute { row["a"]?[attribute]?.double } else { row["s"]?.double }
            guard let reading, reading.isFinite, let time = (row["lu"] ?? row["lc"])?.double else { continue }
            let fahrenheit = attribute == nil ? Format.fahrenheit(reading, unit: unit) : reading
            samples.append(TemperatureSample(date: Date(timeIntervalSince1970: time), fahrenheit: fahrenheit))
        }
        return samples.sorted { $0.date < $1.date }
    }
}
