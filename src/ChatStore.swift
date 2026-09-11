import Foundation
import Observation

/// The assistant reply currently being streamed. Kept apart from `conversations`
/// so per-token updates don't invalidate views that only list conversations.
struct LiveTurn {
    var conversationID: UUID
    var message: ChatMessage
    var isGeneratingImage = false
}

@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    var selectedID: UUID?
    private(set) var live: LiveTurn?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let maxToolRounds = 5

    init(settings: AppSettings) {
        self.settings = settings
        conversations = Persistence.loadConversations().sorted { $0.updatedAt > $1.updatedAt }
    }

    var isStreaming: Bool { live != nil }

    var selectedConversation: Conversation? {
        guard let selectedID else { return nil }
        return conversation(selectedID)
    }

    func liveTurn(for conversationID: UUID?) -> LiveTurn? {
        guard let conversationID, let live, live.conversationID == conversationID else { return nil }
        return live
    }

    private func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    // MARK: Conversation management

    func newChat() {
        selectedID = nil
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmed
        guard !title.isEmpty else { return }
        mutate(id, touch: false) { $0.title = title }
    }

    func delete(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if live?.conversationID == id { stop() }
        ImageStore.delete(conversations[index].messages.flatMap(\.images))
        conversations.remove(at: index)
        Persistence.delete(id)
        if selectedID == id { selectedID = nil }
    }

    func deleteAll() {
        stop()
        for conversation in conversations { delete(conversation.id) }
    }

    private func mutate(_ id: UUID, touch: Bool = true, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conversation = conversations[index]
        change(&conversation)
        if touch {
            conversation.updatedAt = Date()
            conversations.remove(at: index)
            conversations.insert(conversation, at: 0)
        } else {
            conversations[index] = conversation
        }
        Persistence.save(conversation)
    }

    func search(_ query: String) -> [SearchResult] {
        let query = query.trimmed
        guard !query.isEmpty else {
            return conversations.prefix(30).map {
                SearchResult(id: $0.id, title: $0.title, snippet: nil, date: $0.updatedAt)
            }
        }
        return conversations.compactMap { conversation in
            if conversation.title.localizedStandardContains(query) {
                return SearchResult(id: conversation.id, title: conversation.title, snippet: nil, date: conversation.updatedAt)
            }
            for message in conversation.messages {
                let text = message.fullText
                if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                    return SearchResult(
                        id: conversation.id, title: conversation.title,
                        snippet: Self.snippet(text, around: range), date: conversation.updatedAt)
                }
            }
            return nil
        }
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    // MARK: Sending

    /// Returns `true` when the message was accepted (so the composer can be cleared).
    @discardableResult
    func send(_ rawText: String) -> Bool {
        let text = rawText.trimmed
        guard !text.isEmpty, !isStreaming else { return false }

        let conversationID: UUID
        if let selectedID, conversation(selectedID) != nil {
            conversationID = selectedID
        } else {
            let conversation = Conversation(title: Self.provisionalTitle(from: text))
            conversations.insert(conversation, at: 0)
            conversationID = conversation.id
            selectedID = conversation.id
        }
        mutate(conversationID) { $0.messages.append(ChatMessage(role: .user, content: text)) }
        startTurn(in: conversationID)
        return true
    }

    func stop() {
        task?.cancel()
    }

    /// Removes a failed assistant reply and asks again.
    func retryLastResponse() {
        guard !isStreaming, let id = selectedID, let last = conversation(id)?.messages.last,
              last.role == .assistant
        else { return }
        ImageStore.delete(last.images)
        mutate(id, touch: false) { $0.messages.removeLast() }
        startTurn(in: id)
    }

    private func startTurn(in conversationID: UUID) {
        live = LiveTurn(conversationID: conversationID, message: ChatMessage(role: .assistant, content: ""))
        task = Task { [weak self] in
            await self?.runTurn(conversationID: conversationID)
        }
    }

    private func runTurn(conversationID: UUID) async {
        guard var message = live?.message else { return }

        do {
            let client = try settings.makeClient()
            let useTools = settings.imageGenerationEnabled

            for _ in 0..<Self.maxToolRounds {
                try Task.checkCancellation()
                let body = try requestBody(for: conversationID, inProgress: message, useTools: useTools)
                var calls = ToolCallAccumulator()

                for try await event in client.streamChat(body: body) {
                    switch event {
                    case .content(let delta):
                        message.content += delta
                    case .toolCall(let index, let id, let name, let arguments):
                        calls.apply(index: index, id: id, name: name, arguments: arguments)
                    case .image(let url):
                        if let data = try? await OpenAIClient.downloadImage(url),
                           let stored = try? ImageStore.save(data, prompt: nil) {
                            message.images.append(stored)
                        }
                    }
                    live?.message = message
                }
                if Task.isCancelled || calls.isEmpty { break }

                // The model asked for tools: record the round, run them and loop.
                message.toolRounds.append(ToolRound(content: message.content, calls: calls.records()))
                message.content = ""
                live?.message = message

                let round = message.toolRounds.count - 1
                for index in message.toolRounds[round].calls.indices {
                    let call = message.toolRounds[round].calls[index]
                    let result = await executeTool(call, client: client, conversationID: conversationID, current: message)
                    message.toolRounds[round].calls[index].output = result.output
                    if let image = result.image {
                        message.images.append(image)
                        message.toolRounds[round].calls[index].imageIDs = [image.id]
                    }
                    live?.message = message
                }
            }
        } catch {
            if !Self.isCancellation(error) {
                message.errorText = error.localizedDescription
            }
        }

        // Every tool call needs a result, or the next request will be rejected.
        for round in message.toolRounds.indices {
            for call in message.toolRounds[round].calls.indices where message.toolRounds[round].calls[call].output.isEmpty {
                message.toolRounds[round].calls[call].output = "Cancelled by the user."
            }
        }

        live = nil
        task = nil
        if !message.fullText.isEmpty || !message.images.isEmpty || message.errorText != nil {
            mutate(conversationID) { $0.messages.append(message) }
        }
        await generateTitleIfNeeded(conversationID)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: Request building

    private func requestBody(for conversationID: UUID, inProgress: ChatMessage, useTools: Bool) throws -> Data {
        guard let conversation = conversation(conversationID) else { throw CancellationError() }
        let model = settings.chatModel.trimmed
        guard !model.isEmpty else {
            throw APIError.http(status: 0, message: "No hay un modelo configurado. Elige uno en Configuración.")
        }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt(useTools: useTools)]]
        var pendingImages: [StoredImage] = []

        for message in conversation.messages + [inProgress] {
            switch message.role {
            case .user:
                // Chat completions don't allow images in assistant messages, so images the
                // assistant produced travel with the next user message as vision input.
                let imageURLs = settings.sendImagesAsContext
                    ? pendingImages.compactMap { ImageStore.contextDataURL(for: $0) }
                    : []
                pendingImages.removeAll()
                if imageURLs.isEmpty {
                    messages.append(["role": "user", "content": message.content])
                } else {
                    var parts: [[String: Any]] = [[
                        "type": "text",
                        "text": "[Images you (the assistant) generated earlier in this conversation, attached for context]",
                    ]]
                    parts += imageURLs.map { ["type": "image_url", "image_url": ["url": $0]] }
                    parts.append(["type": "text", "text": message.content])
                    messages.append(["role": "user", "content": parts])
                }
            case .assistant:
                messages += apiMessages(forAssistant: message, useTools: useTools)
                pendingImages += message.images
            }
        }

        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if useTools { body["tools"] = [Self.imageTool] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func apiMessages(forAssistant message: ChatMessage, useTools: Bool) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if useTools {
            for round in message.toolRounds {
                result.append([
                    "role": "assistant",
                    "content": round.content.isEmpty ? NSNull() : round.content,
                    "tool_calls": round.calls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                    },
                ])
                for call in round.calls {
                    result.append(["role": "tool", "tool_call_id": call.id, "content": call.output])
                }
            }
            if !message.content.isEmpty {
                result.append(["role": "assistant", "content": message.content])
            }
        } else {
            // Tools are off: flatten earlier tool usage into plain text.
            var text = message.fullText
            let prompts = message.images.compactMap(\.prompt)
            if !prompts.isEmpty {
                text += "\n\n" + prompts.map { "[Generated image: \($0)]" }.joined(separator: "\n")
            }
            if !text.trimmed.isEmpty { result.append(["role": "assistant", "content": text]) }
        }
        return result
    }

    private func systemPrompt(useTools: Bool) -> String {
        let date = Date().formatted(date: .complete, time: .omitted)
        var prompt = """
        You are WillChat, a helpful assistant in a macOS chat app. Reply in the same language the user writes in. \
        Use Markdown when it improves readability. Current date: \(date).
        """
        if useTools {
            prompt += """


            You can create images with the `generate_image` tool. Call it whenever the user asks you to create, draw, \
            design, illustrate or modify an image, writing a detailed prompt. To change an image you already generated, \
            set `edit_previous_image` to true and describe the full desired result. Generated images are shown to the \
            user automatically: never include links or Markdown images for them, just add a brief comment.
            """
        }
        let custom = settings.customInstructions.trimmed
        if !custom.isEmpty {
            prompt += "\n\nCustom instructions from the user:\n\(custom)"
        }
        return prompt
    }

    private static var imageTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "generate_image",
                "description": "Generates an image from a text description and shows it to the user. Use it when the user asks for an image, drawing, illustration, logo, photo, etc., or wants to modify a previously generated image.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "Detailed description of the image to generate (subject, style, composition, colors, lighting).",
                        ],
                        "orientation": [
                            "type": "string",
                            "enum": ["square", "landscape", "portrait"],
                            "description": "Image aspect. Defaults to square.",
                        ],
                        "edit_previous_image": [
                            "type": "boolean",
                            "description": "true to modify the most recent image in this conversation instead of creating a new one from scratch.",
                        ],
                    ],
                    "required": ["prompt"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: Tools

    private func executeTool(
        _ call: ToolCallRecord, client: OpenAIClient, conversationID: UUID, current: ChatMessage
    ) async -> (output: String, image: StoredImage?) {
        guard call.name == "generate_image" else {
            return ("Error: unknown tool '\(call.name)'.", nil)
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        guard let prompt = (arguments["prompt"] as? String)?.trimmed, !prompt.isEmpty else {
            return ("Error: the 'prompt' argument is required.", nil)
        }
        let model = settings.imageModel.trimmed
        guard !model.isEmpty else {
            return ("Error: no image model is configured. Tell the user to set one in Settings.", nil)
        }
        let size = Self.imageSize(orientation: arguments["orientation"] as? String, model: model)
        let wantsEdit = arguments["edit_previous_image"] as? Bool ?? false

        live?.isGeneratingImage = true
        defer { live?.isGeneratingImage = false }

        do {
            var data: Data?
            if wantsEdit, let previous = latestImage(in: conversationID, current: current),
               let original = try? Data(contentsOf: ImageStore.fileURL(for: previous)) {
                // Not every provider supports edits; fall back to a fresh generation.
                data = try? await client.editImage(
                    model: model, prompt: prompt, image: original, filename: previous.filename,
                    mimeType: ImageStore.mimeType(for: previous), size: size)
            }
            try Task.checkCancellation()
            let imageData: Data
            if let data {
                imageData = data
            } else {
                imageData = try await client.generateImage(model: model, prompt: prompt, size: size)
            }
            let stored = try ImageStore.save(imageData, prompt: prompt)
            return ("The image was generated successfully and is already displayed to the user. Prompt used: \"\(prompt)\".", stored)
        } catch {
            if Self.isCancellation(error) { return ("Cancelled by the user.", nil) }
            return ("Error: the image could not be generated (\(error.localizedDescription)). Briefly tell the user.", nil)
        }
    }

    private func latestImage(in conversationID: UUID, current: ChatMessage) -> StoredImage? {
        if let image = current.images.last { return image }
        return conversation(conversationID)?.messages.reversed().lazy.compactMap(\.images.last).first
    }

    private static func imageSize(orientation: String?, model: String) -> String? {
        let model = model.lowercased()
        let isDallE3 = model.contains("dall-e-3")
        let isGPTImage = model.hasPrefix("gpt-image")
        guard isDallE3 || isGPTImage || model.contains("dall-e-2") else { return nil }
        switch orientation {
        case "landscape" where isDallE3: return "1792x1024"
        case "landscape" where isGPTImage: return "1536x1024"
        case "portrait" where isDallE3: return "1024x1792"
        case "portrait" where isGPTImage: return "1024x1536"
        default: return "1024x1024"
        }
    }

    // MARK: Titles

    private static func provisionalTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    private func generateTitleIfNeeded(_ id: UUID) async {
        guard let conversation = conversation(id), conversation.messages.count == 2,
              let question = conversation.messages.first, let answer = conversation.messages.last,
              answer.errorText == nil,
              let client = try? settings.makeClient()
        else { return }

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You write short titles for chat conversations. Reply with only the title: 2 to 6 words, in the same language as the user, no quotes, no final punctuation."],
            ["role": "user", "content": "User: \(question.content.prefix(1500))\n\nAssistant: \(answer.fullText.prefix(1500))"],
        ]
        let payload: [String: Any] = ["model": settings.chatModel, "messages": messages, "stream": false]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let raw = try? await client.complete(body: body)
        else { return }

        var title = raw
        if let thinkEnd = title.range(of: "</think>") { title = String(title[thinkEnd.upperBound...]) }
        title = title.trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»*#.").union(.whitespaces))
        guard !title.isEmpty else { return }
        mutate(id, touch: false) { $0.title = String(title.prefix(60)) }
    }
}

