import CryptoKit
import Foundation

enum OTPAlgorithm: String, Codable, CaseIterable {
    case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
}

/// One authenticator entry: the same secret your authenticator app holds, plus which sites it belongs to.
struct OTPAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Base32, as shown by TrueNAS / Authelia when setting up 2FA.
    var secret: String
    /// Comma-separated host names this code is for, matched exactly: "nas-server.co.uk" is TrueNAS only and
    /// "auth.nas-server.co.uk" is Authelia only. "*.example.com" opts in to every subdomain.
    var sites: String
    var digits: Int = 6
    var period: Int = 30
    var algorithm: OTPAlgorithm = .sha1

    var siteList: [String] {
        sites.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    var key: Data? { Base32.decode(secret) }

    func code(at date: Date = Date()) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return TOTP.code(key: key, date: date, digits: digits, period: period, algorithm: algorithm)
    }

    func secondsLeft(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    /// How well this account matches a host: the length of the matching site name, or nil.
    /// Exact names only, so a TrueNAS code is never typed into another sign-in page on the same domain
    /// (Authelia submits as soon as the boxes are full, and wrong codes count towards its lock-out).
    func matchStrength(host: String) -> Int? {
        let host = host.lowercased()
        return siteList.compactMap { site -> Int? in
            if site.hasPrefix("*.") {
                let domain = String(site.dropFirst(2))
                return host.hasSuffix("." + domain) ? domain.count : nil
            }
            return host == site ? site.count + 1 : nil
        }.max()
    }

    /// Reads an `otpauth://totp/Issuer:name?secret=…&issuer=…` link (what the QR code contains).
    static func from(otpauth text: String) -> OTPAccount? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "otpauth", components.host?.lowercased() == "totp" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        guard let secret = value("secret"), Base32.decode(secret) != nil else { return nil }
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        let issuer = value("issuer") ?? label.split(separator: ":").first.map(String.init) ?? ""
        let account = label.split(separator: ":").last.map(String.init) ?? ""
        var result = OTPAccount(name: issuer.isEmpty ? account : (account.isEmpty || account == issuer ? issuer : "\(issuer) (\(account))"),
                                secret: secret, sites: "")
        if let digits = value("digits").flatMap(Int.init), (6...8).contains(digits) { result.digits = digits }
        if let period = value("period").flatMap(Int.init), period > 0 { result.period = period }
        if let algorithm = value("algorithm").flatMap({ OTPAlgorithm(rawValue: $0.uppercased()) }) { result.algorithm = algorithm }
        return result
    }
}

/// RFC 6238 time-based one-time passwords, the same as Google Authenticator / Authy / 2FAS.
enum TOTP {
    static func code(key: Data, date: Date, digits: Int, period: Int, algorithm: OTPAlgorithm) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(period))
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let symmetricKey = SymmetricKey(data: key)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let number = String(value % modulus)
        return String(repeating: "0", count: max(0, digits - number.count)) + number
    }
}

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ text: String) -> Data? {
        let cleaned = text.uppercased().filter { !" -=\n\t".contains($0) }
        guard !cleaned.isEmpty else { return nil }
        var bits: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            bits = (bits << 5) | UInt64(index)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((bits >> UInt64(bitCount)) & 0xff))
            }
        }
        return Data(bytes)
    }
}
