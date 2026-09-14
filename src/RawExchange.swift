import Foundation

/// One HTTP round trip with the API, kept so the user can inspect exactly what
/// was sent and what came back.
struct RawExchange: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var method: String = "GET"
    var url: String = ""
    var requestHeaders: [String: String] = [:]
    var requestBody: String = ""
    var status: Int = 0
    var responseHeaders: [String: String] = [:]
    var responseBody: String = ""
    /// Set when the exchange never completed (network failure, cancellation…).
    var failure: String?

    init(request: URLRequest) {
        method = request.httpMethod ?? "GET"
        url = request.url?.absoluteString ?? ""
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            requestHeaders[key] = key.lowercased() == "authorization" ? Self.masked(value) : value
        }
        requestBody = Self.bodyText(request.httpBody, contentType: request.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Records the status line and headers of the response.
    mutating func apply(_ response: HTTPURLResponse?) {
        guard let response else { return }
        status = response.statusCode
        for (key, value) in response.allHeaderFields {
            responseHeaders["\(key)"] = "\(value)"
        }
    }

    mutating func setResponseBody(_ data: Data) {
        setResponseBody(String(decoding: data, as: UTF8.self))
    }

    mutating func setResponseBody(_ text: String) {
        responseBody = RawFormat.capped(RawFormat.redactBase64(text))
    }

    // MARK: Presentation

    /// The endpoint without the base URL, e.g. `chat/completions`.
    var endpoint: String {
        guard let components = URLComponents(string: url) else { return url }
        let path = components.path.split(separator: "/").suffix(2).joined(separator: "/")
        return path.isEmpty ? url : path
    }

    var summary: String {
        var text = "\(method) \(endpoint)"
        if status > 0 { text += " · \(status)" }
        if failure != nil { text += " · error" }
        return text
    }

    var requestText: String {
        var lines = ["\(method) \(url)"]
        lines += Self.headerLines(requestHeaders)
        if !requestBody.isEmpty { lines += ["", RawFormat.prettyJSON(requestBody)] }
        return lines.joined(separator: "\n")
    }

    var responseText: String {
        var lines: [String] = []
        if status > 0 { lines.append("HTTP \(status) \(Self.phrase(for: status))") }
        lines += Self.headerLines(responseHeaders)
        if let failure { lines += ["", "⚠︎ \(failure)"] }
        if !responseBody.isEmpty { lines += ["", RawFormat.prettyJSON(responseBody)] }
        return lines.joined(separator: "\n")
    }

    private static let phrases: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 400: "Bad Request",
        401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 408: "Request Timeout",
        409: "Conflict", 413: "Payload Too Large", 422: "Unprocessable Entity",
        429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    private static func phrase(for status: Int) -> String {
        phrases[status] ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }

    private static func headerLines(_ headers: [String: String]) -> [String] {
        headers.keys.sorted { $0.lowercased() < $1.lowercased() }.map { "\($0): \(headers[$0] ?? "")" }
    }

    /// Keeps just enough of a credential to recognise it.
    private static func masked(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard let secret = parts.last else { return value }
        let prefix = parts.count > 1 ? parts[0] + " " : ""
        guard secret.count > 12 else { return prefix + "••••" }
        return prefix + secret.prefix(6) + "…" + secret.suffix(4)
    }

    private static func bodyText(_ data: Data?, contentType: String?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let type = (contentType ?? "").lowercased()
        guard type.contains("json") || type.contains("text"), let text = String(data: data, encoding: .utf8) else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            let suffix = type.isEmpty ? "" : " · \(type)"
            return "[cuerpo binario: \(size)\(suffix)]"
        }
        return RawFormat.capped(RawFormat.redactBase64(text))
    }
}

/// Collects the raw exchanges of a single assistant turn.
/// Written from the networking task, read from the main actor when the turn ends.
final class RawLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RawExchange] = []

    var exchanges: [RawExchange] {
        lock.withLock { storage }
    }

    func record(_ exchange: RawExchange) {
        lock.withLock { storage.append(exchange) }
    }
}

enum RawFormat {
    /// Upper bound for a stored body; conversations are saved to disk with them.
    static let limit = 60_000

    static func capped(_ text: String, limit: Int = RawFormat.limit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[\(text.count - limit) caracteres omitidos]"
    }

    /// Shortens base64 payloads (image data URLs, `b64_json`, an image call's `result`)
    /// so a conversation doesn't store megabytes of pixels twice.
    static func redactBase64(_ text: String) -> String {
        var text = shortenPayloads(in: text, after: ";base64,")
        for key in ["\"b64_json\"", "\"result\""] {
            text = shortenPayloads(in: text, after: key, quoted: true)
        }
        return text
    }

    private static func shortenPayloads(in text: String, after marker: String, quoted: Bool = false) -> String {
        guard text.contains(marker) else { return text }
        var result = ""
        var rest = Substring(text)
        while let found = rest.range(of: marker) {
            result += rest[..<found.upperBound]
            var start = found.upperBound
            if quoted {
                while start < rest.endIndex, rest[start] == ":" || rest[start] == " " {
                    start = rest.index(after: start)
                }
                guard start < rest.endIndex, rest[start] == "\"" else {
                    rest = rest[found.upperBound...]
                    continue
                }
                start = rest.index(after: start)
                result += rest[found.upperBound..<start]
            }
            var end = start
            while end < rest.endIndex, isBase64(rest[end]) { end = rest.index(after: end) }
            let length = rest.distance(from: start, to: end)
            if length > 128 {
                var keep = rest.index(start, offsetBy: 32)
                // Never cut between a backslash and the character it escapes.
                if rest[rest.index(before: keep)] == "\\" { keep = rest.index(before: keep) }
                let kept = rest.distance(from: start, to: keep)
                result += rest[start..<keep] + "…[\(length - kept) caracteres base64 omitidos]"
            } else {
                result += rest[start..<end]
            }
            rest = rest[end...]
        }
        return result + rest
    }

    /// `JSONSerialization` escapes forward slashes, so a data URL reaches us as
    /// `data:image\/jpeg;base64,\/9j\/4AAQ…`; the backslash counts as part of the run.
    private static func isBase64(_ character: Character) -> Bool {
        character.isLetter && character.isASCII || character.isNumber && character.isASCII
            || "+/=-_\\".contains(character)
    }

    /// Re-indents JSON by moving whitespace only, so keys keep the order the
    /// server (or the app) actually used. Anything that isn't JSON is returned as is.
    static func prettyJSON(_ raw: String) -> String {
        guard let first = raw.first, first == "{" || first == "[" else { return raw }
        let characters = Array(raw)
        var out = ""
        out.reserveCapacity(characters.count + characters.count / 3)
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0

        func indent() {
            out.append("\n")
            out.append(String(repeating: "  ", count: depth))
        }

        while index < characters.count {
            let character = characters[index]
            if inString {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inString = true
                out.append(character)
            case "{", "[":
                let close: Character = character == "{" ? "}" : "]"
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == close {
                    out.append(character)
                    out.append(close)
                    index = next + 1
                    continue
                }
                depth += 1
                out.append(character)
                indent()
            case "}", "]":
                depth = max(depth - 1, 0)
                indent()
                out.append(character)
            case ",":
                out.append(character)
                indent()
            case ":":
                out.append(": ")
            case " ", "\n", "\t", "\r":
                break
            default:
                out.append(character)
            }
            index += 1
        }
        return out
    }
}
