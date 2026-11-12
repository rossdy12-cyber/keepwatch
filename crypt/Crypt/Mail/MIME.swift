import Foundation

struct EmailAddress: Hashable, Codable {
    var name: String
    var address: String

    var displayName: String { name.isEmpty ? address : name }

    /// Parses a header value such as `"Ada L." <ada@example.com>, bob@example.com`.
    static func parseList(_ value: String) -> [EmailAddress] {
        var results: [EmailAddress] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        for ch in value {
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if ch == "<" { angleDepth += 1 }
                if ch == ">" { angleDepth = max(0, angleDepth - 1) }
                if ch == ",", angleDepth == 0 {
                    if let address = parseSingle(current) { results.append(address) }
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        if let address = parseSingle(current) { results.append(address) }
        return results
    }

    static func parseSingle(_ raw: String) -> EmailAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            return EmailAddress(name: name, address: address)
        }
        // "addr (Comment Name)" style
        if let paren = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            let address = String(trimmed[..<paren]).trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[trimmed.index(after: paren)..<trimmed.index(before: trimmed.endIndex)])
            return EmailAddress(name: name, address: address)
        }
        return EmailAddress(name: "", address: trimmed)
    }

    /// Formats for an outgoing header, encoding the name when needed.
    var headerValue: String {
        guard !name.isEmpty else { return "<\(address)>" }
        if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address)>"
        }
        return "\(MIME.encodeHeaderWord(name)) <\(address)>"
    }
}

struct Attachment: Identifiable, Hashable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

/// A decoded message: the parts a reader needs.
struct ParsedMessage {
    var headers: MIMEHeaders
    var plainText: String?
    var html: String?
    var attachments: [Attachment] = []

    var subject: String { headers.decoded("Subject") ?? "" }
    var from: [EmailAddress] { EmailAddress.parseList(headers.decoded("From") ?? "") }
    var to: [EmailAddress] { EmailAddress.parseList(headers.decoded("To") ?? "") }
    var cc: [EmailAddress] { EmailAddress.parseList(headers.decoded("Cc") ?? "") }
    var replyTo: [EmailAddress] { EmailAddress.parseList(headers.decoded("Reply-To") ?? "") }
    var date: Date? { headers.value("Date").flatMap(MIME.parseDate) }
    var messageID: String? { headers.value("Message-ID")?.trimmingCharacters(in: .whitespaces) }
    var references: String? { headers.value("References") }

    /// Readable text for quoting in replies and for previews.
    var bodyText: String {
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        if let html { return MIME.htmlToText(html) }
        return ""
    }
}

struct MIMEHeaders {
    private(set) var fields: [(name: String, value: String)] = []

    init(_ fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    func value(_ name: String) -> String? {
        let lower = name.lowercased()
        return fields.first { $0.name.lowercased() == lower }?.value
    }

    func decoded(_ name: String) -> String? {
        value(name).map(MIME.decodeHeader)
    }

    /// The main value and parameters of a structured header such as Content-Type.
    func parameters(_ name: String) -> (value: String, params: [String: String]) {
        guard let raw = value(name) else { return ("", [:]) }
        return MIME.parseParameters(raw)
    }
}

enum MIME {
    // MARK: Message structure

    static func parse(_ data: Data) -> ParsedMessage {
        let (headers, body) = splitHeaders(data)
        var message = ParsedMessage(headers: headers)
        collect(headers: headers, body: body, into: &message, depth: 0)
        return message
    }

    static func splitHeaders(_ data: Data) -> (MIMEHeaders, Data) {
        let crlf2 = data.range(of: Data([13, 10, 13, 10]))
        let lf2 = data.range(of: Data([10, 10]))
        let split: Range<Data.Index>?
        switch (crlf2, lf2) {
        case let (a?, b?): split = a.lowerBound <= b.lowerBound ? a : b
        case let (a?, nil): split = a
        case let (nil, b?): split = b
        default: split = nil
        }
        // A part that starts with a blank line has no headers.
        if data.starts(with: [13, 10]) { return (MIMEHeaders(), Data(data.dropFirst(2))) }
        if data.starts(with: [10]) { return (MIMEHeaders(), Data(data.dropFirst(1))) }
        guard let split else { return (parseHeaderBlock(data), Data()) }
        let headerData = data[data.startIndex..<split.lowerBound]
        let body = data[split.upperBound...]
        return (parseHeaderBlock(Data(headerData)), Data(body))
    }

