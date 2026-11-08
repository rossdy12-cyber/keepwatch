import Foundation

/// RFC 4648 Base32 decoder for TOTP secrets (no padding, case-insensitive, spaces ignored).
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let lookup: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        return map
    }()

    static func decode(_ string: String) -> Data? {
        let clean = string.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard !clean.isEmpty else { return nil }
        var bits = 0
        var value = 0
        var out = [UInt8]()
        for ch in clean {
            guard let v = lookup[ch] else { return nil }
            value = (value << 5) | Int(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return Data(out)
    }

    static func isValid(_ string: String) -> Bool {
        decode(string).map { !$0.isEmpty } ?? false
    }
}
