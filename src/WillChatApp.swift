import SwiftUI

@main
struct WillChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var store: ChatStore
    @State private var ui = UIState()

    init() {
        Persistence.ensureDirectories()
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _store = State(initialValue: ChatStore(settings: settings))
    }

    var body: some Scene {
        Window("WillChat", id: "main") {
            RootView()
                .environment(settings)
                .environment(store)
                .environment(ui)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuevo chat") {
                    store.newChat()
                    ui.showSearch = false
                    ui.focusComposer()
                }
                .keyboardShortcut("n")
                .disabled(!settings.hasCompletedOnboarding)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Configuración…") { ui.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(!settings.hasCompletedOnboarding)
            }
            CommandMenu("Chat") {
                Button("Buscar chats") { ui.showSearch.toggle() }
                    .keyboardShortcut("k")
                Button(ui.historyVisible ? "Ocultar historial" : "Mostrar historial") {
                    ui.historyVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("Detener respuesta") { store.stop() }
                    .keyboardShortcut(".")
                    .disabled(!store.isStreaming)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Window-level UI state shared between views and menu commands.
@MainActor
@Observable
final class UIState {
    var showSettings = false
    var showSearch = false
    var historyVisible: Bool = UserDefaults.standard.object(forKey: "historyVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(historyVisible, forKey: "historyVisible") }
    }
    private(set) var composerFocusToken = 0

    func focusComposer() {
        composerFocusToken += 1
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                MainView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: settings.hasCompletedOnboarding)
        .ignoresSafeArea()
    }
}

struct MainView: View {
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarRail()
                if ui.historyVisible {
                    HistoryPanel()
                        .frame(width: 250)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .background(VisualEffectBackground(material: .sidebar))
            .clipped()

            Divider()

            ChatView()
                .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            if ui.showSearch {
                SearchOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: ui.historyVisible)
        .animation(.easeOut(duration: 0.15), value: ui.showSearch)
        .sheet(isPresented: $ui.showSettings) {
            SettingsView()
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