    static func parseHeaderBlock(_ data: Data) -> MIMEHeaders {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var fields: [(String, String)] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.isEmpty { continue }
            if let first = rawLine.first, first == " " || first == "\t" {
                if !fields.isEmpty {
                    fields[fields.count - 1].1 += " " + rawLine.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let name = String(rawLine[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(rawLine[rawLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields.append((name, value))
        }
        return MIMEHeaders(fields.map { (name: $0.0, value: $0.1) })
    }

    private static func collect(headers: MIMEHeaders, body: Data, into message: inout ParsedMessage, depth: Int) {
        guard depth < 12 else { return }
        let (rawType, params) = headers.parameters("Content-Type")
        let type = rawType.isEmpty ? "text/plain" : rawType.lowercased()
        let disposition = headers.parameters("Content-Disposition")
        let filename = disposition.params["filename"].map(decodeHeader) ?? params["name"].map(decodeHeader)
        let isAttachment = disposition.value.lowercased() == "attachment"

        if type.hasPrefix("multipart/") {
            guard let boundary = params["boundary"] else { return }
            for part in splitMultipart(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeaders(part)
                collect(headers: partHeaders, body: partBody, into: &message, depth: depth + 1)
            }
            return
        }

        if type == "message/rfc822", !isAttachment {
            let (innerHeaders, innerBody) = splitHeaders(body)
            collect(headers: innerHeaders, body: innerBody, into: &message, depth: depth + 1)
            return
        }

        let encoding = headers.value("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) ?? "7bit"
        let decoded = decodeTransfer(body, encoding: encoding)

        if !isAttachment, filename == nil, type == "text/plain" {
            let text = decodeText(decoded, charset: params["charset"])
            message.plainText = (message.plainText.map { $0 + "\n\n" } ?? "") + text
            return
        }
        if !isAttachment, filename == nil, type == "text/html" {
            let text = decodeText(decoded, charset: params["charset"])
            message.html = (message.html.map { $0 + "\n<hr>\n" } ?? "") + text
            return
        }
        // Inline images without a name are left out; everything else is listed as an attachment.
        if filename == nil && type.hasPrefix("image/") && !isAttachment { return }
        let name = filename ?? (type == "text/calendar" ? "invite.ics" : "attachment")
        message.attachments.append(Attachment(filename: name, mimeType: type, data: decoded))
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            // A delimiter must start a line.
            let atLineStart = range.lowerBound == body.startIndex || body[range.lowerBound - 1] == 10
            if !atLineStart {
                searchStart = range.upperBound
                continue
            }
            if let start = partStart {
                var end = range.lowerBound
                if end > start, body[end - 1] == 10 { end -= 1 }
                if end > start, body[end - 1] == 13 { end -= 1 }
                parts.append(Data(body[start..<end]))
            }
            var next = range.upperBound
            let isClosing = body.count >= 2 && next + 1 < body.endIndex && body[next] == UInt8(ascii: "-") && body[next + 1] == UInt8(ascii: "-")
            if isClosing { return parts }
            // Skip to the end of the delimiter line.
            while next < body.endIndex, body[next] != 10 { next += 1 }
            if next < body.endIndex { next += 1 }
            partStart = next
            searchStart = next
        }
        // Truncated message (for example a preview): keep what we have.
        if let start = partStart, start < body.endIndex {
            parts.append(Data(body[start...]))
        }
        return parts
    }

    // MARK: Transfer encodings

    static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64": return decodeBase64Lenient(data)
        case "quoted-printable": return decodeQuotedPrintable(data)
        default: return data
        }
    }

    static func decodeBase64Lenient(_ data: Data) -> Data {
        var clean = data.filter { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47
        }
        // Drop a trailing incomplete group (for truncated previews).
        let remainder = clean.count % 4
        if remainder == 1 { clean = clean.dropLast(1) }
        var padded = Data(clean)
        if padded.count % 4 != 0 {
            padded.append(contentsOf: [UInt8](repeating: 61, count: 4 - padded.count % 4))
        }
        return Data(base64Encoded: padded) ?? Data()
    }

    static func decodeQuotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                if i + 2 >= bytes.count { break } // truncated soft break
            }
            if underscoreIsSpace, byte == UInt8(ascii: "_") {
                out.append(0x20)
            } else {
                out.append(byte)
            }
            i += 1
        }
        return Data(out)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    // MARK: Charsets

    static func decodeText(_ data: Data, charset: String?) -> String {
        let encoding = stringEncoding(for: charset)
        if let text = String(data: data, encoding: encoding) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func stringEncoding(for charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), !charset.isEmpty else {
            return .utf8
        }
        switch charset {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "iso-8859-2": return .isoLatin2
        case "utf-16": return .utf16
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            }
            return .utf8
        }
    }

