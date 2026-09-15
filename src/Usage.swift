import Foundation
import Observation

/// Token counts, and cost when the provider reports it, summed over one or more requests.
struct TokenUsage: Codable, Hashable, Sendable {
    var requests = 0
    var inputTokens = 0
    /// Part of `inputTokens` read from the prompt cache.
    var cachedInputTokens = 0
    var outputTokens = 0
    /// Part of `outputTokens` spent on reasoning.
    var reasoningTokens = 0
    /// Only some providers (e.g. OpenRouter) report what a request cost.
    var cost: Double?

    var totalTokens: Int { inputTokens + outputTokens }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        var sum = lhs
        sum.requests += rhs.requests
        sum.inputTokens += rhs.inputTokens
        sum.cachedInputTokens += rhs.cachedInputTokens
        sum.outputTokens += rhs.outputTokens
        sum.reasoningTokens += rhs.reasoningTokens
        if let cost = rhs.cost { sum.cost = (lhs.cost ?? 0) + cost }
        return sum
    }
}

/// The usage an API response body reports.
struct ReportedUsage: Sendable {
    /// The model that answered, when the response names it.
    var model: String?
    var reply: TokenUsage?
    /// Tokens spent by the Responses API's `image_generation` tool, which doesn't name its model.
    var imageGeneration: TokenUsage?

    /// Reads `usage` (and `tool_usage.image_gen`) from a `/chat/completions`, `/responses` or
    /// `/images` body. A body without usage, or with one in an unexpected shape, yields nothing.
    init(parsing data: Data) {
        guard let body = try? JSONDecoder().decode(UsageEnvelope.self, from: data) else { return }
        model = body.model
        reply = body.usage?.tokenUsage
        imageGeneration = body.tool_usage?.image_gen?.tokenUsage
    }

    init() {}
}

private struct UsageEnvelope: Decodable {
    struct ToolUsage: Decodable {
        let image_gen: UsageBody?
    }
    let model: String?
    let usage: UsageBody?
    let tool_usage: ToolUsage?
}

/// Accepts both namings: `prompt_tokens`/`completion_tokens` (Chat Completions) and
/// `input_tokens`/`output_tokens` (Responses and Images).
private struct UsageBody: Decodable {
    let tokenUsage: TokenUsage?

    private enum CodingKeys: String, CodingKey {
        case prompt_tokens, completion_tokens, input_tokens, output_tokens, cost
        case prompt_tokens_details, completion_tokens_details, input_tokens_details, output_tokens_details
    }

    private struct Details: Decodable {
        let cached_tokens: Int?
        let reasoning_tokens: Int?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int? { try? container.decode(Int.self, forKey: key) }
        func details(_ key: CodingKeys) -> Details? { try? container.decode(Details.self, forKey: key) }

        var usage = TokenUsage(requests: 1)
        usage.inputTokens = int(.prompt_tokens) ?? int(.input_tokens) ?? 0
        usage.outputTokens = int(.completion_tokens) ?? int(.output_tokens) ?? 0
        usage.cachedInputTokens = (details(.prompt_tokens_details) ?? details(.input_tokens_details))?.cached_tokens ?? 0
        usage.reasoningTokens = (details(.completion_tokens_details) ?? details(.output_tokens_details))?.reasoning_tokens ?? 0
        usage.cost = try? container.decode(Double.self, forKey: .cost)
        tokenUsage = usage.totalTokens > 0 || (usage.cost ?? 0) > 0 ? usage : nil
    }
}

/// What one model used on one day.
struct DailyUsage: Codable, Hashable {
    /// Local calendar day, `yyyy-MM-dd`.
    var day: String
    var model: String
    var usage: TokenUsage
}

struct UsageDay: Identifiable {
    /// Start of the local day.
    let date: Date
    let usage: TokenUsage
    var id: Date { date }
}

struct ModelUsage: Identifiable {
    let model: String
    let usage: TokenUsage
    var id: String { model }
}

/// Tokens used through WillChat, per day and model. Kept apart from the chats, so deleting
/// or regenerating a conversation doesn't erase what it consumed.
@MainActor
@Observable
final class UsageStore {
    private(set) var entries: [DailyUsage] = []

    @ObservationIgnored private var needsImport = false

    private static let fileURL = Persistence.root.appending(path: "Usage.json")
    private static let unknownModel = "desconocido"

