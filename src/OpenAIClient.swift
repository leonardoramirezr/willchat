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
    case toolCall(index: Int?, id: String?, name: String?, arguments: String?)
    /// An image returned inline by the model (data: URL or http URL).
    case image(String)
}

/// Minimal client for OpenAI-compatible APIs (`/models`, `/chat/completions`, `/images/*`).
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

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: Self.errorMessage(from: data, status: status))
        }
        return data
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

    func streamChat(body: Data) -> AsyncThrowingStream<StreamEvent, Error> {
        let request = makeRequest("chat/completions", method: "POST", body: body, timeout: 600)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw APIError.http(status: status, message: Self.errorMessage(from: data, status: status))
                    }

                    // Some servers ignore `stream: true` and answer with a single JSON body.
                    let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                    if contentType.contains("application/json") {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                        try Self.emit(chunk, to: continuation)
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data)
                        else { continue }
                        try Self.emit(chunk, to: continuation)
                    }
                    continuation.finish()
                } catch {
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
            for (position, call) in delta.toolCalls.enumerated() {
                continuation.yield(.toolCall(
                    index: call.index ?? (delta.toolCalls.count > 1 ? position : nil),
                    id: call.id,
                    name: call.function?.name,
                    arguments: call.function?.arguments))
            }
            for url in delta.imageURLs { continuation.yield(.image(url)) }
        }
    }

    /// Non-streaming completion that returns only the text (used for titles).
    func complete(body: Data) async throws -> String {
        let data = try await perform(makeRequest("chat/completions", method: "POST", body: body, timeout: 120))
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
        return chunk.choices?.first?.message?.text ?? ""
    }

    // MARK: Images

    private static func sendsResponseFormat(_ model: String) -> Bool {
        // gpt-image models always return base64 and reject `response_format`.
        !model.lowercased().hasPrefix("gpt-image")
    }

    func generateImage(model: String, prompt: String, size: String?) async throws -> Data {
        var body: [String: Any] = ["model": model, "prompt": prompt, "n": 1]
        if let size { body["size"] = size }
        if Self.sendsResponseFormat(model) { body["response_format"] = "b64_json" }
        let request = makeRequest(
            "images/generations", method: "POST",
            body: try JSONSerialization.data(withJSONObject: body), timeout: 300)
        return try await Self.imageData(from: try await perform(request))
    }

    func editImage(model: String, prompt: String, image: Data, filename: String, mimeType: String, size: String?) async throws -> Data {
        let boundary = "WillChat-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("prompt", prompt)
        field("n", "1")
        if let size { field("size", size) }
        if Self.sendsResponseFormat(model) { field("response_format", "b64_json") }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let request = makeRequest(
            "images/edits", method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)", timeout: 300)
        return try await Self.imageData(from: try await perform(request))
    }

    private static func imageData(from data: Data) async throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]],
              let first = items.first
        else { throw APIError.invalidResponse("La API de imágenes no devolvió ninguna imagen.") }

        if let b64 = first["b64_json"] as? String,
           let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            return decoded
        }
        if let urlString = first["url"] as? String, let decoded = try await downloadImage(urlString) {
            return decoded
        }
        throw APIError.invalidResponse("Formato de imagen no soportado.")
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
    struct ToolCallDelta: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        let index: Int?
        let id: String?
        let function: Function?
    }

    var text: String?
    var toolCalls: [ToolCallDelta] = []
    var imageURLs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case content, tool_calls, images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .content) {
            text = string
        } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
            text = parts.filter { $0.type == nil || $0.type == "text" }.compactMap(\.text).joined()
            imageURLs += parts.compactMap { $0.image_url?.url }
        }
        toolCalls = (try? container.decode([ToolCallDelta].self, forKey: .tool_calls)) ?? []
        if let images = try? container.decode([ContentPart].self, forKey: .images) {
            imageURLs += images.compactMap { $0.image_url?.url }
        }
    }
}
