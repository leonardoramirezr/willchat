import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageRow: View {
    let message: ChatMessage
    var isLive = false
    var isGeneratingImage = false
    var onRetry: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Group {
            switch message.role {
            case .user: userBody
            case .assistant: assistantBody
            }
        }
        .onHover { isHovering = $0 }
    }

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer(minLength: 120)
                Text(message.content)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
            CopyButton(text: message.content)
                .opacity(isHovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(message.toolRounds.enumerated()), id: \.offset) { _, round in
                if !round.content.isEmpty {
                    MarkdownView(text: round.content)
                }
                ForEach(round.calls) { call in
                    ForEach(call.imageIDs, id: \.self) { id in
                        if let image = message.image(withID: id) {
                            GeneratedImageView(image: image)
                        }
                    }
                }
            }

            if isGeneratingImage {
                ImagePlaceholderView()
            }

            if !message.content.isEmpty {
                MarkdownView(text: message.content)
            }

            ForEach(message.inlineImages) { image in
                GeneratedImageView(image: image)
            }

            if isLive && message.content.isEmpty && !isGeneratingImage {
                TypingIndicator()
            }

            if let errorText = message.errorText {
                ErrorBanner(text: errorText, onRetry: onRetry)
            }

            if !isLive && !message.fullText.isEmpty {
                CopyButton(text: message.fullText)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copiar")
    }
}

private struct ErrorBanner: View {
    let text: String
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRetry {
                Button("Reintentar", action: onRetry)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25))
        )
    }
}

private struct TypingIndicator: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.primary)
            .frame(width: 11, height: 11)
            .scaleEffect(pulse ? 1 : 0.6)
            .opacity(pulse ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .padding(.vertical, 6)
    }
}

private struct ImagePlaceholderView: View {
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(pulse ? 0.09 : 0.04))
            .frame(width: 340, height: 340)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Creando imagen…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

struct GeneratedImageView: View {
    let image: StoredImage
    @State private var isHovering = false

    private static let maxSide: CGFloat = 440

    var body: some View {
        if let nsImage = ImageStore.nsImage(for: image) {
            let size = displaySize(for: nsImage.size)
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        Button(action: save) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Guardar imagen")
                        .padding(10)
                        .transition(.opacity)
                    }
                }
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .onTapGesture(count: 2) { NSWorkspace.shared.open(ImageStore.fileURL(for: image)) }
                .help(image.prompt ?? "")
                .contextMenu {
                    Button("Abrir en Vista Previa") { NSWorkspace.shared.open(ImageStore.fileURL(for: image)) }
                    Button("Copiar imagen") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([nsImage])
                    }
                    Button("Guardar como…", action: save)
                    if let prompt = image.prompt {
                        Divider()
                        Button("Copiar prompt") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                        }
                    }
                }
        } else {
            Label("Imagen no disponible", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }

    private func displaySize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: Self.maxSide, height: Self.maxSide) }
        let scale = min(Self.maxSide / size.width, Self.maxSide / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func save() {
        let source = ImageStore.fileURL(for: image)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "imagen.\(source.pathExtension)"
        if let type = UTType(filenameExtension: source.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }
}
