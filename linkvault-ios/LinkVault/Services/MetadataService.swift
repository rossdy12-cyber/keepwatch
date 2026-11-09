import Foundation

struct PageMetadata {
    let title: String
    let description: String
    let faviconURL: String?
    let canonicalURL: String?
    let siteName: String?
}

enum MetadataError: LocalizedError {
    case invalidURL, invalidResponse, requestFailed(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTP or HTTPS URL."
        case .invalidResponse: return "The page could not be read as HTML."
        case .requestFailed(let code): return "The page returned HTTP \(code)."
        }
    }
}

struct MetadataService {
    private func fetch(_ raw: String) async throws -> (String, URL) {
        guard let url = await LinkStore.webURL(raw) else { throw MetadataError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MetadataError.requestFailed(http.statusCode) }
        guard data.count <= 5_000_000,
              let mime = http.mimeType, ["text/html", "application/xhtml+xml"].contains(mime),
              let html = String(data: data, encoding: .utf8) else { throw MetadataError.invalidResponse }
        return (html, http.url ?? url)
    }

    private func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        for match in captures(pattern, in: tag) {
            result[match[1].lowercased()] = match[2...4].first(where: { !$0.isEmpty }).map(ArticleExtractor.decodeEntities) ?? ""
        }
        return result
    }

    func fetchMetadata(for raw: String) async throws -> PageMetadata {
        let (html, base) = try await fetch(raw)
        var meta: [String: String] = [:]
        var canonical: String?
        var icon: String?
        func resolved(_ value: String?) -> String? {
            guard let value, let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url.absoluteString
        }
        for tag in captures("<meta\\b[^>]*>", in: html) {
            let a = attributes(tag[0])
            if let key = a["property"] ?? a["name"], let content = a["content"] { meta[key.lowercased()] = content }
        }
        for tag in captures("<link\\b[^>]*>", in: html) {
            let a = attributes(tag[0])
            let rel = (a["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            if rel.contains("canonical") { canonical = resolved(a["href"]) }
            if rel.contains("icon") || rel.contains("apple-touch-icon") { icon = icon ?? resolved(a["href"]) }
        }
        let title = captures("<title\\b[^>]*>(.*?)</title>", in: html).first.map { ArticleExtractor.extract(from: $0[1]) }
        return PageMetadata(title: meta["og:title"] ?? meta["twitter:title"] ?? title ?? base.host ?? "Untitled link", description: meta["description"] ?? meta["og:description"] ?? "", faviconURL: icon ?? URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL.absoluteString, canonicalURL: canonical, siteName: meta["og:site_name"])
    }

    func fetchArticle(for raw: String) async throws -> String {
        let (html, _) = try await fetch(raw)
        let text = ArticleExtractor.extract(from: html)
        guard !text.isEmpty else { throw MetadataError.invalidResponse }
        return text
    }
}
