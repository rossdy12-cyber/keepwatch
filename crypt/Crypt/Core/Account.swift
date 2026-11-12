import Foundation
import Security

enum SMTPSecurity: String, Codable, CaseIterable, Identifiable {
    case startTLS
    case tls

    var id: String { rawValue }
    var label: String { self == .tls ? "SSL/TLS" : "STARTTLS" }
}

struct MailAccount: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
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
    var label: String { displayName.isEmpty ? email : displayName }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, displayName, email, username, imapHost, imapPort, smtpHost, smtpPort, smtpSecurity, saveSentCopy
    }

    // Tolerates accounts saved by older versions, which had no id.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        imapHost = try c.decodeIfPresent(String.self, forKey: .imapHost) ?? ""
        imapPort = try c.decodeIfPresent(Int.self, forKey: .imapPort) ?? 993
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        smtpPort = try c.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 587
        smtpSecurity = try c.decodeIfPresent(SMTPSecurity.self, forKey: .smtpSecurity) ?? .startTLS
        saveSentCopy = try c.decodeIfPresent(Bool.self, forKey: .saveSentCopy) ?? true
    }
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
    private static let accountsKey = "crypt.accounts"
    private static let activeKey = "crypt.activeAccount"
    private static let legacyAccountKey = "crypt.account"
    private static let legacyPasswordAccount = "mail-password"

    static func loadAll() -> [MailAccount] {
        migrateLegacy()
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) else { return [] }
        return accounts
    }

    static func saveAll(_ accounts: [MailAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    static var activeID: UUID? {
        get { UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: activeKey) }
    }

    static func password(for id: UUID) -> String? {
        Keychain.read(account: "password-\(id.uuidString)")
    }

    static func setPassword(_ password: String, for id: UUID) {
        Keychain.save(password, account: "password-\(id.uuidString)")
    }

    static func deletePassword(for id: UUID) {
        Keychain.delete(account: "password-\(id.uuidString)")
    }

    /// Version 1 stored a single account; move it into the list.
    private static func migrateLegacy() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: legacyAccountKey) else { return }
        if defaults.data(forKey: accountsKey) == nil,
           let account = try? JSONDecoder().decode(MailAccount.self, from: data) {
            if let password = Keychain.read(account: legacyPasswordAccount) {
                setPassword(password, for: account.id)
            }
            if let encoded = try? JSONEncoder().encode([account]) {
                defaults.set(encoded, forKey: accountsKey)
            }
            activeID = account.id
        }
        defaults.removeObject(forKey: legacyAccountKey)
        Keychain.delete(account: legacyPasswordAccount)
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
