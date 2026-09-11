import AppKit
import SwiftUI

/// Opens the raw HTTP exchanges behind an assistant reply.
struct RawButton: View {
    let exchanges: [RawExchange]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "curlybraces")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ver la petición y la respuesta sin procesar")
        .sheet(isPresented: $isPresented) {
            RawExchangeSheet(exchanges: exchanges)
        }
    }
}

private struct RawExchangeSheet: View {
    let exchanges: [RawExchange]

    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var side = Side.request

    private enum Side: String, CaseIterable, Identifiable {
        case request = "Enviado"
        case response = "Recibido"
        var id: Self { self }
    }

    private var exchange: RawExchange? {
        exchanges.first { $0.id == selection } ?? exchanges.first
    }

    private var text: String {
        guard let exchange else { return "" }
        return side == .request ? exchange.requestText : exchange.responseText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            RawTextView(text: text)
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 420, idealHeight: 640)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Detalle de la API")
                    .font(.headline)
                if let exchange {
                    Text(exchange.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cerrar") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $side) {
                ForEach(Side.allCases) { side in
                    Text(side.rawValue).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if exchanges.count > 1 {
                Picker("", selection: Binding(get: { exchange?.id }, set: { selection = $0 })) {
                    ForEach(Array(exchanges.enumerated()), id: \.element.id) { index, exchange in
                        Text("\(index + 1). \(exchange.summary)").tag(Optional(exchange.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            } else if let exchange {
                Text(exchange.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            CopyButton(text: text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Read-only monospaced text; an NSTextView handles long dumps far better than `Text`.
private struct RawTextView: NSViewRepresentable {
    let text: String

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.font = Self.font
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.scroll(.zero)
    }
}
