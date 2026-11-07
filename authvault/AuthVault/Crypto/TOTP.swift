import CryptoKit
import Foundation

enum OTPAlgorithm: String, Codable, CaseIterable, Identifiable {
    case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    var id: String { rawValue }
}

struct TOTPConfig: Codable, Equatable {
    var secret: String                    // Base32
    var digits: Int = 6
    var period: Int = 30
    var algorithm: OTPAlgorithm = .sha1
}

enum TOTP {
    /// The current code for a config, or dots if the secret is unreadable.
    static func code(_ config: TOTPConfig, at date: Date = Date()) -> String {
        guard let key = Base32.decode(config.secret), !key.isEmpty else {
            return String(repeating: "•", count: max(config.digits, 6))
        }
        let period = max(config.period, 1)
        let counter = UInt64(floor(date.timeIntervalSince1970 / Double(period)))
        return hotp(key: key, counter: counter, digits: config.digits, algorithm: config.algorithm)
    }

    /// Seconds remaining in the current step.
    static func remaining(_ config: TOTPConfig, at date: Date = Date()) -> Int {
        let period = max(config.period, 1)
        return period - Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period)))
    }

    static func hotp(key: Data, counter: UInt64, digits: Int, algorithm: OTPAlgorithm) -> String {
        var big = counter.bigEndian
        let message = withUnsafeBytes(of: &big) { Data($0) }
        let symmetric = SymmetricKey(data: key)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let truncated = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        let d = min(max(digits, 6), 8)
        let mod = UInt32(pow(10.0, Double(d)))
        return String(format: "%0\(d)d", truncated % mod)
    }
}
