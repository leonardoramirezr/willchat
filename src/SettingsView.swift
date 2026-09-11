import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var chatModel = ""
    @State private var imageModel = ""
    @State private var imageGenerationEnabled = true
    @State private var sendImagesAsContext = true
    @State private var customInstructions = ""
    @State private var models: [String] = []
    @State private var connection = ConnectionTest.idle
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Configuración")
                .font(.headline)
                .padding(.top, 18)

            Form {
                Section {
                    TextField("URL base", text: $baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    SecureField("API key", text: $apiKey, prompt: Text("sk-…"))
                    HStack {
                        Button("Probar conexión", action: testConnection)
                            .disabled(connection == .testing)
                        ConnectionStatusView(state: connection)
                    }
                } header: {
                    Text("Conexión")
                } footer: {
                    Text("Compatible con cualquier API estilo OpenAI (OpenAI, OpenRouter, Ollama, LM Studio, vLLM…). La API key se guarda en el Llavero de macOS.")
                        .foregroundStyle(.secondary)
                }

                Section("Modelo") {
                    ModelField(title: "Modelo de chat", placeholder: "gpt-4o", model: $chatModel, options: ModelFilter.chat(models))
                }

                Section {
                    Toggle("Permitir que el modelo genere imágenes", isOn: $imageGenerationEnabled)
                    ModelField(title: "Modelo de imágenes", placeholder: AppSettings.defaultImageModel, model: $imageModel, options: ModelFilter.image(models))
                        .disabled(!imageGenerationEnabled)
                    Toggle("Enviar imágenes anteriores como contexto (visión)", isOn: $sendImagesAsContext)
                } header: {
                    Text("Imágenes")
                } footer: {
                    Text("El modelo de chat decide cuándo crear una imagen usando la herramienta generate_image, que llama a /images/generations. Desactiva la generación si tu proveedor no soporta herramientas.")
                        .foregroundStyle(.secondary)
                }

                Section("Instrucciones personalizadas") {
                    TextEditor(text: $customInstructions)
                        .font(.body)
                        .frame(minHeight: 70)
                }

                Section {
                    Button("Eliminar todos los chats…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(store.conversations.isEmpty)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(AppSettings.normalizedBaseURL(baseURL) == nil)
            }
            .padding(16)
        }
        .frame(width: 580, height: 680)
        .onAppear(perform: load)
        .confirmationDialog("¿Eliminar todos los chats?", isPresented: $confirmDeleteAll) {
            Button("Eliminar todo", role: .destructive) { store.deleteAll() }
        } message: {
            Text("Esta acción no se puede deshacer.")
        }
    }

    private func load() {
        baseURL = settings.baseURL
        apiKey = settings.apiKey
        chatModel = settings.chatModel
        imageModel = settings.imageModel
        imageGenerationEnabled = settings.imageGenerationEnabled
        sendImagesAsContext = settings.sendImagesAsContext
        customInstructions = settings.customInstructions
        models = settings.availableModels
    }

    private func save() {
        if let url = AppSettings.normalizedBaseURL(baseURL) { settings.baseURL = url.absoluteString }
        settings.setAPIKey(apiKey)
        settings.chatModel = chatModel.trimmed
        settings.imageModel = imageModel.trimmed
        settings.imageGenerationEnabled = imageGenerationEnabled
        settings.sendImagesAsContext = sendImagesAsContext
        settings.customInstructions = customInstructions
        if !models.isEmpty { settings.availableModels = models }
    }

    private func testConnection() {
        connection = .testing
        Task {
            do {
                let fetched = try await AppSettings.makeClient(baseURL: baseURL, apiKey: apiKey).listModels()
                models = fetched
                connection = .success(fetched.count)
            } catch {
                connection = .failure(error.localizedDescription)
            }
        }
    }
}

enum ConnectionTest: Equatable {
    case idle
    case testing
    case success(Int)
    case failure(String)
}

struct ConnectionStatusView: View {
    let state: ConnectionTest

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let count):
            Label("Conectado · \(count) modelos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// Free-form model name with a menu of the models reported by the server.
struct ModelField: View {
    let title: String
    let placeholder: String
    @Binding var model: String
    let options: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $model, prompt: Text(placeholder))
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { model = option }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Elegir de la lista de modelos")
            }
        }
    }
}
