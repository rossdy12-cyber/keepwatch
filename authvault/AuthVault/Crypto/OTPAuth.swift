import Foundation

struct OTPAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var issuer: String
    var label: String
    var config: TOTPConfig

    var title: String { issuer.isEmpty ? (label.isEmpty ? "Account" : label) : issuer }
    var subtitle: String { label.isEmpty || label == issuer ? "" : label }
}

/// Parses and builds `otpauth://totp/...` URIs (the content of an authenticator QR code).
enum OTPAuth {
    static func parse(_ uri: String) -> OTPAccount? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "otpauth",
              (comps.host ?? "").lowercased() == "totp" else { return nil }
        let items = comps.queryItems ?? []
        func q(_ key: String) -> String? { items.first { $0.name.lowercased() == key }?.value }

        guard let secret = q("secret"), Base32.isValid(secret) else { return nil }

        var path = comps.path
        if path.hasPrefix("/") { path.removeFirst() }
        let labelPath = path.removingPercentEncoding ?? path

        var issuer = q("issuer") ?? ""
        var label = labelPath
        if let colon = labelPath.firstIndex(of: ":") {
            if issuer.isEmpty { issuer = String(labelPath[..<colon]).trimmingCharacters(in: .whitespaces) }
            label = String(labelPath[labelPath.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let digits = Int(q("digits") ?? "") ?? 6
        let period = Int(q("period") ?? "") ?? 30
        let algorithm = OTPAlgorithm(rawValue: (q("algorithm") ?? "SHA1").uppercased()) ?? .sha1
        if issuer.isEmpty { issuer = label.isEmpty ? "Account" : label }

        return OTPAccount(issuer: issuer, label: label,
                          config: TOTPConfig(secret: secret, digits: digits, period: period, algorithm: algorithm))
    }
}
