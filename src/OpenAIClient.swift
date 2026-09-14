import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case http(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "La URL de la API no es válida. Revísala en Configuración."
        case .http(let status, let message):
            switch status {
            case 401: return "API key inválida o faltante (401). \(message)"
            case 404: return "Endpoint o modelo no encontrado (404). \(message)"
            case 429: return "Límite de uso alcanzado (429). \(message)"
            case 0: return message
            default: return "Error \(status): \(message)"
            }
        case .invalidResponse(let detail):
            return "Respuesta inesperada del servidor. \(detail)"
        }
    }
}

enum StreamEvent: Sendable {
    case content(String)
    /// An image returned inline by the model (data: URL or http URL).
    case image(String)
}

/// One output item of a Responses API reply, in the order the model produced them.
enum ResponseItem: Sendable {
    case text(String)
    /// A call to the built-in `image_generation` tool; `image` is nil when it failed.
    case image(id: String, status: String, image: Data?, revisedPrompt: String?, size: String?)
}

/// Minimal client for OpenAI-compatible APIs (`/models`, `/chat/completions`, `/responses`).
struct OpenAIClient: Sendable {
    let baseURL: URL
    let apiKey: String

    // MARK: Requests

    private func makeRequest(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String = "application/json",
        timeout: TimeInterval = 60
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func perform(_ request: URLRequest, log: RawLog? = nil) async throws -> Data {
        var record = RawExchange(request: request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            record.apply(http)
            record.setResponseBody(data)
            log?.record(record)
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw APIError.http(status: status, message: Self.errorMessage(from: data, status: status))
            }
            return data
        } catch {
            if record.status == 0 {
                record.failure = error.localizedDescription
                log?.record(record)
            }
            throw error
        }
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        let text = String(data: data, encoding: .utf8)?.trimmed ?? ""
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : String(text.prefix(400))
    }

    // MARK: Models

    func listModels() async throws -> [String] {
        let data = try await perform(makeRequest("models", timeout: 20))
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]?
            let models: [Model]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw APIError.invalidResponse("No se pudo leer la lista de modelos.")
        }
        let ids = (response.data ?? response.models ?? []).map(\.id)
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Chat

    func streamChat(body: Data, log: RawLog? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        let request = makeRequest("chat/completions", method: "POST", body: body, timeout: 600)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var record = RawExchange(request: request)
                var recorded = false
                // The stream is kept verbatim, line by line, for the raw view.
                var transcript = ""
                func commit() {
                    guard !recorded else { return }
                    recorded = true
                    log?.record(record)
                }
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    record.apply(http)
                    let status = http?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        record.setResponseBody(data)
                        commit()
                        throw APIError.http(status: status, message: Self.errorMessage(from: data, status: status))
                    }

                    // Requests use `stream: false`, so the usual answer is a single JSON body.
                    // SSE is still parsed below for servers that stream anyway.
                    let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                    if contentType.contains("application/json") {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        record.setResponseBody(data)
                        commit()
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                        try Self.emit(chunk, to: continuation)
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        if transcript.utf8.count < RawFormat.limit {
                            transcript += line + "\n"
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data)
                        else { continue }
                        try Self.emit(chunk, to: continuation)
                    }
                    record.setResponseBody(transcript)
                    commit()
                    continuation.finish()
                } catch {
                    // Keep whatever arrived before the stream broke.
                    record.setResponseBody(transcript)
                    record.failure = error.localizedDescription
                    commit()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func emit(_ chunk: ChatChunk, to continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws {
        if let error = chunk.error {
            throw APIError.http(status: 0, message: error.message ?? "Error desconocido del servidor.")
        }
        for choice in chunk.choices ?? [] {
            guard let delta = choice.delta ?? choice.message else { continue }
            if let text = delta.text, !text.isEmpty { continuation.yield(.content(text)) }
            for url in delta.imageURLs { continuation.yield(.image(url)) }
        }
    }

    /// Non-streaming completion that returns only the text (used for titles).
    func complete(body: Data) async throws -> String {
        let data = try await perform(makeRequest("chat/completions", method: "POST", body: body, timeout: 120))
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
        return chunk.choices?.first?.message?.text ?? ""
    }

    // MARK: Responses

    /// Non-streaming call to the Responses API, which runs hosted tools such as
    /// `image_generation` on the server and returns their results with the reply.
    func createResponse(body: Data, log: RawLog? = nil) async throws -> [ResponseItem] {
        let data = try await perform(makeRequest("responses", method: "POST", body: body, timeout: 600), log: log)
        guard let response = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw APIError.invalidResponse("No se pudo leer la respuesta de /responses.")
        }
        if let message = response.error?.message {
            throw APIError.http(status: 0, message: message)
        }
        let items: [ResponseItem] = (response.output ?? []).compactMap { item in
            switch item.type {
            case "message":
                let text = (item.content ?? []).compactMap { $0.text ?? $0.refusal }.joined()
                return text.isEmpty ? nil : .text(text)
            case "image_generation_call":
                let image = item.result.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
                return .image(
                    id: item.id ?? "ig_\(UUID().uuidString.prefix(12))", status: item.status ?? "unknown",
                    image: image, revisedPrompt: item.revised_prompt, size: item.size)
            default:
                return nil
            }
        }
        if items.isEmpty, let reason = response.incomplete_details?.reason {
            throw APIError.invalidResponse("La respuesta quedó incompleta (\(reason)).")
        }
        return items
    }

    /// Resolves a `data:` URL or downloads an http(s) image URL.
    static func downloadImage(_ urlString: String) async throws -> Data? {
        if urlString.hasPrefix("data:") {
            guard let comma = urlString.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(urlString[urlString.index(after: comma)...]), options: .ignoreUnknownCharacters)
        }
        guard let url = URL(string: urlString) else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

// MARK: - Wire format

private struct ResponseBody: Decodable {
    struct Item: Decodable {
        struct Content: Decodable {
            let text: String?
            let refusal: String?
        }
        let type: String
        let id: String?
        let status: String?
        let content: [Content]?
        let result: String?
        let revised_prompt: String?
        let size: String?
    }
    struct ErrorBody: Decodable {
        let message: String?
    }
    struct IncompleteDetails: Decodable {
        let reason: String?
    }
    let output: [Item]?
    let error: ErrorBody?
    let incomplete_details: IncompleteDetails?
}

private struct ChatChunk: Decodable {
    struct Choice: Decodable {
        let delta: Delta?
        let message: Delta?
    }
    struct ErrorBody: Decodable {
        let message: String?
    }
    let choices: [Choice]?
    let error: ErrorBody?
}

/// Tolerant decoder for both streaming deltas and full messages.
private struct Delta: Decodable {
    struct ContentPart: Decodable {
        struct ImageURL: Decodable { let url: String }
        let type: String?
        let text: String?
        let image_url: ImageURL?
    }

    var text: String?
    var imageURLs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case content, images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .content) {
            text = string
        } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
            text = parts.filter { $0.type == nil || $0.type == "text" }.compactMap(\.text).joined()
            imageURLs += parts.compactMap { $0.image_url?.url }
        }
        if let images = try? container.decode([ContentPart].self, forKey: .images) {
            imageURLs += images.compactMap { $0.image_url?.url }
        }
    }
}
