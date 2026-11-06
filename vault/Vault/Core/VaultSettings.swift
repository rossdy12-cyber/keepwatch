import Foundation

struct VaultSettings {
    var serverURL: String
    var webDAVPath: String
    var username: String

    var password: String {
        get {
            Keychain.read(account: "vault.password") ?? ""
        }
        set {
            if newValue.isEmpty {
                Keychain.delete(account: "vault.password")
            } else {
                Keychain.save(newValue, account: "vault.password")
            }
        }
    }

    static func load() -> VaultSettings {
        let defaults = UserDefaults.standard

        return VaultSettings(
            serverURL: defaults.string(forKey: "vault.serverURL") ?? "https://vault.nas-server.co.uk",
            webDAVPath: defaults.string(forKey: "vault.webDAVPath") ?? "/",
            username: defaults.string(forKey: "vault.username") ?? ""
        )
    }

    func save() {
        UserDefaults.standard.set(serverURL, forKey: "vault.serverURL")
        UserDefaults.standard.set(webDAVPath, forKey: "vault.webDAVPath")
        UserDefaults.standard.set(username, forKey: "vault.username")
    }

    var baseURL: URL? {
        var server = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !server.hasPrefix("http://") && !server.hasPrefix("https://") {
            server = "https://" + server
        }

        guard var components = URLComponents(string: server) else {
            return nil
        }

        let path = webDAVPath
            .trimmingCharacters(in: .whitespacesAndNewlines)

        components.path = path.hasPrefix("/") ? path : "/" + path

        return components.url
    }
}
