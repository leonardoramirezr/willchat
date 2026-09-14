import Foundation
import Observation

/// The assistant reply currently being streamed. Kept apart from `conversations`
/// so per-token updates don't invalidate views that only list conversations.
struct LiveTurn {
    var conversationID: UUID
    var message: ChatMessage
}

@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    var selectedID: UUID?
    private(set) var live: LiveTurn?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var task: Task<Void, Never>?

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
        FileStore.delete(conversations[index].messages.flatMap(\.files))
        conversations.remove(at: index)
        Persistence.delete(id)
        if selectedID == id { selectedID = nil }
    }

    func deleteAll() {
        stop()
        for conversation in conversations { delete(conversation.id) }
    }

    /// Opens a new conversation holding the history before a user message and returns that
    /// message, so its text and attachments can be put back in the composer. When the message
    /// starts the conversation there's no history to copy, so this just starts a new chat.
    func fork(from messageID: UUID) -> ChatMessage? {
        guard let id = selectedID, let source = conversation(id),
              let index = source.messages.firstIndex(where: { $0.id == messageID }),
              source.messages[index].role == .user
        else { return nil }
        let prompt = source.messages[index]
        guard index > 0 else {
            selectedID = nil
            return prompt
        }

        // Each conversation owns its files (deleting one removes them), so the fork gets copies.
        var copiedImages: [StoredImage] = []
        var copiedFiles: [StoredFile] = []
        var history: [ChatMessage] = []
        for var message in source.messages[..<index] {
            var imageIDs: [UUID: UUID] = [:]
            message.id = UUID()
            message.images = message.images.compactMap { image in
                guard let copy = try? ImageStore.duplicate(image) else { return nil }
                imageIDs[image.id] = copy.id
                copiedImages.append(copy)
                return copy
            }
            message.files = message.files.compactMap { file in
                guard let copy = try? FileStore.duplicate(file) else { return nil }
                copiedFiles.append(copy)
                return copy
            }
            for round in message.toolRounds.indices {
                for call in message.toolRounds[round].calls.indices {
                    message.toolRounds[round].calls[call].imageIDs =
                        message.toolRounds[round].calls[call].imageIDs.compactMap { imageIDs[$0] }
                }
            }
            history.append(message)
        }

        let fork = Conversation(title: source.title, messages: history)
        conversations.insert(fork, at: 0)
        Persistence.save(fork)
        selectedID = fork.id
        return prompt
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
    /// Throws if an attachment can't be saved; nothing is sent in that case.
    @discardableResult
    func send(_ rawText: String, attachments: [DraftAttachment] = []) throws -> Bool {
        let text = rawText.trimmed
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming else { return false }

        var message = ChatMessage(role: .user, content: text)
        do {
            for attachment in attachments {
                switch attachment.kind {
                case .image:
                    message.images.append(try ImageStore.save(attachment.data, prompt: nil, title: attachment.trimmedTitle))
                case .document: message.files.append(try FileStore.save(attachment.data, name: attachment.name))
                }
            }
        } catch {
            ImageStore.delete(message.images)
            FileStore.delete(message.files)
            throw error
        }

        let conversationID: UUID
        if let selectedID, conversation(selectedID) != nil {
            conversationID = selectedID
        } else {
            let seed = text.isEmpty ? attachments.map { $0.trimmedTitle ?? $0.name }.joined(separator: ", ") : text
            let conversation = Conversation(title: Self.provisionalTitle(from: seed))
            conversations.insert(conversation, at: 0)
            conversationID = conversation.id
            selectedID = conversation.id
        }
        mutate(conversationID) { $0.messages.append(message) }
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

    /// Drops everything after a user message and answers it again with the current settings,
    /// replacing the message's text first when `editedContent` is given.
    func regenerateResponse(to messageID: UUID, editedContent: String? = nil) {
        guard !isStreaming, let id = selectedID, let messages = conversation(id)?.messages,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .user
        else { return }
        let content = editedContent?.trimmed ?? messages[index].content
        let message = messages[index]
        guard !content.isEmpty || !message.images.isEmpty || !message.files.isEmpty else { return }
        let removed = messages[(index + 1)...]
        ImageStore.delete(removed.flatMap(\.images))
        FileStore.delete(removed.flatMap(\.files))
        mutate(id, touch: false) {
            $0.messages[index].content = content
            $0.messages.removeSubrange((index + 1)...)
        }
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
        let log = RawLog()

        do {
            let client = try settings.makeClient()
            if settings.imageGenerationEnabled {
                // The built-in image tool only exists in the Responses API; it runs on the server.
                let body = try requestBody(for: conversationID, format: .responses)
                let items = try await client.createResponse(body: body, log: log)
                try Task.checkCancellation()
                apply(items, to: &message)
            } else {
                let body = try requestBody(for: conversationID, format: .chatCompletions)
                for try await event in client.streamChat(body: body, log: log) {
                    switch event {
                    case .content(let delta):
                        message.content += delta
                    case .image(let url):
                        if let data = try? await OpenAIClient.downloadImage(url),
                           let stored = try? ImageStore.save(data, prompt: nil) {
                            message.images.append(stored)
                        }
                    }
                    live?.message = message
                }
            }
        } catch {
            if !Self.isCancellation(error) {
                message.errorText = error.localizedDescription
            }
        }

        message.rawExchanges = log.exchanges

        live = nil
        task = nil
        if !message.fullText.isEmpty || !message.images.isEmpty || message.errorText != nil {
            mutate(conversationID) { $0.messages.append(message) }
        }
        await generateTitleIfNeeded(conversationID)
    }

    /// Stores a Responses API reply. Each image call becomes a tool round holding the text
    /// written before it, so the images show up in the order the model produced them.
    private func apply(_ items: [ResponseItem], to message: inout ChatMessage) {
        var failedImages = 0
        for item in items {
            switch item {
            case .text(let text):
                message.content += message.content.isEmpty ? text : "\n\n" + text
            case .image(let id, let status, let data, let revisedPrompt, let size):
                var call = ToolCallRecord(
                    id: id, name: "image_generation",
                    arguments: Self.imageCallArguments(revisedPrompt: revisedPrompt, size: size),
                    output: status)
                if let data, let stored = try? ImageStore.save(data, prompt: revisedPrompt) {
                    message.images.append(stored)
                    call.imageIDs = [stored.id]
                } else {
                    failedImages += 1
                }
                if message.content.isEmpty, let last = message.toolRounds.indices.last {
                    message.toolRounds[last].calls.append(call)
                } else {
                    message.toolRounds.append(ToolRound(content: message.content, calls: [call]))
                    message.content = ""
                }
            }
        }
        if failedImages > 0 {
            message.errorText = "No se pudo generar la imagen."
        }
    }

    private static func imageCallArguments(revisedPrompt: String?, size: String?) -> String {
        var arguments: [String: String] = [:]
        arguments["revised_prompt"] = revisedPrompt
        arguments["size"] = size
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: Request building

    private enum WireFormat {
        case chatCompletions, responses

        func textPart(_ text: String) -> [String: Any] {
            switch self {
            case .chatCompletions: ["type": "text", "text": text]
            case .responses: ["type": "input_text", "text": text]
            }
        }

        func imagePart(_ url: String) -> [String: Any] {
            switch self {
            case .chatCompletions: ["type": "image_url", "image_url": ["url": url]]
            case .responses: ["type": "input_image", "image_url": url]
            }
        }
    }

    private func requestBody(for conversationID: UUID, format: WireFormat) throws -> Data {
        guard let conversation = conversation(conversationID) else { throw CancellationError() }
        let model = settings.chatModel.trimmed
        guard !model.isEmpty else {
            throw APIError.http(status: 0, message: "No hay un modelo configurado. Elige uno en Configuración.")
        }

        let useTools = format == .responses
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt(useTools: useTools)]]
        var pendingImages: [StoredImage] = []

        for message in conversation.messages {
            switch message.role {
            case .user:
                var parts: [[String: Any]] = []
                // Neither API accepts images in assistant messages, so images the assistant
                // produced travel with the next user message as vision input. That is also
                // what lets the image tool edit them.
                let generatedURLs = settings.sendImagesAsContext
                    ? pendingImages.compactMap { ImageStore.contextDataURL(for: $0) }
                    : []
                pendingImages.removeAll()
                if !generatedURLs.isEmpty {
                    parts.append(format.textPart(
                        "[Images you (the assistant) generated earlier in this conversation, attached for context]"))
                    parts += generatedURLs.map(format.imagePart)
                }
                for image in message.images {
                    guard let url = ImageStore.contextDataURL(for: image, maxPixelSize: 2048) else { continue }
                    // The label right before the image is what ties its title to it.
                    if let title = image.title {
                        parts.append(format.textPart(Self.imageLabel(title)))
                    }
                    parts.append(format.imagePart(url))
                }

                let text = userText(for: message)
                if parts.isEmpty {
                    messages.append(["role": "user", "content": text])
                } else {
                    if !text.isEmpty { parts.append(format.textPart(text)) }
                    messages.append(["role": "user", "content": parts])
                }
            case .assistant:
                let text = assistantText(for: message)
                if !text.trimmed.isEmpty { messages.append(["role": "assistant", "content": text]) }
                pendingImages += message.images
            }
        }

        var body: [String: Any] = ["model": model, "stream": false]
        switch format {
        case .chatCompletions:
            body["messages"] = messages
        case .responses:
            body["input"] = messages
            var tool: [String: Any] = ["type": "image_generation"]
            let imageModel = settings.imageModel.trimmed
            if !imageModel.isEmpty { tool["model"] = imageModel }
            body["tools"] = [tool]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The user's text preceded by the contents of their attached documents.
    private func userText(for message: ChatMessage) -> String {
        let documents = message.files.map { file in
            let body = FileStore.text(for: file) ?? "[The file is no longer available]"
            return "<file name=\"\(file.name)\">\n\(body)\n</file>"
        }
        return (documents + [message.content]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func imageLabel(_ title: String) -> String {
        "[Image titled \"\(title)\"]"
    }

    /// The assistant's reply as plain text, noting the images it generated.
    private func assistantText(for message: ChatMessage) -> String {
        var text = message.fullText
        let prompts = message.images.compactMap(\.prompt)
        if !prompts.isEmpty {
            text += "\n\n" + prompts.map { "[Generated image: \($0)]" }.joined(separator: "\n")
        }
        return text
    }

    private func systemPrompt(useTools: Bool) -> String {
        let date = Date().formatted(date: .complete, time: .omitted)
        var prompt = """
        You are WillChat, a helpful assistant in a macOS chat app. Reply in the same language the user writes in. \
        Use Markdown when it improves readability. Current date: \(date). The user can attach images and files; \
        the contents of attached files appear in their message inside <file name="…"> tags. An attached image may be \
        preceded by a label like [Image titled "…"]: that title names the image right after it, and the user may \
        refer to the image by that title.
        """
        if useTools {
            prompt += """


            You can create and edit images with your image generation tool. Use it whenever the user asks you to \
            create, draw, design, illustrate or modify an image. Earlier images in the conversation (generated by you \
            or attached by the user) are included in the user's messages, so you can edit them; when the user names \
            a titled image, edit that one. Generated images are shown to the user automatically: never include links \
            or Markdown images for them, just add a brief comment.
            """
        }
        let custom = settings.customInstructions.trimmed
        if !custom.isEmpty {
            prompt += "\n\nCustom instructions from the user:\n\(custom)"
        }
        return prompt
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
            ["role": "user", "content": "User: \(Self.titleSource(for: question).prefix(1500))\n\nAssistant: \(answer.fullText.prefix(1500))"],
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

    private static func titleSource(for message: ChatMessage) -> String {
        var names = message.files.map { "[Attached file: \($0.name)]" }
        let titled = message.images.compactMap(\.title)
        names += titled.map { "[Attached image: \($0)]" }
        let untitled = message.images.count - titled.count
        if untitled > 0 { names.append("[\(untitled) attached image(s)]") }
        return (names + [message.content]).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
