import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(UIState.self) private var ui

    @State private var draft = ""

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
                isStreaming: store.isStreaming,
                focusToken: ui.composerFocusToken,
                onSend: submit,
                onStop: store.stop
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
    }

    private func submit() {
        if store.send(draft) {
            draft = ""
        }
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            onRetry: message.id == messages.last?.id && message.errorText != nil
                                ? { store.retryLastResponse() } : nil)
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
    }
}
