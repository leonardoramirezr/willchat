import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let baseURL = "baseURL"
        static let chatModel = "chatModel"
        static let imageModel = "imageModel"
        static let imageGenerationEnabled = "imageGenerationEnabled"
        static let sendImagesAsContext = "sendImagesAsContext"
        static let customInstructions = "customInstructions"
        static let availableModels = "availableModels"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let apiKeyAccount = "apiKey"
    }

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultImageModel = "gpt-image-1"

    private let defaults = UserDefaults.standard

    var baseURL: String { didSet { defaults.set(baseURL, forKey: Keys.baseURL) } }
    private(set) var apiKey: String
    var chatModel: String { didSet { defaults.set(chatModel, forKey: Keys.chatModel) } }
    var imageModel: String { didSet { defaults.set(imageModel, forKey: Keys.imageModel) } }
    var imageGenerationEnabled: Bool { didSet { defaults.set(imageGenerationEnabled, forKey: Keys.imageGenerationEnabled) } }
    var sendImagesAsContext: Bool { didSet { defaults.set(sendImagesAsContext, forKey: Keys.sendImagesAsContext) } }
    var customInstructions: String { didSet { defaults.set(customInstructions, forKey: Keys.customInstructions) } }
    var availableModels: [String] { didSet { defaults.set(availableModels, forKey: Keys.availableModels) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) } }

    init() {
        baseURL = defaults.string(forKey: Keys.baseURL) ?? Self.defaultBaseURL
        apiKey = Keychain.read(account: Keys.apiKeyAccount) ?? ""
        chatModel = defaults.string(forKey: Keys.chatModel) ?? ""
        imageModel = defaults.string(forKey: Keys.imageModel) ?? Self.defaultImageModel
        imageGenerationEnabled = defaults.object(forKey: Keys.imageGenerationEnabled) as? Bool ?? true
        sendImagesAsContext = defaults.object(forKey: Keys.sendImagesAsContext) as? Bool ?? true
        customInstructions = defaults.string(forKey: Keys.customInstructions) ?? ""
        availableModels = defaults.stringArray(forKey: Keys.availableModels) ?? []
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }

    func setAPIKey(_ key: String) {
        let key = key.trimmed
        guard key != apiKey else { return }
        apiKey = key
        if key.isEmpty {
            Keychain.delete(account: Keys.apiKeyAccount)
        } else {
            Keychain.save(key, account: Keys.apiKeyAccount)
        }
    }

    func makeClient() throws -> OpenAIClient {
        try Self.makeClient(baseURL: baseURL, apiKey: apiKey)
    }

    static func makeClient(baseURL: String, apiKey: String) throws -> OpenAIClient {
        guard let url = normalizedBaseURL(baseURL) else { throw APIError.invalidURL }
        return OpenAIClient(baseURL: url, apiKey: apiKey.trimmed)
    }

    /// Accepts things like `api.openai.com`, `https://host/v1/` or a full
    /// `.../chat/completions` or `.../responses` URL and returns the API base (e.g. `https://host/v1`).
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var string = raw.trimmed
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        for suffix in ["/chat/completions", "/completions", "/responses", "/models"] where string.hasSuffix(suffix) {
            string.removeLast(suffix.count)
        }
        guard var components = URLComponents(string: string), components.host != nil else { return nil }
        if components.path.isEmpty || components.path == "/" { components.path = "/v1" }
        return components.url
    }

    var chatModelOptions: [String] {
        var options = ModelFilter.chat(availableModels)
        if !chatModel.isEmpty && !options.contains(chatModel) { options.insert(chatModel, at: 0) }
        return options
    }

    var imageModelOptions: [String] {
        var options = ModelFilter.image(availableModels)
        if !imageModel.isEmpty && !options.contains(imageModel) { options.insert(imageModel, at: 0) }
        return options
    }

    func refreshModels() async throws {
        let models = try await makeClient().listModels()
        availableModels = models
    }
}

enum ModelFilter {
    private static let nonChatMarkers = [
        "embed", "whisper", "tts", "moderation", "dall-e", "gpt-image", "transcribe", "realtime",
        "davinci", "babbage", "sora",
    ]
    private static let imageMarkers = ["image", "dall-e", "flux", "stable-diffusion", "sdxl", "imagen"]

    static func chat(_ models: [String]) -> [String] {
        let filtered = models.filter { model in
            let lower = model.lowercased()
            return !nonChatMarkers.contains { lower.contains($0) }
        }
        return filtered.isEmpty ? models : filtered
    }

    static func image(_ models: [String]) -> [String] {
        let filtered = models.filter { model in
            let lower = model.lowercased()
            return imageMarkers.contains { lower.contains($0) }
        }
        return filtered.isEmpty ? models : filtered
    }

    static func suggestedChatModel(from models: [String]) -> String? {
        let chat = chat(models)
        for preferred in ["gpt-5", "gpt-4.1", "gpt-4o"] {
            if let match = chat.first(where: { $0 == preferred }) { return match }
        }
        return chat.first
    }

    static func suggestedImageModel(from models: [String]) -> String? {
        // The image_generation tool only accepts gpt-image models.
        models.first { $0.lowercased().hasPrefix("gpt-image") }
    }
}
