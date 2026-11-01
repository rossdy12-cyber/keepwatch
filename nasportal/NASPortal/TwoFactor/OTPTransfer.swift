import Foundation

/// One 2FA account read from an authenticator export, ready to go into Vaultwarden.
struct TransferAccount: Identifiable, Equatable {
    var id: String { secretBase32 + "|" + issuer + "|" + name }
    var issuer: String
    var name: String
    var secretBase32: String
    var digits: Int = 6
    var period: Int = 30
    var algorithm: OTPAlgorithm = .sha1
    var isTOTP = true

    var title: String {
        if issuer.isEmpty { return name.isEmpty ? "Unnamed account" : name }
        return issuer
    }

    /// The account name without a repeated "Issuer:" prefix.
    var username: String {
        if !issuer.isEmpty, name.lowercased().hasPrefix(issuer.lowercased() + ":") {
            return String(name.dropFirst(issuer.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    var asOTPAccount: OTPAccount {
        OTPAccount(name: title, secret: secretBase32, sites: "", digits: digits, period: period, algorithm: algorithm)
    }

    /// `otpauth://totp/Issuer:name?secret=…` — what Vaultwarden's "Authenticator key" field accepts.
    var otpauthURI: String {
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"
        let label = issuer.isEmpty ? username : "\(issuer):\(username)"
        components.path = "/" + label
        var items = [URLQueryItem(name: "secret", value: secretBase32)]
        if !issuer.isEmpty { items.append(URLQueryItem(name: "issuer", value: issuer)) }
        if digits != 6 { items.append(URLQueryItem(name: "digits", value: String(digits))) }
        if period != 30 { items.append(URLQueryItem(name: "period", value: String(period))) }
        if algorithm != .sha1 { items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue)) }
        components.queryItems = items
        return components.string ?? "otpauth://totp/?secret=\(secretBase32)"
    }
}

enum OTPTransfer {
    /// Reads every account from a QR code's text: a Google Authenticator export (`otpauth-migration://`)
    /// or an ordinary 2FA QR code (`otpauth://totp/…`).
    static func accounts(from text: String) -> [TransferAccount] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("otpauth-migration://") {
            return googleMigration(trimmed)
        }
        if lower.hasPrefix("otpauth://"), let account = OTPAccount.from(otpauth: trimmed),
           let key = account.key {
            let components = URLComponents(string: trimmed)
            var label = components?.path ?? ""
            if label.hasPrefix("/") { label.removeFirst() }
            let issuer = components?.queryItems?.first { $0.name.lowercased() == "issuer" }?.value
                ?? (label.contains(":") ? String(label.split(separator: ":")[0]) : "")
            return [TransferAccount(issuer: issuer, name: label, secretBase32: Base32.encode(key),
                                    digits: account.digits, period: account.period, algorithm: account.algorithm)]
        }
        return []
    }

    /// Google Authenticator's "Export accounts" QR codes: base64 protobuf in the `data` parameter.
    private static func googleMigration(_ text: String) -> [TransferAccount] {
        guard let components = URLComponents(string: text),
              var data = components.queryItems?.first(where: { $0.name == "data" })?.value else { return [] }
        data = data.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while data.count % 4 != 0 { data += "=" }
        guard let payload = Data(base64Encoded: data) else { return [] }

        var accounts: [TransferAccount] = []
        var reader = ProtobufReader(Array(payload))
        while let field = reader.next() {
            guard field.number == 1, let bytes = field.bytes else { continue } // repeated OtpParameters
            var otp = ProtobufReader(bytes)
            var secret: [UInt8] = []
            var account = TransferAccount(issuer: "", name: "", secretBase32: "")
            while let item = otp.next() {
                switch item.number {
                case 1: secret = item.bytes ?? []
                case 2: account.name = item.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                case 3: account.issuer = item.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                case 4:
                    switch item.value ?? 0 {
                    case 2: account.algorithm = .sha256
                    case 3: account.algorithm = .sha512
                    default: account.algorithm = .sha1
                    }
                case 5: account.digits = item.value == 2 ? 8 : 6
                case 6: account.isTOTP = item.value != 1 // 1 = HOTP (counter-based)
                default: break
                }
            }
            guard !secret.isEmpty else { continue }
            account.secretBase32 = Base32.encode(Data(secret))
            accounts.append(account)
        }
        return accounts
    }

    /// A Bitwarden-format CSV that Vaultwarden imports (Tools → Import data → Bitwarden (csv)).
    static func bitwardenCSV(_ accounts: [TransferAccount]) -> String {
        var lines = ["folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp"]
        for account in accounts {
            let row = ["", "", "login", account.title, "2FA code moved from an authenticator app", "", "0", "",
                       account.username, "", account.otpauthURI]
            lines.append(row.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(where: { ",\"\n\r".contains($0) }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

/// Just enough protobuf to read Google Authenticator exports.
struct ProtobufReader {
    struct Field {
        var number: Int
        var value: UInt64?
        var bytes: [UInt8]?
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func next() -> Field? {
        guard index < bytes.count, let key = varint() else { return nil }
        let number = Int(key >> 3)
        switch key & 7 {
        case 0:
            guard let value = varint() else { return nil }
            return Field(number: number, value: value)
        case 2:
            guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
            let end = index + Int(length)
            let slice = Array(bytes[index..<end])
            index = end
            return Field(number: number, bytes: slice)
        case 1:
            guard index + 8 <= bytes.count else { return nil }
            index += 8
            return Field(number: number)
        case 5:
            guard index + 4 <= bytes.count else { return nil }
            index += 4
            return Field(number: number)
        default:
            return nil
        }
    }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

extension Base32 {
    static func encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        }
        return output
    }
}
