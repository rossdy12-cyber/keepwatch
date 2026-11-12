import Foundation

/// A Tampermonkey-style userscript: custom JavaScript injected into pages whose URL matches a pattern.
struct UserScript: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var pattern: String   // e.g. *://*.example.com/*  (glob) or a plain substring
    var code: String
    var enabled: Bool = true

    /// Does this script run on `url`? Supports `*` globs and plain substring matches.
    func matches(_ url: String) -> Bool {
        guard enabled else { return false }
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p == "*" || p == "*://*/*" { return true }
        if !p.contains("*") { return url.contains(p) }
        // Glob -> regex
        let escaped = NSRegularExpression.escapedPattern(for: p).replacingOccurrences(of: "\\*", with: ".*")
        return (try? NSRegularExpression(pattern: "^" + escaped + "$"))?
            .firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            || url.range(of: escaped, options: .regularExpression) != nil
    }
}

@MainActor
final class UserScriptStore: ObservableObject {
    static let shared = UserScriptStore()
    @Published var scripts: [UserScript] { didSet { persist() } }
    private let key = "userscripts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: "userscripts.v1"),
           let s = try? JSONDecoder().decode([UserScript].self, from: data) {
            scripts = s
        } else {
            scripts = [
                UserScript(name: "Example — greet",
                           pattern: "*",
                           code: "console.log('Crimson userscript running on ' + location.host);",
                           enabled: false)
            ]
        }
    }

    func add() -> UserScript {
        let s = UserScript(name: "New script", pattern: "*://*.example.com/*", code: "// your JavaScript here\n")
        scripts.insert(s, at: 0)
        return s
    }
    func update(_ s: UserScript) {
        if let i = scripts.firstIndex(where: { $0.id == s.id }) { scripts[i] = s }
    }
    func delete(_ s: UserScript) { scripts.removeAll { $0.id == s.id } }

    /// Scripts that should run on the given URL, as one combined JS blob.
    func injection(for url: String) -> String? {
        let matching = scripts.filter { $0.matches(url) }
        guard !matching.isEmpty else { return nil }
        return matching.map { "(function(){try{\n\($0.code)\n}catch(e){console.error('Crimson userscript error',e)}})();" }
            .joined(separator: "\n")
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(scripts) { UserDefaults.standard.set(d, forKey: key) }
    }
}
