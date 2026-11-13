import Foundation
import Security

// MARK: JSON

/// Any JSON value: event content in Matrix is free-form.
enum JSON: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSON])
    case array([JSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let v) = self { return v }; return nil }
    var double: Double? { if case .number(let v) = self { return v }; return nil }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var object: [String: JSON]? { if case .object(let v) = self { return v }; return nil }
    var array: [JSON]? { if case .array(let v) = self { return v }; return nil }

    /// Builds JSON from plain Swift values (String, numbers, Bool, arrays, dictionaries).
    static func from(_ any: Any?) -> JSON {
        switch any {
        case let v as JSON: return v
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as [String: Any]: return .object(v.mapValues { JSON.from($0) })
        case let v as [Any]: return .array(v.map { JSON.from($0) })
        default: return .null
        }
    }
}

// MARK: Wire models

struct MatrixEvent: Decodable, Hashable {
    var event_id: String?
    var type: String
    var sender: String?
    var origin_server_ts: Double?
    var state_key: String?
    var content: JSON
    var unsigned: JSON?
    var redacts: String?

    var isState: Bool { state_key != nil }
    var date: Date { Date(timeIntervalSince1970: (origin_server_ts ?? 0) / 1000) }
}

struct EventList: Decodable { var events: [MatrixEvent]? }

struct SyncResponse: Decodable {
    struct Rooms: Decodable {
        var join: [String: JoinedRoom]?
        var invite: [String: InvitedRoom]?
        var leave: [String: JoinedRoom]?
    }
    struct Timeline: Decodable {
        var events: [MatrixEvent]?
        var limited: Bool?
        var prev_batch: String?
    }
    struct Unread: Decodable {
        var notification_count: Int?
        var highlight_count: Int?
    }
    struct Summary: Decodable {
        var heroes: [String]?
        var joined: Int?
        enum CodingKeys: String, CodingKey {
            case heroes = "m.heroes"
            case joined = "m.joined_member_count"
        }
    }
    struct JoinedRoom: Decodable {
        var state: EventList?
        var timeline: Timeline?
        var ephemeral: EventList?
        var account_data: EventList?
        var unread_notifications: Unread?
        var summary: Summary?
    }
    struct InvitedRoom: Decodable {
        var invite_state: EventList?
    }

    var next_batch: String
    var rooms: Rooms?
    var account_data: EventList?
}

struct MessagesResponse: Decodable {
    var chunk: [MatrixEvent]?
    var state: [MatrixEvent]?
    var end: String?
}

enum MatrixError: LocalizedError {
    case notSignedIn
    case unreachable(String)
    case server(code: String, message: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .unreachable(let base): return "Couldn't reach the Matrix server at \(base). Is Tailscale on and the server running?"
        case .server(let code, let message, _):
            if code == "M_FORBIDDEN", message.lowercased().contains("password") { return "Wrong username or password." }
            if code == "M_UNKNOWN_TOKEN" { return "You've been signed out. Sign in again." }
            return message.isEmpty ? code : message
        }
    }

    var isAuthFailure: Bool {
        if case .server(let code, _, _) = self { return code == "M_UNKNOWN_TOKEN" }
        return false
    }
}

// MARK: Client

struct MatrixSession: Codable, Equatable {
    var homeserver: String
    var userID: String
    var accessToken: String
    var deviceID: String?
}