    // MARK: Headers

    /// Decodes RFC 2047 encoded words such as `=?UTF-8?B?...?=`.
    static func decodeHeader(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let ns = value as NSString
        var result = ""
        var last = 0
        var previousWasEncoded = false
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            // Whitespace between two encoded words is dropped.
            if !(previousWasEncoded && between.trimmingCharacters(in: .whitespaces).isEmpty) {
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1)).components(separatedBy: "*").first
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))
            let bytes: Data
            if mode == "B" {
                bytes = decodeBase64Lenient(Data(text.utf8))
            } else {
                bytes = decodeQuotedPrintable(Data(text.utf8), underscoreIsSpace: true)
            }
            result += decodeText(bytes, charset: charset)
            last = match.range.location + match.range.length
            previousWasEncoded = true
        }
        result += ns.substring(from: last)
        return result
    }

    static func encodeHeaderWord(_ text: String) -> String {
        guard !text.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    static func parseParameters(_ raw: String) -> (value: String, params: [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)
        let value = segments.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [Int: String]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            // RFC 2231: name*=utf-8''encoded and name*0=..., name*1=...
            var extended = false
            if key.hasSuffix("*") {
                key.removeLast()
                extended = true
            }
            if extended, let quote = val.range(of: "''") {
                let charset = String(val[..<quote.lowerBound])
                let encoded = String(val[quote.upperBound...])
                val = decodeText(percentDecode(encoded), charset: charset)
            } else if extended {
                val = val.removingPercentEncoding ?? val
            }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: [:]][n] = val
                continue
            }
            params[key] = val
        }
        for (base, pieces) in continuations where params[base] == nil {
            params[base] = pieces.keys.sorted().compactMap { pieces[$0] }.joined()
        }
        return (value, params)
    }

    private static func percentDecode(_ text: String) -> Data {
        var out: [UInt8] = []
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return Data(out)
    }

    // MARK: Dates

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "dd-MMM-yyyy HH:mm:ss Z"
    ]

    private static let parsers: [DateFormatter] = dateFormats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func parseDate(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: "  ", with: " ")
        for parser in parsers {
            if let date = parser.date(from: text) { return date }
        }
        return nil
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: HTML to text

    static func htmlToText(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            (#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|tr|li|h[1-6]|table)>"#, "\n"),
            (#"(?s)<[^>]+>"#, ""),
            (#"[ \t]+"#, " "),
            (#"\n\s*\n\s*\n+"#, "\n\n")
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&zwnj;": "", "&#8203;": "", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–", "&copy;": "©"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = text as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let isHex = match.range(at: 1).length > 0
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = UnicodeScalar(code) {
                    output.unicodeScalars.append(scalar)
                }
                last = match.range.location + match.range.length
            }
            output += ns.substring(from: last)
            text = output
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preview(from text: String, limit: Int = 180) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    // MARK: Building outgoing mail

    static func buildMessage(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress],
        subject: String,
        body: String,
        inReplyTo: String?,
        references: String?
    ) -> (data: Data, messageID: String) {
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "crypt.local"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
        var lines: [String] = []
        lines.append("From: \(from.headerValue)")
        lines.append("To: \(to.map(\.headerValue).joined(separator: ", "))")
        if !cc.isEmpty { lines.append("Cc: \(cc.map(\.headerValue).joined(separator: ", "))") }
        lines.append("Subject: \(encodeHeaderWord(subject))")
        lines.append("Date: \(formatDate(Date()))")
        lines.append("Message-ID: \(messageID)")
        if let inReplyTo, !inReplyTo.isEmpty {
            lines.append("In-Reply-To: \(inReplyTo)")
            let refs = [references, inReplyTo].compactMap { $0 }.joined(separator: " ")
            lines.append("References: \(refs)")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("X-Mailer: Crypt for iPhone")
        lines.append("")
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let encoded = Data(normalized.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        lines.append(encoded)
        let text = lines.joined(separator: "\r\n") + "\r\n"
        return (Data(text.utf8), messageID)
    }
}
