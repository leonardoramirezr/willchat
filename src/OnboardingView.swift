import SwiftUI

/// First-launch flow: welcome → connection (URL + API key) → model selection.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings

    private enum Step: Int, CaseIterable {
        case welcome, connection, model
    }

    private struct Preset: Identifiable {
        let name: String
        let url: String
        var id: String { name }
    }

    private static let presets = [
        Preset(name: "OpenAI", url: "https://api.openai.com/v1"),
        Preset(name: "OpenRouter", url: "https://openrouter.ai/api/v1"),
        Preset(name: "Ollama", url: "http://localhost:11434/v1"),
        Preset(name: "LM Studio", url: "http://localhost:1234/v1"),
    ]

    @State private var step = Step.welcome
    @State private var baseURL = AppSettings.defaultBaseURL
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var chatModel = ""
    @State private var imageModel = AppSettings.defaultImageModel
    @State private var imageGenerationEnabled = true
    @State private var connection = ConnectionTest.idle

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            Group {
                switch step {
                case .welcome: welcome
                case .connection: connectionStep
                case .model: modelStep
                }
            }
            .frame(maxWidth: 440)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            Spacer(minLength: 40)

            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: item == step ? 18 : 7, height: 7)
                }
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.smooth(duration: 0.35), value: step)
        .onAppear {
            baseURL = settings.baseURL
            apiKey = settings.apiKey
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .padding(.bottom, 6)
            Text("Te damos la bienvenida a WillChat")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Chatea con cualquier modelo que ofrezca una API compatible con OpenAI: OpenAI, OpenRouter, Ollama, LM Studio y más. Primero, conectemos tu proveedor.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Comenzar") { step = .connection }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                title: "Conecta tu API",
                subtitle: "Solo se admiten APIs compatibles con OpenAI (endpoint /chat/completions).")

            VStack(alignment: .leading, spacing: 8) {
                Text("Proveedor").font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    ForEach(Self.presets) { preset in
                        Button(preset.name) {
                            baseURL = preset.url
                            connection = .idle
                        }
                        .buttonStyle(.bordered)
                        .tint(AppSettings.normalizedBaseURL(baseURL)?.absoluteString == preset.url ? .accentColor : nil)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL base").font(.callout.weight(.medium))
                TextField("", text: $baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API key").font(.callout.weight(.medium))
                SecureField("", text: $apiKey, prompt: Text("sk-…"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                Text("Se guarda en el Llavero de macOS. Puedes dejarla vacía para servidores locales.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ConnectionStatusView(state: connection)

            HStack {
                Button("Atrás") { step = .welcome }
                    .controlSize(.large)
                Spacer()
                if case .failure = connection {
                    Button("Continuar sin verificar") { goToModelStep(with: []) }
                        .controlSize(.large)
                }
                Button(action: verifyConnection) {
                    if connection == .testing {
                        ProgressView().controlSize(.small).frame(width: 90)
                    } else {
                        Text("Verificar y continuar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(connection == .testing || AppSettings.normalizedBaseURL(baseURL) == nil)
            }
            .padding(.top, 4)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                title: "Elige un modelo",
                subtitle: models.isEmpty
                    ? "No pudimos obtener la lista de modelos; escribe el nombre manualmente."
                    : "Encontramos \(models.count) modelos en tu proveedor.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Modelo de chat").font(.callout.weight(.medium))
                ModelField(title: "", placeholder: "gpt-4o", model: $chatModel, options: ModelFilter.chat(models))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Permitir que el modelo genere imágenes", isOn: $imageGenerationEnabled)
                if imageGenerationEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Modelo de imágenes").font(.callout.weight(.medium))
                        ModelField(title: "", placeholder: AppSettings.defaultImageModel, model: $imageModel, options: ModelFilter.image(models))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                        Text("Cuando pidas una imagen, el modelo de chat la solicitará a /images/generations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Atrás") { step = .connection }
                    .controlSize(.large)
                Spacer()
                Button("Empezar a chatear", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chatModel.trimmed.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func verifyConnection() {
        connection = .testing
        Task {
            do {
                let fetched = try await AppSettings.makeClient(baseURL: baseURL, apiKey: apiKey).listModels()
                connection = .success(fetched.count)
                goToModelStep(with: fetched)
            } catch {
                connection = .failure(error.localizedDescription)
            }
        }
    }

    private func goToModelStep(with fetched: [String]) {
        models = fetched
        if chatModel.isEmpty {
            chatModel = ModelFilter.suggestedChatModel(from: fetched) ?? ""
        }
        if let suggested = ModelFilter.suggestedImageModel(from: fetched) {
            imageModel = suggested
        }
        step = .model
    }

    private func finish() {
        if let url = AppSettings.normalizedBaseURL(baseURL) { settings.baseURL = url.absoluteString }
        settings.setAPIKey(apiKey)
        settings.chatModel = chatModel.trimmed
        settings.imageModel = imageModel.trimmed
        settings.imageGenerationEnabled = imageGenerationEnabled
        settings.availableModels = models
        settings.hasCompletedOnboarding = true
    }
}
