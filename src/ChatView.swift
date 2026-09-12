import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(UIState.self) private var ui

    @State private var draft = ""
    @State private var attachments: [DraftAttachment] = []
    @State private var attachmentError: String?
    @State private var isDropTargeted = false

    var body: some View {
        let conversation = store.selectedConversation
        let live = store.liveTurn(for: conversation?.id)
        let messages = conversation?.messages ?? []
        let isEmpty = messages.isEmpty && live == nil

        VStack(spacing: 0) {
            ChatTopBar()

            // The composer keeps its identity across both layouts, so it animates
            // from the center to the bottom without losing focus.
            if isEmpty {
                Spacer(minLength: 0)
                Text("¿En qué puedo ayudarte?")
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.bottom, 28)
                    .transition(.opacity)
            } else {
                MessagesView(conversationID: conversation?.id, messages: messages, live: live)
                    .transition(.opacity)
            }

            ComposerView(
                text: $draft,
                attachments: $attachments,
                isStreaming: store.isStreaming,
                focusToken: ui.composerFocusToken,
                onSend: submit,
                onStop: store.stop,
                onAttach: pickFiles,
                onPaste: paste
            )
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)

            if isEmpty {
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                    .frame(maxHeight: 60)
            } else {
                Text("WillChat puede cometer errores. Verifica la información importante.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        }
        .animation(.smooth(duration: 0.35), value: isEmpty)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: drop)
        .overlay {
            if isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onChange(of: ui.attachFilesToken) { pickFiles() }
        .alert(
            "No se pudo adjuntar",
            isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private func submit() {
        do {
            if try store.send(draft, attachments: attachments) {
                draft = ""
                attachments = []
            }
        } catch {
            attachmentError = "No se pudieron guardar los adjuntos. \(error.localizedDescription)"
        }
    }

    // MARK: Attachments

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Adjuntar"
        panel.message = "Elige imágenes o documentos para adjuntar al mensaje"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    private func addFiles(_ urls: [URL]) {
        addAttachments(urls.map { url in { try DraftAttachment.load(from: url) } })
    }

    private func addAttachments(_ loaders: [() throws -> DraftAttachment]) {
        var errors: [String] = []
        for load in loaders {
            guard attachments.count < DraftAttachment.maxCount else {
                errors.append("Puedes adjuntar hasta \(DraftAttachment.maxCount) archivos por mensaje.")
                break
            }
            do {
                attachments.append(try load())
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if !errors.isEmpty {
            attachmentError = ([attachmentError].compactMap { $0 } + errors).joined(separator: "\n")
        }
        ui.focusComposer()
    }

    /// Attaches copied files or images; returns `false` to let the text view paste text.
    private func paste(from pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            addFiles(urls)
            return true
        }
        // Text wins over images: apps like Word also put a picture of copied text on the pasteboard.
        if pasteboard.string(forType: .string) != nil { return false }
        guard let data = pasteboard.imageData else { return false }
        addAttachments([{ try DraftAttachment.image(data, name: "Imagen pegada") }])
        return true
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFiles([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // Images dragged from apps that don't provide a file, such as a browser.
                accepted = true
                let name = provider.suggestedName ?? "Imagen"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in addAttachments([{ try DraftAttachment.image(data, name: name) }]) }
                }
            }
        }
        return accepted
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(0.06))
            .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .overlay {
                Label("Suelta los archivos para adjuntarlos", systemImage: "paperclip")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

private struct ChatTopBar: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        @Bindable var settings = settings

        HStack(spacing: 8) {
            TopBarMenu {
                modelSection("Modelo de chat", options: settings.chatModelOptions, selection: settings.chatModel) {
                    settings.chatModel = $0
                }
                commonItems
            } label: {
                Text(settings.chatModel.isEmpty ? "Elegir modelo" : settings.chatModel)
                    .font(.system(size: 15, weight: .semibold))
            }

            TopBarMenu {
                Toggle("Generar imágenes", isOn: $settings.imageGenerationEnabled)
                Divider()
                modelSection("Modelo de imágenes", options: settings.imageModelOptions, selection: settings.imageModel) {
                    settings.imageModel = $0
                    settings.imageGenerationEnabled = true
                }
                commonItems
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "photo")
                    Text(settings.imageModel.isEmpty ? "Modelo de imágenes" : settings.imageModel)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(settings.imageGenerationEnabled ? .secondary : .tertiary)
            }
            .help(settings.imageGenerationEnabled ? "Modelo de imágenes" : "Generación de imágenes desactivada")

            if isRefreshing {
                ProgressView().controlSize(.small)
            } else if let refreshError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(refreshError)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .padding(.top, 6)
    }

    private func modelSection(
        _ title: String, options: [String], selection: String, select: @escaping (String) -> Void
    ) -> some View {
        Section(title) {
            ForEach(options, id: \.self) { model in
                Button {
                    select(model)
                } label: {
                    if model == selection {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var commonItems: some View {
        Divider()
        Button("Actualizar lista de modelos") { refresh() }
        Button("Configuración…") { ui.showSettings = true }
    }

    private func refresh() {
        isRefreshing = true
        refreshError = nil
        Task {
            do {
                try await settings.refreshModels()
            } catch {
                refreshError = error.localizedDescription
            }
            isRefreshing = false
        }
    }
}

/// A borderless top-bar menu: the label followed by a small chevron.
private struct TopBarMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                label
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.0001)))
    }
}

private struct MessagesView: View {
    @Environment(ChatStore.self) private var store

    let conversationID: UUID?
    let messages: [ChatMessage]
    let live: LiveTurn?

    @State private var isNearBottom = true
    @State private var pendingRegeneration: Regeneration?
    @State private var editingID: UUID?

    private struct Regeneration {
        let messageID: UUID
        var editedContent: String?
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(messages) { message in
                        let canRegenerate = message.role == .user && !store.isStreaming
                        MessageRow(
                            message: message,
                            onRetry: message.id == messages.last?.id && message.errorText != nil
                                ? { store.retryLastResponse() } : nil,
                            onRegenerate: canRegenerate
                                ? { regenerate(Regeneration(messageID: message.id)) } : nil,
                            onEdit: canRegenerate ? { editingID = message.id } : nil,
                            isEditing: editingID == message.id,
                            onCancelEdit: { editingID = nil },
                            onSubmitEdit: canRegenerate
                                ? { regenerate(Regeneration(messageID: message.id, editedContent: $0)) } : nil)
                    }
                    if let live {
                        MessageRow(message: live.message, isLive: true, isGeneratingImage: live.isGeneratingImage)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onChange(of: conversationID) {
                editingID = nil
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: live?.message.id) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: live?.message) {
                if isNearBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: live?.isGeneratingImage) {
                if isNearBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .confirmationDialog(
            "¿Regenerar la respuesta?",
            isPresented: Binding(get: { pendingRegeneration != nil }, set: { if !$0 { pendingRegeneration = nil } }),
            presenting: pendingRegeneration
        ) { regeneration in
            Button(regeneration.editedContent == nil ? "Regenerar" : "Enviar", role: .destructive) {
                perform(regeneration)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Se eliminarán los mensajes posteriores de esta conversación.")
        }
    }

    /// Replacing only the reply right after the message needs no confirmation;
    /// dropping later turns does.
    private func regenerate(_ regeneration: Regeneration) {
        guard let index = messages.firstIndex(where: { $0.id == regeneration.messageID }) else { return }
        if index + 2 < messages.count {
            pendingRegeneration = regeneration
        } else {
            perform(regeneration)
        }
    }

    private func perform(_ regeneration: Regeneration) {
        if regeneration.editedContent != nil { editingID = nil }
        store.regenerateResponse(to: regeneration.messageID, editedContent: regeneration.editedContent)
    }
}
