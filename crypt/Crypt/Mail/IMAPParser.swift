import Foundation

/// One value in an IMAP response: an atom (including bracketed sections such as
/// `BODY[HEADER.FIELDS (FROM)]`), a quoted or literal string, a parenthesised list, or NIL.
indirect enum IMAPValue {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    var data: Data? {
        switch self {
        case .atom(let s): return Data(s.utf8)
        case .string(let d): return d
        default: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }
}

struct IMAPParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    static func parse(_ data: Data) -> [IMAPValue] {
        var parser = IMAPParser(data)
        return parser.parseSequence(until: nil)
    }

    private mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == 0x20 { index += 1 }
    }

    private mutating func parseSequence(until terminator: UInt8?) -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard index < bytes.count else { return values }
            let byte = bytes[index]
            if let terminator, byte == terminator {
                index += 1
                return values
            }
            if byte == UInt8(ascii: ")") {
                // Stray closing paren at the top level: skip it.
                index += 1
                continue
            }
            if let value = parseValue() {
                values.append(value)
            }
        }
    }

    private mutating func parseValue() -> IMAPValue? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "("):
            index += 1
            return .list(parseSequence(until: UInt8(ascii: ")")))
        case UInt8(ascii: "\""):
            return .string(parseQuoted())
        case UInt8(ascii: "{"):
            if let literal = parseLiteral() { return .string(literal) }
            return .atom(parseAtom())
        case 13, 10:
            index += 1
            return nil
        default:
            let atom = parseAtom()
            if atom.uppercased() == "NIL" { return .nilValue }
            return .atom(atom)
        }
    }

    private mutating func parseQuoted() -> Data {
        index += 1
        var out: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                out.append(bytes[index + 1])
                index += 2
                continue
            }
            index += 1
            if byte == UInt8(ascii: "\"") { break }
            out.append(byte)
        }
        return Data(out)
    }

    private mutating func parseLiteral() -> Data? {
        let start = index
        index += 1
        var digits = ""
        while index < bytes.count, (48...57).contains(bytes[index]) {
            digits.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") { index += 1 }
        guard let count = Int(digits), index < bytes.count, bytes[index] == UInt8(ascii: "}") else {
            index = start
            return nil
        }
        index += 1
        if index < bytes.count, bytes[index] == 13 { index += 1 }
        if index < bytes.count, bytes[index] == 10 { index += 1 }
        let end = min(bytes.count, index + count)
        let literal = Data(bytes[index..<end])
        index = end
        return literal
    }

    private mutating func parseAtom() -> String {
        var out: [UInt8] = []
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if depth == 0 {
                if byte == 0x20 || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == 13 || byte == 10 {
                    break
                }
                if byte == UInt8(ascii: "{"), !out.isEmpty {
                    break
                }
            }
            if byte == UInt8(ascii: "[") { depth += 1 }
            if byte == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            out.append(byte)
            index += 1
        }
        if out.isEmpty, index < bytes.count {
            // Make progress on unexpected bytes.
            out.append(bytes[index])
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Decodes IMAP's modified UTF-7 mailbox names (RFC 3501 section 5.1.3).
enum ModifiedUTF7 {
    static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        var result = ""
        var iterator = name.makeIterator()
        while let ch = iterator.next() {
            if ch != "&" {
                result.append(ch)
                continue
            }
            var encoded = ""
            while let next = iterator.next(), next != "-" {
                encoded.append(next)
            }
            if encoded.isEmpty {
                result.append("&")
                continue
            }
            var base64 = encoded.replacingOccurrences(of: ",", with: "/")
            while base64.count % 4 != 0 { base64.append("=") }
            if let data = Data(base64Encoded: base64),
               let text = String(data: data, encoding: .utf16BigEndian) {
                result.append(text)
            } else {
                result.append("&\(encoded)-")
            }
        }
        return result
    }
}