    private struct SavedFile: Codable {
        var entries: [DailyUsage]
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(SavedFile.self, from: data) {
            entries = saved.entries
        } else {
            needsImport = true
        }
    }

    /// Adds a response's usage. `imageModel` names the image tool's model, which responses omit.
    func record(_ reported: ReportedUsage, chatModel: String, imageModel: String?, at date: Date = Date()) {
        guard add(reported, chatModel: chatModel, imageModel: imageModel, at: date) else { return }
        save()
    }

    /// On first launch, rebuilds past usage from the API responses saved with each reply. Replies
    /// that were deleted, regenerated or retried are gone, and title requests were never saved,
    /// so the result can fall short of what was actually used.
    func importHistoryIfNeeded(from conversations: [Conversation]) {
        guard needsImport else { return }
        needsImport = false
        // Forked chats carry copies of the same exchanges.
        var seen = Set<UUID>()
        for exchange in conversations.flatMap({ $0.messages.flatMap(\.rawExchanges) })
        where (200..<300).contains(exchange.status) && seen.insert(exchange.id).inserted {
            let request = Self.requestedModels(in: exchange.requestBody)
            let fallback = request.model ?? (exchange.endpoint.hasPrefix("images/") ? "imágenes" : Self.unknownModel)
            add(ReportedUsage(parsing: Data(exchange.responseBody.utf8)),
                chatModel: fallback, imageModel: request.imageModel, at: exchange.date)
        }
        save()
    }

    @discardableResult
    private func add(_ reported: ReportedUsage, chatModel: String, imageModel: String?, at date: Date) -> Bool {
        let day = Self.dayKey(for: date)
        var added = false
        func insert(_ usage: TokenUsage?, model: String?) {
            guard let usage else { return }
            let model = [model, chatModel].compactMap { $0?.trimmed }.first { !$0.isEmpty } ?? Self.unknownModel
            if let index = entries.firstIndex(where: { $0.day == day && $0.model == model }) {
                entries[index].usage = entries[index].usage + usage
            } else {
                entries.append(DailyUsage(day: day, model: model, usage: usage))
            }
            added = true
        }
        insert(reported.reply, model: reported.model)
        insert(reported.imageGeneration, model: imageModel?.trimmed.isEmpty == false ? imageModel : "image_generation")
        return added
    }

    private func save() {
        Persistence.ensureDirectories()
        let sorted = entries.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        do {
            try JSONEncoder().encode(SavedFile(entries: sorted)).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("WillChat: failed to save usage: \(error)")
        }
    }

    /// The models named in a saved request, when its body is still valid JSON (long bodies are cut).
    private static func requestedModels(in body: String) -> (model: String?, imageModel: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return (nil, nil)
        }
        let tool = (object["tools"] as? [[String: Any]])?.first { $0["type"] as? String == "image_generation" }
        return (object["model"] as? String, tool?["model"] as? String)
    }

    // MARK: Queries

    /// The last `count` days, oldest first and ending today, each summed over every model.
    func days(last count: Int, now: Date = Date()) -> [UsageDay] {
        var totals: [String: TokenUsage] = [:]
        for entry in entries {
            totals[entry.day] = (totals[entry.day] ?? TokenUsage()) + entry.usage
        }
        return Self.dates(last: count, now: now).map { date in
            UsageDay(date: date, usage: totals[Self.dayKey(for: date)] ?? TokenUsage())
        }
    }

    /// Usage per model over the last `count` days, most tokens first.
    func models(last count: Int, now: Date = Date()) -> [ModelUsage] {
        let dates = Self.dates(last: count, now: now)
        guard let first = dates.first.map({ Self.dayKey(for: $0) }), let last = dates.last.map({ Self.dayKey(for: $0) })
        else { return [] }
        var totals: [String: TokenUsage] = [:]
        for entry in entries where (first...last).contains(entry.day) {
            totals[entry.model] = (totals[entry.model] ?? TokenUsage()) + entry.usage
        }
        return totals
            .map { ModelUsage(model: $0.key, usage: $0.value) }
            .sorted { ($0.usage.totalTokens, $1.model) > ($1.usage.totalTokens, $0.model) }
    }

    // MARK: Days

    /// Gregorian, so day keys stay `yyyy-MM-dd` whatever calendar the user prefers.
    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    private static func dates(last count: Int, now: Date) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(count, 0)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    static func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
