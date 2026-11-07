import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var webdavURL: String { didSet { UserDefaults.standard.set(webdavURL, forKey: "av.webdav"); applyTrust(old: ServerAddress.host(of: oldValue)) } }
    @Published var webdavUser: String { didSet { UserDefaults.standard.set(webdavUser, forKey: "av.user") } }
    @Published var webdavPassword: String { didSet { Keychain.set(webdavPassword, for: "webdav.pass") } }
    @Published var passphrase: String { didSet { Keychain.set(passphrase, for: "backup.pass") } }
    @Published var trustSelfSigned: Bool { didSet { UserDefaults.standard.set(trustSelfSigned, forKey: "av.trust"); applyTrust(old: nil) } }
    @Published var lockEnabled: Bool { didSet { UserDefaults.standard.set(lockEnabled, forKey: "av.lock") } }

    init() {
        let d = UserDefaults.standard
        webdavURL = d.string(forKey: "av.webdav") ?? ""
        webdavUser = d.string(forKey: "av.user") ?? ""
        trustSelfSigned = d.object(forKey: "av.trust") as? Bool ?? true
        lockEnabled = d.object(forKey: "av.lock") as? Bool ?? true
        webdavPassword = Keychain.get("webdav.pass")
        passphrase = Keychain.get("backup.pass")
        applyTrust(old: nil)
    }

    var backupConfigured: Bool { !ServerAddress.normalize(webdavURL).isEmpty }

    private func applyTrust(old: String?) {
        if let old { TrustDelegate.shared.setTrusted(host: old, trusted: false) }
        TrustDelegate.shared.setTrusted(host: ServerAddress.host(of: webdavURL), trusted: trustSelfSigned)
    }
}
