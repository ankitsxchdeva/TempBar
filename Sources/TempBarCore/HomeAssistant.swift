import Foundation

public struct HAState: Sendable, Equatable {
    public let entityID: String
    public let state: String
    public let attributes: [String: JSONValue]

    public init(entityID: String, state: String, attributes: [String: JSONValue] = [:]) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
    }

    init?(json: JSONValue) {
        guard let entityID = json["entity_id"]?.string, let state = json["state"]?.string else { return nil }
        self.init(entityID: entityID, state: state, attributes: json["attributes"]?.object ?? [:])
    }

    public var isAvailable: Bool { state != "unavailable" && state != "unknown" }
    public var numericValue: Double? { isAvailable ? Double(state) : nil }
    public var unit: String? { attributes["unit_of_measurement"]?.string }
    public var deviceClass: String? { attributes["device_class"]?.string }
}

/// One message received over the Home Assistant WebSocket API.
public enum HAIncoming: Sendable, Equatable {
    case authRequired
    case authOK
    case authInvalid(String)
    case states([HAState])
    case result(success: Bool, error: String?)
    case stateChanged(HAState)
    case pong
    case other

    public static func parse(_ data: Data) throws -> HAIncoming {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        switch json["type"]?.string {
        case "auth_required":
            return .authRequired
        case "auth_ok":
            return .authOK
        case "auth_invalid":
            return .authInvalid(json["message"]?.string ?? "Invalid access token")
        case "pong":
            return .pong
        case "result":
            if let items = json["result"]?.array {
                return .states(items.compactMap(HAState.init(json:)))
            }
            return .result(success: json["success"]?.bool ?? false, error: json["error"]?["message"]?.string)
        case "event":
            // new_state is null when an entity is removed.
            guard let newState = json["event"]?["data"]?["new_state"], let state = HAState(json: newState) else {
                return .other
            }
            return .stateChanged(state)
        default:
            return .other
        }
    }
}

public enum HAError: LocalizedError, Equatable {
    case badURL
    case authInvalid(String)
    case requestFailed(String)
    case stale

    public var errorDescription: String? {
        switch self {
        case .badURL: "Home Assistant URL is not valid"
        case .authInvalid(let message): message
        case .requestFailed(let message): message
        case .stale: "Connection stopped responding"
        }
    }
}

/// Keeps a live WebSocket to Home Assistant: fetches all states once, then streams every change.
/// Reconnects with backoff until stopped or the token is rejected.
@MainActor
public final class HomeAssistantClient {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case authFailed(String)
        case disconnected(String)
    }

    public var onStatus: (Status) -> Void = { _ in }
    public var onState: (HAState) -> Void = { _ in }

    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1
    private var awaitingPong = false
    private var didAuthenticate = false

    public init() {}

    public func start(baseURL: URL, token: String) {
        stop()
        loop = Task { [weak self] in await self?.run(baseURL: baseURL, token: token) }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onStatus(.idle)
    }

    public nonisolated static func websocketURL(for base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/websocket"
        return components.url
    }

    private func run(baseURL: URL, token: String) async {
        guard let url = Self.websocketURL(for: baseURL) else {
            onStatus(.disconnected(HAError.badURL.localizedDescription))
            return
        }
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            onStatus(.connecting)
            do {
                try await session(url: url, token: token)
            } catch HAError.authInvalid(let message) {
                onStatus(.authFailed(message))
                return
            } catch {
                if Task.isCancelled { return }
                onStatus(.disconnected(error.localizedDescription))
            }
            if didAuthenticate {
                delay = .seconds(1)
                didAuthenticate = false
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
    }

    private func session(url: URL, token: String) async throws {
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        awaitingPong = false
        ws.resume()

        var pinger: Task<Void, Error>?
        defer {
            pinger?.cancel()
            ws.cancel(with: .goingAway, reason: nil)
        }

        while true {
            let data: Data
            switch try await ws.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }

            switch try HAIncoming.parse(data) {
            case .authRequired:
                try await send(["type": "auth", "access_token": token], on: ws)
            case .authOK:
                didAuthenticate = true
                onStatus(.connected)
                // Subscribe before the snapshot so no change slips between the two.
                try await send(["id": takeID(), "type": "subscribe_events", "event_type": "state_changed"], on: ws)
                try await send(["id": takeID(), "type": "get_states"], on: ws)
                pinger = Task { try await keepAlive(ws) }
            case .authInvalid(let message):
                throw HAError.authInvalid(message)
            case .states(let states):
                states.forEach(onState)
            case .result(let success, let error):
                if !success { throw HAError.requestFailed(error ?? "Request failed") }
            case .stateChanged(let state):
                onState(state)
            case .pong:
                awaitingPong = false
            case .other:
                break
            }
        }
    }

    /// Sleep, wake and network changes can leave a socket silently dead; a missed pong forces a reconnect.
    private func keepAlive(_ ws: URLSessionWebSocketTask) async throws {
        while true {
            try await Task.sleep(for: .seconds(30))
            if awaitingPong {
                ws.cancel(with: .abnormalClosure, reason: nil)
                return
            }
            awaitingPong = true
            try await send(["id": takeID(), "type": "ping"], on: ws)
        }
    }

    private func send(_ message: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
