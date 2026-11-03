import Foundation

/// A loosely typed JSON value. TrueNAS, NZBGet and the *arr apps change their response shapes between
/// versions, so the app reads fields leniently instead of failing on one missing key.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    subscript(key: String) -> JSONValue {
        if case .object(let dict) = self { return dict[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var int: Int? { double.map { Int($0) } }

    var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["true", "yes", "1"].contains(value.lowercased())
        default: return nil
        }
    }

    var array: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var object: [String: JSONValue] {
        if case .object(let dict) = self { return dict }
        return [:]
    }

    /// TrueNAS sends dates as `{"$date": milliseconds}`, plain epoch numbers, or ISO strings.
    var date: Date? {
        switch self {
        case .object:
            return self["$date"].date
        case .number(let value):
            return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
        case .string(let value):
            return DateParsing.iso(value)
        default:
            return nil
        }
    }

    /// Plain Swift value for JSONSerialization.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map(\.any)
        case .object(let dict): return dict.mapValues(\.any)
        }
    }
}

enum DateParsing {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func iso(_ text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text) ?? dayOnly.date(from: String(text.prefix(10)))
    }

    static func isoString(_ date: Date) -> String {
        plain.string(from: date)
    }
}
