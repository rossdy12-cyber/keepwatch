import Foundation

enum ArticleExtractor {
    static func decodeEntities(_ input: String) -> String {
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "mdash": "—", "ndash": "–"]
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return input }
        var output = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: input), let range = Range(match.range, in: output) else { continue }
            let key = String(input[keyRange])
            let number: UInt32? = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : key.hasPrefix("#") ? UInt32(key.dropFirst()) : nil
            if let value = named[key] ?? number.flatMap(UnicodeScalar.init).map({ String($0) }) {
                output.replaceSubrange(range, with: value)
            }
        }
        return output
    }

    static func extract(from html: String) -> String {
        var text = html.replacingOccurrences(of: "<(script|style|nav|header|footer|aside|head)\\b[^>]*>.*?</\\1\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        if let regex = try? NSRegularExpression(pattern: "<(article|main)\\b[^>]*>(.*?)</\\1\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 2), in: text) { text = String(text[range]) }
        text = text.replacingOccurrences(of: "(?is)<(script|style|nav|header|footer|aside|head)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\b[^>]*>|</(?:p|div|h[1-6]|li|section)\\s*>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(text).components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