/// Thin wrapper around the Matrix client-server API.
struct MatrixAPI {
    let base: URL
    var token: String?

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    static func normalize(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        return URL(string: value)
    }

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? component
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil, timeout: TimeInterval = 60) async throws -> Data {
        var components = URLComponents(string: base.absoluteString + path)!
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }.joined(separator: "&")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let data = body as? Data {
                request.httpBody = data
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        let result: (Data, URLResponse)
        do {
            result = try await Self.session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw MatrixError.unreachable(base.absoluteString)
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
            throw MatrixError.server(code: json?["errcode"] as? String ?? "HTTP \(status)", message: json?["error"] as? String ?? "", status: status)
        }
        return result.0
    }

    func json(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
        let data = try await request(method, path, query: query, body: body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Endpoints

    func login(user: String, password: String, deviceName: String) async throws -> MatrixSession {
        let response = try await json("POST", "/_matrix/client/v3/login", body: [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": user],
            "password": password,
            "initial_device_display_name": deviceName
        ])
        guard let token = response["access_token"] as? String, let userID = response["user_id"] as? String else {
            throw MatrixError.server(code: "M_UNKNOWN", message: "The server didn't return a session.", status: 0)
        }
        return MatrixSession(homeserver: base.absoluteString, userID: userID, accessToken: token, deviceID: response["device_id"] as? String)
    }

    func logout() async {
        _ = try? await request("POST", "/_matrix/client/v3/logout", body: [String: Any]())
    }

    static let syncFilter = #"{"room":{"timeline":{"limit":30,"lazy_load_members":true},"state":{"lazy_load_members":true},"include_leave":false},"presence":{"types":[]}}"#

    func sync(since: String?, timeout: Int) async throws -> SyncResponse {
        var query = ["filter": Self.syncFilter, "timeout": String(timeout)]
        if let since { query["since"] = since }
        let data = try await request("GET", "/_matrix/client/v3/sync", query: query, timeout: TimeInterval(timeout / 1000 + 60))
        return try JSONDecoder().decode(SyncResponse.self, from: data)
    }

    func messages(room: String, from: String?, limit: Int = 40) async throws -> MessagesResponse {
        var query = ["dir": "b", "limit": String(limit), "filter": #"{"lazy_load_members":true}"#]
        if let from { query["from"] = from }
        let data = try await request("GET", "/_matrix/client/v3/rooms/\(Self.encode(room))/messages", query: query)
        return try JSONDecoder().decode(MessagesResponse.self, from: data)
    }

    func send(room: String, type: String, content: [String: Any], txn: String) async throws -> String {
        let response = try await json("PUT", "/_matrix/client/v3/rooms/\(Self.encode(room))/send/\(Self.encode(type))/\(Self.encode(txn))", body: content)
        return response["event_id"] as? String ?? ""
    }

    func redact(room: String, event: String, txn: String) async throws {
        _ = try await request("PUT", "/_matrix/client/v3/rooms/\(Self.encode(room))/redact/\(Self.encode(event))/\(Self.encode(txn))", body: [String: Any]())
    }

    func markRead(room: String, event: String) async throws {
        _ = try await request("POST", "/_matrix/client/v3/rooms/\(Self.encode(room))/read_markers", body: ["m.fully_read": event, "m.read": event])
    }

    func typing(room: String, user: String, typing: Bool) async throws {
        var body: [String: Any] = ["typing": typing]
        if typing { body["timeout"] = 6000 }
        _ = try await request("PUT", "/_matrix/client/v3/rooms/\(Self.encode(room))/typing/\(Self.encode(user))", body: body)
    }

    func join(room: String) async throws {
        _ = try await request("POST", "/_matrix/client/v3/join/\(Self.encode(room))", body: [String: Any]())
    }

    func leave(room: String) async throws {
        _ = try await request("POST", "/_matrix/client/v3/rooms/\(Self.encode(room))/leave", body: [String: Any]())
    }

    func createDirect(with user: String) async throws -> String {
        let response = try await json("POST", "/_matrix/client/v3/createRoom", body: [
            "is_direct": true, "invite": [user], "preset": "trusted_private_chat"
        ])
        return response["room_id"] as? String ?? ""
    }

    func setAccountData(user: String, type: String, content: [String: Any]) async throws {
        _ = try await request("PUT", "/_matrix/client/v3/user/\(Self.encode(user))/account_data/\(Self.encode(type))", body: content)
    }

    func upload(_ data: Data, filename: String, mimetype: String) async throws -> String {
        var components = URLComponents(string: base.absoluteString + "/_matrix/media/v3/upload")!
        components.queryItems = [URLQueryItem(name: "filename", value: filename)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(mimetype, forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await Self.session.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status), let uri = json?["content_uri"] as? String else {
            throw MatrixError.server(code: json?["errcode"] as? String ?? "HTTP \(status)", message: json?["error"] as? String ?? "Upload failed.", status: status)
        }
        return uri
    }

    func setPusher(_ body: [String: Any]) async throws {
        _ = try await request("POST", "/_matrix/client/v3/pushers/set", body: body)
    }

    /// Authenticated media URL for an mxc:// URI (Synapse 1.111+ requires authentication).
    func mediaURL(_ mxc: String, thumbnail size: Int? = nil) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let parts = mxc.dropFirst(6).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if let size {
            return URL(string: base.absoluteString + "/_matrix/client/v1/media/thumbnail/\(Self.encode(parts[0]))/\(Self.encode(parts[1]))?width=\(size)&height=\(size)&method=scale")
        }
        return URL(string: base.absoluteString + "/_matrix/client/v1/media/download/\(Self.encode(parts[0]))/\(Self.encode(parts[1]))")
    }
}

// MARK: Keychain

enum MatrixKeychain {
    static func save(_ value: String, service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
