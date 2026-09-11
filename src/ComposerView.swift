import AppKit
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [DraftAttachment]
    let isStreaming: Bool
    let focusToken: Int
    let onSend: () -> Void
    let onStop: () -> Void
    let onAttach: () -> Void
    /// Returns `true` when the pasteboard held files or images that were attached.
    let onPaste: (NSPasteboard) -> Bool

    @State private var textHeight: CGFloat = ComposerTextView.lineHeight

    private var canSend: Bool { (!text.trimmed.isEmpty || !attachments.isEmpty) && !isStreaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach($attachments) { $attachment in
                            DraftAttachmentView(attachment: $attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    // Room for the remove buttons, which stick out of each corner.
                    .padding(.top, 6)
                    .padding(.horizontal, 6)
                }
                .transition(.opacity)
            }
            inputRow
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .animation(.easeOut(duration: 0.12), value: textHeight)
        .animation(.easeOut(duration: 0.15), value: attachments.map(\.id))
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Adjuntar archivos (⌘U)")

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Pregunta lo que quieras")
                        .font(.system(size: ComposerTextView.fontSize))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $text, height: $textHeight, focusToken: focusToken,
                    onSubmit: onSend, onPaste: onPaste)
                    .frame(height: textHeight)
            }
            .padding(.vertical, 7)

            Button {
                isStreaming ? onStop() : onSend()
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: isStreaming ? 11 : 15, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(canSend || isStreaming ? 1 : 0.2)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !isStreaming)
            .help(isStreaming ? "Detener (⌘.)" : "Enviar (↩︎)")
        }
    }
}

/// A pending attachment in the composer, with a button to remove it. Images
/// also get a title field so the prompt can refer to them by name.
private struct DraftAttachmentView: View {
    @Binding var attachment: DraftAttachment
    let onRemove: () -> Void

    @Environment(UIState.self) private var ui

    var body: some View {
        Group {
            if let preview = attachment.preview {
                HStack(spacing: 10) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help(attachment.name)
                    TextField("Añadir título", text: $attachment.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 130)
                        .onSubmit { ui.focusComposer() }
                        .help("Título para referirte a esta imagen en el mensaje")
                }
                .padding(6)
                .padding(.trailing, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
            } else {
                FileChip(name: attachment.name, byteCount: attachment.data.count)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.75)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Quitar")
            .offset(x: 6, y: -6)
        }
    }
}

/// Multi-line text input: Return sends, Shift/Option+Return inserts a new line,
/// and the view grows with its content up to `maxHeight`.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusToken: Int
    let onSubmit: () -> Void
    let onPaste: (NSPasteboard) -> Bool

    static let fontSize: CGFloat = 15
    static let font = NSFont.systemFont(ofSize: fontSize)
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
    static let maxHeight: CGFloat = 220

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.recalculateHeight() }
        textView.onPaste = { [weak coordinator = context.coordinator] pasteboard in
            coordinator?.parent.onPaste(pasteboard) ?? false
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.lastFocusToken = focusToken
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            coordinator.recalculateHeight()
        }
        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocusToken = 0

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func recalculateHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = ceil(layoutManager.usedRect(for: container).height)
            let newHeight = min(max(used, ComposerTextView.lineHeight), ComposerTextView.maxHeight)
            if abs(newHeight - parent.height) > 0.5 {
                DispatchQueue.main.async { [parent] in
                    parent.height = newHeight
                }
            }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onWidthChange: (() -> Void)?
    var onPaste: ((NSPasteboard) -> Bool)?
    private var didRequestInitialFocus = false

    /// Accept only dropped text, leaving files and images to the chat view (which
    /// attaches them) instead of inserting their paths here.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func paste(_ sender: Any?) {
        if onPaste?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    /// A plain-text view only enables Paste for text and files, so ⌘V would never
    /// reach `paste(_:)` with just an image (e.g. a screenshot) on the pasteboard.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, NSPasteboard.general.hasImage { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didRequestInitialFocus, let window else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) > 0.5 { onWidthChange?() }
    }
}
