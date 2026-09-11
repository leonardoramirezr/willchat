import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageRow: View {
    let message: ChatMessage
    var isLive = false
    var isGeneratingImage = false
    var onRetry: (() -> Void)?
    /// User messages only; `nil` disables the button (e.g. while a reply is streaming).
    var onRegenerate: (() -> Void)?

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
            if !message.images.isEmpty || !message.files.isEmpty {
                TrailingFlowLayout(spacing: 8) {
                    ForEach(message.images) { image in
                        GeneratedImageView(image: image, maxSide: 240)
                    }
                    ForEach(message.files) { file in
                        StoredFileView(file: file)
                    }
                }
                .padding(.leading, 120)
            }
            if !message.content.isEmpty {
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
            }
            HStack(spacing: 0) {
                Button {
                    onRegenerate?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(onRegenerate == nil ? .tertiary : .secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onRegenerate == nil)
                .help("Regenerar respuesta con los modelos actuales")
                if !message.content.isEmpty {
                    CopyButton(text: message.content)
                }
            }
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

/// An attached document: file-type icon, name, type and size.
struct FileChip: View {
    let name: String
    let byteCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.vertical, 11)
        .padding(.leading, 11)
        .padding(.trailing, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .help(name)
    }

    private var fileExtension: String { (name as NSString).pathExtension }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return fileExtension.isEmpty ? size : "\(fileExtension.uppercased()) · \(size)"
    }

    private var style: (symbol: String, color: Color) {
        let type = UTType(filenameExtension: fileExtension)
        if type?.conforms(to: .pdf) == true { return ("doc.richtext.fill", .red) }
        if type?.conforms(to: .commaSeparatedText) == true || type?.conforms(to: .tabSeparatedText) == true {
            return ("tablecells.fill", .green)
        }
        if let type, [UTType.sourceCode, .json, .xml, .html, .yaml, .shellScript].contains(where: type.conforms(to:)) {
            return ("chevron.left.forwardslash.chevron.right", .purple)
        }
        return ("doc.text.fill", .blue)
    }
}

/// A document attached to a sent message; opens with the default app.
private struct StoredFileView: View {
    let file: StoredFile

    var body: some View {
        FileChip(name: file.name, byteCount: file.byteCount)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(FileStore.fileURL(for: file)) }
            .contextMenu {
                Button("Abrir") { NSWorkspace.shared.open(FileStore.fileURL(for: file)) }
                Button("Guardar como…", action: save)
            }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: FileStore.fileURL(for: file), to: destination)
    }
}

/// Lays out children in rows that wrap, aligned to the trailing edge.
private struct TrailingFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let rows = rows(for: subviews, maxWidth: available ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: available ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct GeneratedImageView: View {
    let image: StoredImage
    var maxSide: CGFloat = 440
    @State private var isHovering = false

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
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxSide, height: maxSide) }
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
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