/// Assembles streamed tool-call fragments into complete calls.
private struct ToolCallAccumulator {
    private struct Partial {
        var id: String?
        var name = ""
        var arguments = ""
    }
    private var calls: [Partial] = []

    var isEmpty: Bool { calls.isEmpty }

    mutating func apply(index: Int?, id: String?, name: String?, arguments: String?) {
        let position: Int
        if let index {
            while calls.count <= index { calls.append(Partial()) }
            position = index
        } else if let id, !id.isEmpty {
            if let existing = calls.firstIndex(where: { $0.id == id }) {
                position = existing
            } else {
                calls.append(Partial())
                position = calls.count - 1
            }
        } else {
            if calls.isEmpty { calls.append(Partial()) }
            position = calls.count - 1
        }
        if let id, !id.isEmpty { calls[position].id = id }
        if let name, !name.isEmpty, calls[position].name.isEmpty { calls[position].name = name }
        if let arguments { calls[position].arguments += arguments }
    }

    func records() -> [ToolCallRecord] {
        calls.map { partial in
            ToolCallRecord(
                id: partial.id ?? "call_\(UUID().uuidString.prefix(12))",
                name: partial.name,
                arguments: partial.arguments.trimmed.isEmpty ? "{}" : partial.arguments)
        }
    }
}
