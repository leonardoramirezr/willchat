import AppKit
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let isStreaming: Bool
    let focusToken: Int
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var textHeight: CGFloat = ComposerTextView.lineHeight

    private var canSend: Bool { !text.trimmed.isEmpty && !isStreaming }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Pregunta lo que quieras")
                        .font(.system(size: ComposerTextView.fontSize))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, height: $textHeight, focusToken: focusToken, onSubmit: onSend)
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
        .padding(.leading, 20)
        .padding(.trailing, 9)
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
    }
}

/// Multi-line text input: Return sends, Shift/Option+Return inserts a new line,
/// and the view grows with its content up to `maxHeight`.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusToken: Int
    let onSubmit: () -> Void

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
    private var didRequestInitialFocus = false

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
