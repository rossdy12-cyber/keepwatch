import Foundation
import Security

enum SMTPSecurity: String, Codable, CaseIterable, Identifiable {
    case startTLS
    case tls

    var id: String { rawValue }
    var label: String { self == .tls ? "SSL/TLS" : "STARTTLS" }
}

struct MailAccount: Codable, Equatable {
    var displayName: String = ""
    var email: String = ""
    var username: String = ""
    var imapHost: String = ""
    var imapPort: Int = 993
    var smtpHost: String = ""
    var smtpPort: Int = 587
    var smtpSecurity: SMTPSecurity = .startTLS
    var saveSentCopy: Bool = true

    var loginName: String { username.isEmpty ? email : username }
    var sender: EmailAddress { EmailAddress(name: displayName, address: email) }
}

struct MailProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let imapHost: String
    let smtpHost: String
    let smtpPort: Int
    let smtpSecurity: SMTPSecurity
    let saveSentCopy: Bool
    let passwordHint: String

    static let all: [MailProvider] = [
        MailProvider(id: "icloud", name: "iCloud", imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS, saveSentCopy: true,
                     passwordHint: "Use an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords."),
        MailProvider(id: "gmail", name: "Gmail", imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls, saveSentCopy: false,
                     passwordHint: "Use an app password from myaccount.google.com/apppasswords (needs 2-Step Verification)."),
        MailProvider(id: "outlook", name: "Outlook", imapHost: "outlook.office365.com", smtpHost: "smtp-mail.outlook.com", smtpPort: 587, smtpSecurity: .startTLS, saveSentCopy: false,
                     passwordHint: "Microsoft may require an app password, and some accounts don't allow password sign-in at all."),
        MailProvider(id: "yahoo", name: "Yahoo", imapHost: "imap.mail.yahoo.com", smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .tls, saveSentCopy: true,
                     passwordHint: "Use an app password from Yahoo Account Security → Generate app password."),
        MailProvider(id: "fastmail", name: "Fastmail", imapHost: "imap.fastmail.com", smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpSecurity: .tls, saveSentCopy: true,
                     passwordHint: "Use an app password from Fastmail Settings → Privacy & Security."),
        MailProvider(id: "custom", name: "Other", imapHost: "", smtpHost: "", smtpPort: 587, smtpSecurity: .startTLS, saveSentCopy: true,
                     passwordHint: "Your provider's mail password or app password.")
    ]

    static func guess(for email: String) -> MailProvider? {
        let domain = email.split(separator: "@").last?.lowercased() ?? ""
        switch domain {
        case "icloud.com", "me.com", "mac.com": return all.first { $0.id == "icloud" }
        case "gmail.com", "googlemail.com": return all.first { $0.id == "gmail" }
        case "outlook.com", "hotmail.com", "live.com", "msn.com", "hotmail.co.uk", "outlook.co.uk": return all.first { $0.id == "outlook" }
        case "yahoo.com", "yahoo.co.uk", "ymail.com": return all.first { $0.id == "yahoo" }
        case "fastmail.com", "fastmail.fm": return all.first { $0.id == "fastmail" }
        default: return nil
        }
    }
}

enum AccountStorage {
    private static let accountKey = "crypt.account"
    private static let passwordAccount = "mail-password"

    static func load() -> MailAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(MailAccount.self, from: data)
    }

    static func save(_ account: MailAccount, password: String) {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountKey)
        }
        Keychain.save(password, account: passwordAccount)
    }

    static func password() -> String? {
        Keychain.read(account: passwordAccount)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: accountKey)
        Keychain.delete(account: passwordAccount)
    }
}

enum Keychain {
    private static let service = "app.keepwatch.crypt"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
