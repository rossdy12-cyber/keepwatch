import CryptoKit
import Foundation

enum BackupError: LocalizedError {
    case tooShort, wrongPassphrase, noPassphrase, notConfigured, http(Int)
    var errorDescription: String? {
        switch self {
        case .tooShort: return "That backup file looks corrupt or incomplete."
        case .wrongPassphrase: return "Wrong passphrase, or the file isn't an AuthVault backup."
        case .noPassphrase: return "Set a backup passphrase first."
        case .notConfigured: return "Set your NAS backup (WebDAV) URL first."
        case .http(let code): return "The NAS returned HTTP \(code)."
        }
    }
}

/// Encrypts/decrypts the accounts with AES-GCM, using a key derived from a passphrase (HKDF-SHA256 + random salt).
/// File layout: salt(16 bytes) ‖ AES-GCM combined box.
enum Backup {
    private struct Payload: Codable { var version = 1; var exported = Date(); var accounts: [OTPAccount] }

    private static func key(passphrase: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
                               salt: salt, info: Data("authvault.backup".utf8), outputByteCount: 32)
    }

    static func encrypt(_ accounts: [OTPAccount], passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw BackupError.noPassphrase }
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let plain = try JSONEncoder().encode(Payload(accounts: accounts))
        let box = try AES.GCM.seal(plain, using: key(passphrase: passphrase, salt: salt))
        guard let combined = box.combined else { throw BackupError.tooShort }
        return salt + combined
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> [OTPAccount] {
        guard !passphrase.isEmpty else { throw BackupError.noPassphrase }
        guard data.count > 16 + 12 else { throw BackupError.tooShort }
        let salt = data.prefix(16)
        let rest = data.suffix(from: data.startIndex + 16)
        do {
            let box = try AES.GCM.SealedBox(combined: rest)
            let plain = try AES.GCM.open(box, using: key(passphrase: passphrase, salt: salt))
            return try JSONDecoder().decode(Payload.self, from: plain).accounts
        } catch is CryptoKitError {
            throw BackupError.wrongPassphrase
        } catch is DecodingError {
            throw BackupError.wrongPassphrase
        }
    }
}

/// Uploads/downloads the encrypted backup to a WebDAV endpoint on the user's NAS.
enum WebDAV {
    static func upload(_ data: Data, to urlString: String, user: String, password: String) async throws {
        var request = try makeRequest(urlString, method: "PUT", user: user, password: password)
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await httpSession.data(for: request)
        try check(response)
    }

    static func download(from urlString: String, user: String, password: String) async throws -> Data {
        let request = try makeRequest(urlString, method: "GET", user: user, password: password)
        let (data, response) = try await httpSession.data(for: request)
        try check(response)
        return data
    }

    private static func makeRequest(_ urlString: String, method: String, user: String, password: String) throws -> URLRequest {
        let normalized = ServerAddress.normalize(urlString)
        guard !normalized.isEmpty, let url = URL(string: normalized), url.host != nil else { throw BackupError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        if !user.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw BackupError.http(http.statusCode) }
    }
}
