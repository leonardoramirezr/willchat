import SwiftUI

/// Leading space reserved for the window's traffic-light buttons.
let titleBarHeight: CGFloat = 40

/// App name above the sidebar; collapses to the app icon when only the rail is visible.
struct SidebarHeader: View {
    let expanded: Bool

    /// Full screen hides the traffic lights, so their reserved space isn't needed.
    @State private var isFullScreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }

    var body: some View {
        ZStack(alignment: .leading) {
            if expanded {
                Text("WillChat")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.leading, 16)
                    .transition(.opacity)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .frame(width: 60)
                    .transition(.opacity)
            }
        }
        .frame(height: 36)
        .padding(.top, isFullScreen ? 12 : titleBarHeight)
        // Update after the system's full-screen transition finishes; changes made during it
        // are hidden behind its snapshot crossfade and look like a jump.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            withAnimation(.smooth(duration: 0.35)) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.smooth(duration: 0.35)) { isFullScreen = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WillChat")
    }
}

struct SidebarRail: View {
    @Environment(ChatStore.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        VStack(spacing: 6) {
            RailButton(systemImage: "square.and.pencil", help: "Nuevo chat (⌘N)") {
                store.newChat()
                ui.focusComposer()
            }
            RailButton(systemImage: "magnifyingglass", help: "Buscar chats (⌘K)", isActive: ui.showSearch) {
                ui.showSearch.toggle()
            }
            RailButton(systemImage: "clock.arrow.circlepath", help: "Historial de chats (⌃⌘S)", isActive: ui.historyVisible) {
                ui.historyVisible.toggle()
            }

            Spacer()

            RailButton(systemImage: "gearshape", help: "Configuración (⌘,)", isActive: ui.showSettings) {
                ui.showSettings = true
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(width: 60)
        .frame(maxHeight: .infinity)
    }
}

struct RailButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(isActive ? 0.1 : (isHovering ? 0.06 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct HistoryPanel: View {
    @Environment(ChatStore.self) private var store
    @Environment(UIState.self) private var ui

    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chats")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 6)

            if store.conversations.isEmpty {
                ContentUnavailableView(
                    "Sin chats",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Tus conversaciones aparecerán aquí."))
                .frame(maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(ConversationGroup.grouped(store.conversations)) { group in
                        Section(group.title) {
                            ForEach(group.conversations) { conversation in
                                Text(conversation.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .tag(conversation.id)
                                    .contextMenu {
                                        Button("Renombrar…") {
                                            renameText = conversation.title
                                            renaming = conversation
                                        }
                                        Divider()
                                        Button("Eliminar", role: .destructive) { deleting = conversation }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .alert("Renombrar chat", isPresented: isPresented($renaming)) {
            TextField("Título", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") {
                if let renaming { store.rename(renaming.id, to: renameText) }
            }
        }
        .confirmationDialog(
            "¿Eliminar este chat?", isPresented: isPresented($deleting), presenting: deleting
        ) { conversation in
            Button("Eliminar", role: .destructive) { store.delete(conversation.id) }
        } message: { conversation in
            Text("Se eliminará “\(conversation.title)” de forma permanente.")
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { store.selectedID },
            set: { id in
                store.select(id)
                ui.focusComposer()
            })
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

struct SearchOverlay: View {
    @Environment(ChatStore.self) private var store
    @Environment(UIState.self) private var ui

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let results = store.search(query)
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Buscar chats…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isFieldFocused)
                        .onSubmit {
                            if let first = results.first { open(first.id) }
                        }
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if query.trimmed.isEmpty {
                            SearchRow(systemImage: "square.and.pencil", title: "Nuevo chat", snippet: nil, date: nil) {
                                store.newChat()
                                close()
                            }
                        }
                        ForEach(results) { result in
                            SearchRow(
                                systemImage: "bubble.left", title: result.title,
                                snippet: result.snippet, date: result.date
                            ) {
                                open(result.id)
                            }
                        }
                        if results.isEmpty && !query.trimmed.isEmpty {
                            Text("Sin resultados para “\(query.trimmed)”")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 600, height: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
        .onAppear { isFieldFocused = true }
    }

    private func open(_ id: UUID) {
        store.select(id)
        close()
    }

    private func close() {
        ui.showSearch = false
        ui.focusComposer()
    }
}

private struct SearchRow: View {
    let systemImage: String
    let title: String
    let snippet: String?
    let date: Date?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .lineLimit(1)
                    if let snippet {
                        Text(snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let date {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
