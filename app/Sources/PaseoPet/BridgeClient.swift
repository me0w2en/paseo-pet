import Foundation

struct PetPermission: Codable, Hashable {
    let requestId: String
    let kind: String
    let title: String
    let detail: String?
}

struct PetAgent: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let provider: String
    let cwd: String
    let workspaceId: String?
    let parentAgentId: String?
    let status: String
    let updatedAt: String
    let pending: [PetPermission]
}

struct PetNotice: Decodable {
    let type: String
    let agent: PetAgent?
    let summary: String?
    let message: String?
    let permission: PetPermission?
}

struct BridgeConnection: Decodable {
    let url: String
    let token: String
    let serverId: String?
}

private struct Snapshot: Decodable {
    let agents: [PetAgent]
}

enum BridgeError: LocalizedError {
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, body): return "브리지 응답 \(code): \(body)"
        }
    }
}

/// Streams agent state from the pet-bridge Paseo plugin over server-sent events.
@MainActor
final class BridgeClient {
    var onSnapshot: (([PetAgent]) -> Void)?
    var onNotice: ((PetNotice) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var connection: BridgeConnection?

    private var loop: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // The bridge pings every 15 seconds; a silent minute means the daemon or plugin went away.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        return URLSession(configuration: config)
    }()

    static var connectionFile: URL {
        let home = ProcessInfo.processInfo.environment["PASEO_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo")
        return home.appendingPathComponent("pet-bridge/connection.json")
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                // Re-read every attempt: the token changes whenever the plugin restarts.
                let data = try Data(contentsOf: Self.connectionFile)
                let info = try JSONDecoder().decode(BridgeConnection.self, from: data)
                connection = info
                try await stream(info)
                backoff = 1
            } catch {
                if Task.isCancelled { return }
            }
            onConnectionChange?(false)
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 15)
        }
    }

    private func stream(_ info: BridgeConnection) async throws {
        var request = URLRequest(url: URL(string: "\(info.url)/v1/events")!)
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BridgeError.badStatus(status, "") }
        onConnectionChange?(true)

        // AsyncLineSequence drops blank lines, so dispatch on each data line using the last event name.
        var event = "message"
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                dispatch(event: event, payload: payload)
                event = "message"
            }
        }
    }

    private func dispatch(event: String, payload: Data) {
        let decoder = JSONDecoder()
        switch event {
        case "snapshot":
            if let snapshot = try? decoder.decode(Snapshot.self, from: payload) {
                onSnapshot?(snapshot.agents)
            }
        case "notice":
            if let notice = try? decoder.decode(PetNotice.self, from: payload) {
                onNotice?(notice)
            }
        default:
            break
        }
    }

    func respond(agentId: String, requestId: String, allow: Bool) async throws {
        let agent = agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentId
        let req = requestId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestId
        try await post(path: "/v1/agents/\(agent)/permissions/\(req)", body: ["behavior": allow ? "allow" : "deny"])
    }

    func sendTest() async throws {
        try await post(path: "/v1/test", body: [:])
    }

    private func post(path: String, body: [String: String]) async throws {
        guard let info = connection else { throw BridgeError.badStatus(0, "브리지에 연결되지 않았습니다") }
        var request = URLRequest(url: URL(string: "\(info.url)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw BridgeError.badStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
