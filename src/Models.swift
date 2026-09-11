import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct StoredImage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var filename: String
    var prompt: String?
    /// Title the user gave an attached image, so they can refer to it by name.
    var title: String?
}

/// A document the user attached to a message; its text is sent to the model.
struct StoredFile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Name of the copy inside `Persistence.filesDirectory`.
    var filename: String
    /// Original file name, shown to the user and the model.
    var name: String
    var byteCount: Int
}

/// A tool call made by the model plus the result we sent back.
struct ToolCallRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var arguments: String
    var output: String = ""
    var imageIDs: [UUID] = []
}

/// An intermediate assistant message that ended with tool calls.
struct ToolRound: Codable, Hashable {
    var content: String
    var calls: [ToolCallRecord]
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: ChatRole
    /// User text, or the assistant's final answer (after any tool rounds).
    var content: String
    var toolRounds: [ToolRound] = []
    /// Images the assistant produced, or images the user attached.
    var images: [StoredImage] = []
    /// Documents the user attached.
    var files: [StoredFile] = []
    var errorText: String?
    var createdAt: Date = Date()

    var fullText: String {
        (toolRounds.map(\.content) + [content])
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Images the model returned directly in its message (not produced by a tool call).
    var inlineImages: [StoredImage] {
        let referenced = Set(toolRounds.flatMap { $0.calls.flatMap(\.imageIDs) })
        return images.filter { !referenced.contains($0.id) }
    }

    func image(withID id: UUID) -> StoredImage? {
        images.first { $0.id == id }
    }
}

extension ChatMessage {
    private enum CodingKeys: String, CodingKey {
        case id, role, content, toolRounds, images, files, errorText, createdAt
    }

    /// Tolerates fields added after a conversation was saved.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        toolRounds = try container.decodeIfPresent([ToolRound].self, forKey: .toolRounds) ?? []
        images = try container.decodeIfPresent([StoredImage].self, forKey: .images) ?? []
        files = try container.decodeIfPresent([StoredFile].self, forKey: .files) ?? []
        errorText = try container.decodeIfPresent(String.self, forKey: .errorText)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct ConversationGroup: Identifiable {
    let id: String
    let title: String
    let conversations: [Conversation]

    static func grouped(_ conversations: [Conversation], now: Date = Date()) -> [ConversationGroup] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        func daysAgo(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        }
        let buckets: [(String, (Int) -> Bool)] = [
            ("Hoy", { $0 <= 0 }),
            ("Ayer", { $0 == 1 }),
            ("Últimos 7 días", { (2...7).contains($0) }),
            ("Últimos 30 días", { (8...30).contains($0) }),
            ("Anteriores", { $0 > 30 }),
        ]
        return buckets.compactMap { title, matches in
            let items = conversations.filter { matches(daysAgo($0.updatedAt)) }
            return items.isEmpty ? nil : ConversationGroup(id: title, title: title, conversations: items)
        }
    }
}

struct SearchResult: Identifiable {
    let id: UUID
    let title: String
    let snippet: String?
    let date: Date
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Persistence {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "WillChat", directoryHint: .isDirectory)
    }()
    static let conversationsDirectory = root.appending(path: "Conversations", directoryHint: .isDirectory)
    static let imagesDirectory = root.appending(path: "Images", directoryHint: .isDirectory)
    static let filesDirectory = root.appending(path: "Files", directoryHint: .isDirectory)

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    private static func fileURL(for id: UUID) -> URL {
        conversationsDirectory.appending(path: "\(id.uuidString).json")
    }

    static func loadConversations() -> [Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: conversationsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Conversation.self, from: data)
            }
    }

    static func save(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        ensureDirectories()
        do {
            let data = try encoder.encode(conversation)
            try data.write(to: fileURL(for: conversation.id), options: .atomic)
        } catch {
            NSLog("WillChat: failed to save conversation: \(error)")
        }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}
