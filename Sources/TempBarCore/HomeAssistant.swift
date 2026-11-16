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
    case result(id: Int?, success: Bool, error: String?, payload: JSONValue?)
    case entities(HAEntityUpdate)
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
            return .result(
                id: json["id"]?.double.map { Int($0) },
                success: json["success"]?.bool ?? false,
                error: json["error"]?["message"]?.string,
                payload: json["result"]
            )
        case "event":
            guard let event = json["event"] else { return .other }
            return .entities(HAEntityUpdate(json: event))
        default:
            return .other
        }
    }
}

/// A `subscribe_entities` event: full states under "a", diffs under "c", removals under "r".
/// https://developers.home-assistant.io/docs/api/websocket/#subscribe-to-entities
public struct HAEntityUpdate: Sendable, Equatable {
    public struct Diff: Sendable, Equatable {
        public var state: String?
        public var attributes: [String: JSONValue] = [:]
        public var removedAttributes: [String] = []
    }

    public var added: [String: HAState] = [:]
    public var changed: [String: Diff] = [:]
    public var removed: [String] = []

    init(json: JSONValue) {
        for (id, entity) in json["a"]?.object ?? [:] {
            added[id] = HAState(entityID: id, state: entity["s"]?.string ?? "unknown", attributes: entity["a"]?.object ?? [:])
        }
        for (id, entity) in json["c"]?.object ?? [:] {
            changed[id] = Diff(
                state: entity["+"]?["s"]?.string,
                attributes: entity["+"]?["a"]?.object ?? [:],
                removedAttributes: entity["-"]?["a"]?.array?.compactMap(\.string) ?? []
            )
        }
        removed = json["r"]?.array?.compactMap(\.string) ?? []
    }

    /// Folds this update into `cache` and returns the entities that changed. Removed ones come back unavailable.
    public func apply(to cache: inout [String: HAState]) -> [HAState] {
        var touched: [HAState] = []
        for (id, state) in added {
            cache[id] = state
            touched.append(state)
        }
        for (id, diff) in changed {
            guard let current = cache[id] else { continue }
            var attributes = current.attributes.merging(diff.attributes) { _, new in new }
            diff.removedAttributes.forEach { attributes[$0] = nil }
            let next = HAState(entityID: id, state: diff.state ?? current.state, attributes: attributes)
            cache[id] = next
            touched.append(next)
        }
        for id in removed {
            cache[id] = nil
            touched.append(HAState(entityID: id, state: "unavailable"))
        }
        return touched
    }
}

public enum HAError: LocalizedError, Equatable {
    case badURL
    case authInvalid(String)
    case requestFailed(String)
    case stale
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .badURL: "Home Assistant URL is not valid"
        case .authInvalid(let message): message
        case .requestFailed(let message): message
        case .stale: "Connection stopped responding"
        case .notConnected: "Not connected to Home Assistant"
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
    private var cache: [String: HAState] = [:]
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1
    private var awaitingPong = false
    private var didAuthenticate = false
    private var isReady = false
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    public init() {}

    /// Streams only `entityIDs`; Home Assistant filters server-side.
    public func start(baseURL: URL, token: String, entityIDs: [String]) {
        stop()
        loop = Task { [weak self] in await self?.run(baseURL: baseURL, token: token, entityIDs: entityIDs) }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failPending()
        onStatus(.idle)
    }

    /// Sends a one-off command (without its `id`) on the live socket and returns its `result`.
    public func request(_ message: [String: Any]) async throws -> JSONValue {
        guard isReady, let ws = socket else { throw HAError.notConnected }
        let id = takeID()
        var message = message
        message["id"] = id
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            ws.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
    }

    private func failPending() {
        isReady = false
        pending.values.forEach { $0.resume(throwing: HAError.notConnected) }
        pending = [:]
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

    private func run(baseURL: URL, token: String, entityIDs: [String]) async {
        guard let url = Self.websocketURL(for: baseURL) else {
            onStatus(.disconnected(HAError.badURL.localizedDescription))
            return
        }
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            onStatus(.connecting)
            do {
                try await session(url: url, token: token, entityIDs: entityIDs)
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

    private func session(url: URL, token: String, entityIDs: [String]) async throws {
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        awaitingPong = false
        cache = [:]
        ws.resume()

        var pinger: Task<Void, Error>?
        defer {
            pinger?.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            // A restart may already have replaced this session; its requests aren't ours to fail.
            if socket === ws { failPending() }
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
                isReady = true
                onStatus(.connected)
                // The first event carries each entity's full state; later ones only what changed.
                if !entityIDs.isEmpty {
                    try await send(["id": takeID(), "type": "subscribe_entities", "entity_ids": entityIDs], on: ws)
                }
                pinger = Task { try await keepAlive(ws) }
            case .authInvalid(let message):
                throw HAError.authInvalid(message)
            case .result(let id, let success, let error, let payload):
                let failure = HAError.requestFailed(error ?? "Request failed")
                if let id, let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(with: success ? .success(payload ?? .null) : .failure(failure))
                } else if !success {
                    throw failure
                }
            case .entities(let update):
                update.apply(to: &cache).forEach(onState)
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
