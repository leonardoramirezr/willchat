import AppKit
import Charts
import SwiftUI

enum UsagePeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { "\(rawValue) días" }
}

/// Spending reported by the provider's API plus the tokens WillChat recorded, per day.
struct UsageView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("usagePeriod") private var period = UsagePeriod.week
    @State private var refreshToken = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    SpendSection(period: period, refreshToken: refreshToken)
                    TokensSection(period: period)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 760)
    }

    /// The period applies to every section below it.
    private var header: some View {
        HStack(spacing: 12) {
            Text("Consumo")
                .font(.headline)
            Spacer()
            Picker("Periodo", selection: $period) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                refreshToken += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Volver a consultar el gasto")
            Button("Cerrar") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Spending

private struct SpendSection: View {
    @Environment(AppSettings.self) private var settings
    let period: UsagePeriod
    let refreshToken: Int

    var body: some View {
        switch settings.billingProvider {
        case .openAI:
            OpenAISpendView(period: period, refreshToken: refreshToken)
        case .openRouter:
            OpenRouterSpendView(refreshToken: refreshToken)
        case .other:
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Gasto", subtitle: "Consultado a la API de tu proveedor.")
                Label(
                    "WillChat puede consultar el gasto de OpenAI (con una Admin key) y de OpenRouter. Tu proveedor no ofrece una API compatible; si informa el costo de cada respuesta, aparecerá en la sección de tokens.",
                    systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .usageCard()
            }
        }
    }
}

private struct OpenAISpendView: View {
    @Environment(AppSettings.self) private var settings
    let period: UsagePeriod
    let refreshToken: Int

    @State private var costs: [DailyCost]?
    @State private var loadedDays = 0
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isEditingKey = false

    private struct LoadID: Equatable {
        let days: Int
        let key: String
        let refresh: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Gasto en OpenAI",
                subtitle: "De toda la organización, según la API de costes de OpenAI, en días UTC. Lo más reciente puede tardar en aparecer.")

            if settings.openAIAdminKey.isEmpty || isEditingKey {
                AdminKeyForm(onCancel: settings.openAIAdminKey.isEmpty ? nil : { isEditingKey = false }) {
                    isEditingKey = false
                }
            } else {
                content
                keyFooter
            }
        }
        .task(id: LoadID(days: period.days, key: settings.openAIAdminKey, refresh: refreshToken)) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            SpendError(
                message: errorText,
                hint: "La API de costes solo acepta Admin keys de la organización (empiezan por sk-admin-).",
                onRetry: { Task { await load() } })
        } else if let costs {
            let days = CostDay.days(from: costs, count: loadedDays)
            let lineItems = LineItemCost.items(from: costs)
            let currency = costs.first?.currency ?? "usd"
            let total = days.reduce(0) { $0 + $1.amount }
            VStack(alignment: .leading, spacing: 14) {
                StatRow {
                    StatTile(label: "Hoy (UTC)", value: UsageFormat.money(days.last?.amount ?? 0, currency: currency))
                    StatTile(label: "Últimos \(loadedDays) días", value: UsageFormat.money(total, currency: currency))
                    StatTile(
                        label: "Promedio diario",
                        value: UsageFormat.money(total / Double(max(loadedDays, 1)), currency: currency))
                }
                CostChart(days: days, currency: currency)
                    .frame(height: 200)
                    .padding(16)
                    .usageCard()
                if !lineItems.isEmpty {
                    LineItemTable(items: lineItems, currency: currency)
                }
            }
            // Refetching keeps the previous numbers on screen instead of flashing a spinner.
            .opacity(isLoading ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: isLoading)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var keyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
            Text("Admin key \(Self.masked(settings.openAIAdminKey)), guardada en el Llavero")
            Spacer()
            Button("Cambiar…") { isEditingKey = true }
            Button("Quitar") {
                settings.setOpenAIAdminKey("")
                costs = nil
                errorText = nil
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }

    private func load() async {
        guard !settings.openAIAdminKey.isEmpty else { return }
        let days = period.days
        isLoading = true
        do {
            let result = try await settings.makeAdminClient().organizationCosts(days: days)
            guard !Task.isCancelled else { return }
            costs = result
            loadedDays = days
            errorText = nil
        } catch {
            // A newer load replaced this one; it owns `isLoading` now.
            guard !Task.isCancelled, !UsageFormat.isCancellation(error) else { return }
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private static func masked(_ key: String) -> String {
        key.count > 16 ? "\(key.prefix(9))…\(key.suffix(4))" : "••••"
    }
}

private struct AdminKeyForm: View {
    @Environment(AppSettings.self) private var settings
    var onCancel: (() -> Void)?
    let onSave: () -> Void

    @State private var draft = ""

    private static let adminKeysURL = URL(string: "https://platform.openai.com/settings/organization/admin-keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Añade una Admin key para ver el gasto", systemImage: "key.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("OpenAI no deja que las API keys normales consulten costes. Crea una Admin key en la configuración de tu organización y pégala aquí: se guarda en el Llavero de macOS y solo se usa para leer el gasto.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Admin key", text: $draft, prompt: Text("sk-admin-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(save)
                if let onCancel {
                    Button("Cancelar", action: onCancel)
                }
                Button("Guardar", action: save)
                    .disabled(draft.trimmed.isEmpty)
            }
            Link("Crear una Admin key en platform.openai.com", destination: Self.adminKeysURL)
                .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usageCard()
    }

    private func save() {
        guard !draft.trimmed.isEmpty else { return }
        settings.setOpenAIAdminKey(draft)
        onSave()
    }
}

private struct OpenRouterSpendView: View {
    @Environment(AppSettings.self) private var settings
    let refreshToken: Int

    @State private var spend: OpenRouterSpend?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Gasto en OpenRouter",
                subtitle: "Créditos (USD) gastados con tu API key, según OpenRouter; el día, la semana y el mes son UTC. El costo de cada día aparece en la sección de tokens.")

            if let errorText {
                SpendError(message: errorText, onRetry: { Task { await load() } })
            } else if let spend {
                VStack(spacing: 12) {
                    StatRow {
                        StatTile(label: "Hoy (UTC)", value: UsageFormat.money(spend.today ?? 0))
                        StatTile(label: "Esta semana", value: UsageFormat.money(spend.thisWeek ?? 0))
                        StatTile(label: "Este mes", value: UsageFormat.money(spend.thisMonth ?? 0))
                    }
                    StatRow {
                        if let balance = spend.balance {
                            StatTile(label: "Saldo de la cuenta", value: UsageFormat.money(balance))
                        }
                        if let remaining = spend.limitRemaining {
                            StatTile(
                                label: "Límite restante de la key", value: UsageFormat.money(remaining),
                                detail: spend.limit.map { "de \(UsageFormat.money($0))" })
                        }
                        StatTile(label: "Total gastado con la key", value: UsageFormat.money(spend.total ?? 0))
                    }
                }
                .opacity(isLoading ? 0.5 : 1)
                .animation(.easeOut(duration: 0.15), value: isLoading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: refreshToken) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        do {
            let result = try await settings.makeClient().openRouterSpend()
            guard !Task.isCancelled else { return }
            spend = result
            errorText = nil
        } catch {
            guard !Task.isCancelled, !UsageFormat.isCancellation(error) else { return }
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SpendError: View {
    let message: String
    var hint: String?
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .textSelection(.enabled)
                if let hint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reintentar", action: onRetry)
                .controlSize(.small)
        }
        .padding(12)
        .usageCard()
    }
}

/// A UTC billing day, placed on the chart at the same calendar date in local time
/// so the axis shows the date OpenAI reports.
private struct CostDay: Identifiable {
    let date: Date
    let amount: Double
    var id: Date { date }

    static func days(from costs: [DailyCost], count: Int, now: Date = Date()) -> [CostDay] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let local = Calendar(identifier: .gregorian)
        var totals: [DateComponents: Double] = [:]
        for cost in costs {
            totals[utc.dateComponents([.year, .month, .day], from: cost.day), default: 0] += cost.amount
        }
        let today = utc.startOfDay(for: now)
        return (0..<max(count, 0)).reversed().compactMap { offset in
            guard let day = utc.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let components = utc.dateComponents([.year, .month, .day], from: day)
            guard let date = local.date(from: components) else { return nil }
            return CostDay(date: date, amount: totals[components] ?? 0)
        }
    }
}

private struct LineItemCost: Identifiable {
    let name: String
    let amount: Double
    var id: String { name }

    /// Totals per line item, largest first, with the long tail folded into one row.
    static func items(from costs: [DailyCost], limit: Int = 8) -> [LineItemCost] {
        var totals: [String: Double] = [:]
        for cost in costs {
            totals[cost.lineItem ?? "Sin concepto", default: 0] += cost.amount
        }
        let sorted = totals
            .filter { $0.value > 0 }
            .map { LineItemCost(name: $0.key, amount: $0.value) }
            .sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }
        guard sorted.count > limit else { return sorted }
        let rest = sorted[(limit - 1)...].reduce(0) { $0 + $1.amount }
        return Array(sorted.prefix(limit - 1)) + [LineItemCost(name: "Otros (\(sorted.count - limit + 1))", amount: rest)]
    }
}

private struct CostChart: View {
    let days: [CostDay]
    let currency: String

    @State private var hoveredDay: Date?

    var body: some View {
        GeometryReader { geometry in
            let width = barWidth(plotWidth: geometry.size.width - 50, dayCount: days.count)
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Día", day.date, unit: .day), y: .value("Gasto", day.amount), width: .fixed(width))
                        .foregroundStyle(Color.seriesBlue)
                        .clipShape(BarSegmentShape(roundsTop: true))
                        .opacity(hoveredDay == nil || hoveredDay == day.date ? 1 : 0.4)
                }
                if let hoveredDay, let day = days.first(where: { $0.date == hoveredDay }) {
                    RuleMark(x: .value("Día", day.date, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(
                            position: .overlay, alignment: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TooltipRow(value: UsageFormat.money(day.amount, currency: currency), label: "gastado (UTC)")
                            }
                            .tooltipBackground()
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xAxisStride(for: days.count))) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.currency(code: currency.uppercased()).precision(.fractionLength(0...2))))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                HoverLayer(proxy: proxy, hoveredDay: $hoveredDay)
            }
        }
    }
}

private struct LineItemTable: View {
    let items: [LineItemCost]
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Por concepto")
                .font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(items) { item in
                    GridRow {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageFormat.money(item.amount, currency: currency))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
            .padding(14)
            .usageCard()
        }
    }
}

// MARK: - Tokens

private struct TokensSection: View {
    @Environment(UsageStore.self) private var usage
    let period: UsagePeriod

    var body: some View {
        let days = usage.days(last: period.days)
        let models = usage.models(last: period.days)
        let total = days.reduce(TokenUsage()) { $0 + $1.usage }
        let today = days.last?.usage ?? TokenUsage()

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Tokens por día",
                subtitle: "Lo que WillChat registró en este Mac con cualquier proveedor, en tu zona horaria.")

            StatRow {
                StatTile(
                    label: "Hoy", value: UsageFormat.tokens(today.totalTokens),
                    detail: "\(today.requests.formatted()) solicitudes")
                StatTile(
                    label: "Últimos \(period.days) días", value: UsageFormat.tokens(total.totalTokens),
                    detail: "\(UsageFormat.tokens(total.inputTokens)) entrada · \(UsageFormat.tokens(total.outputTokens)) salida")
                if let cost = total.cost {
                    StatTile(label: "Costo reportado", value: UsageFormat.money(cost), detail: "Últimos \(period.days) días")
                }
            }

            Group {
                if total.requests == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("Sin consumo en este periodo")
                            .font(.headline)
                        Text("Los tokens aparecerán aquí a medida que uses el chat.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TokenChart(days: days)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .padding(16)
            .usageCard()

            if !models.isEmpty {
                ModelTable(models: models, showsCost: total.cost != nil)
                DisclosureGroup("Detalle por día") {
                    DayTable(days: days.filter { $0.usage.requests > 0 }.reversed(), showsCost: total.cost != nil)
                        .padding(.top, 8)
                }
            }
        }
    }
}

private struct TokenChart: View {
    let days: [UsageDay]

    @State private var hoveredDay: Date?

    private enum Series: String {
        case input = "Entrada"
        case output = "Salida"
    }

    /// Stacked by hand so each segment can get its own shape: rounded on top of the column
    /// and separated from the one below by a gap.
    private struct Segment: Identifiable {
        let date: Date
        let series: Series
        let start: Int
        let end: Int
        let isTop: Bool
        var id: String { "\(date.timeIntervalSince1970)-\(series.rawValue)" }
    }

    private var segments: [Segment] {
        days.flatMap { day -> [Segment] in
            let input = day.usage.inputTokens
            let total = day.usage.totalTokens
            var segments: [Segment] = []
            if input > 0 {
                segments.append(Segment(date: day.date, series: .input, start: 0, end: input, isTop: total == input))
            }
            if total > input {
                segments.append(Segment(date: day.date, series: .output, start: input, end: total, isTop: true))
            }
            return segments
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = barWidth(plotWidth: geometry.size.width - 50, dayCount: days.count)
            Chart {
                ForEach(segments) { segment in
                    BarMark(
                        x: .value("Día", segment.date, unit: .day),
                        yStart: .value("Tokens", segment.start),
                        yEnd: .value("Tokens", segment.end),
                        width: .fixed(width))
                    .foregroundStyle(by: .value("Tipo", segment.series.rawValue))
                    .clipShape(BarSegmentShape(roundsTop: segment.isTop, bottomGap: segment.start > 0 ? 2 : 0))
                    .opacity(hoveredDay == nil || hoveredDay == segment.date ? 1 : 0.4)
                }
                if let hoveredDay, let day = days.first(where: { $0.date == hoveredDay }) {
                    RuleMark(x: .value("Día", day.date, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(
                            position: .overlay, alignment: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            tooltip(for: day)
                        }
                }
            }
            .chartForegroundStyleScale([Series.input.rawValue: Color.seriesBlue, Series.output.rawValue: Color.seriesOrange])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xAxisStride(for: days.count))) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text(UsageFormat.tokens(count))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                HoverLayer(proxy: proxy, hoveredDay: $hoveredDay)
            }
        }
    }

    private func tooltip(for day: UsageDay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.caption)
                .foregroundStyle(.secondary)
            TooltipRow(color: .seriesBlue, value: day.usage.inputTokens.formatted(), label: Series.input.rawValue)
            TooltipRow(color: .seriesOrange, value: day.usage.outputTokens.formatted(), label: Series.output.rawValue)
            Text("\(day.usage.requests.formatted()) solicitudes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tooltipBackground()
    }
}

private struct TooltipRow: View {
    var color: Color?
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            if let color { SeriesKey(color: color) }
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Tracks which day's column the pointer is over.
private struct HoverLayer: View {
    let proxy: ChartProxy
    @Binding var hoveredDay: Date?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geometry[plotFrame].origin.x
                        if let date: Date = proxy.value(atX: x) {
                            hoveredDay = Calendar.current.startOfDay(for: date)
                        }
                    case .ended:
                        hoveredDay = nil
                    }
                }
        }
    }
}

private struct ModelTable: View {
    let models: [ModelUsage]
    let showsCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Por modelo")
                .font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Modelo")
                    Text("Solicitudes").gridColumnAlignment(.trailing)
                    Text("Entrada").gridColumnAlignment(.trailing)
                    Text("Salida").gridColumnAlignment(.trailing)
                    Text("Total").gridColumnAlignment(.trailing)
                    if showsCost { Text("Costo").gridColumnAlignment(.trailing) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(models) { model in
                    GridRow {
                        Text(model.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        UsageNumbers(usage: model.usage, showsCost: showsCost)
                    }
                }
            }
            .font(.callout)
            .padding(14)
            .usageCard()
        }
    }
}

private struct DayTable: View {
    let days: [UsageDay]
    let showsCost: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Día")
                Text("Solicitudes").gridColumnAlignment(.trailing)
                Text("Entrada").gridColumnAlignment(.trailing)
                Text("Salida").gridColumnAlignment(.trailing)
                Text("Total").gridColumnAlignment(.trailing)
                if showsCost { Text("Costo").gridColumnAlignment(.trailing) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(days) { day in
                GridRow {
                    Text(day.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    UsageNumbers(usage: day.usage, showsCost: showsCost)
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usageCard()
    }
}

/// The numeric cells shared by the model and day tables.
private struct UsageNumbers: View {
    let usage: TokenUsage
    let showsCost: Bool

    var body: some View {
        Group {
            Text(usage.requests.formatted())
            Text(usage.inputTokens.formatted())
                .help(usage.cachedInputTokens > 0 ? "\(usage.cachedInputTokens.formatted()) desde la caché" : "")
            Text(usage.outputTokens.formatted())
                .help(usage.reasoningTokens > 0 ? "\(usage.reasoningTokens.formatted()) de razonamiento" : "")
            Text(usage.totalTokens.formatted())
                .fontWeight(.medium)
            if showsCost {
                Text(usage.cost.map { UsageFormat.money($0) } ?? "—")
            }
        }
        .monospacedDigit()
    }
}

// MARK: - Shared pieces

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .usageCard()
    }
}

/// Stat tiles side by side, all as tall as the tallest one.
private struct StatRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UsageCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

private extension View {
    func usageCard() -> some View {
        modifier(UsageCard())
    }

    func tooltipBackground() -> some View {
        padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
            .fixedSize()
    }
}

/// A short stroke of a series color, keying a tooltip or legend row.
private struct SeriesKey: View {
    let color: Color

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: 12, height: 3)
    }
}

/// A column's rounded data end (square at the baseline). `bottomGap` leaves a strip of the
/// surface between stacked segments instead of drawing a border around them.
private struct BarSegmentShape: Shape {
    var roundsTop: Bool
    var bottomGap: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height - bottomGap, 0))
        guard roundsTop else { return Path(body) }
        let radius = min(4, body.width / 2, body.height)
        return UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
            .path(in: body)
    }
}

/// Bars get thinner as the period grows, but never thicker than 24pt.
private func barWidth(plotWidth: CGFloat, dayCount: Int) -> CGFloat {
    max(2, min(24, plotWidth / CGFloat(max(dayCount, 1)) * 0.6))
}

private func xAxisStride(for dayCount: Int) -> Int {
    switch dayCount {
    case ...7: 1
    case ...30: 5
    default: 15
    }
}

private extension Color {
    /// Slots 1 and 2 of the chart palette, validated for colorblind separation and contrast
    /// on the card surface in each appearance.
    static let seriesBlue = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let seriesOrange = Color(light: 0xEB6834, dark: 0xD95926)

    init(light: Int, dark: Int) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum UsageFormat {
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// Cents for regular amounts; amounts under a cent keep up to four decimals so they don't read as zero.
    static func money(_ amount: Double, currency: String = "usd") -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currency.uppercased())
        return abs(amount) >= 0.01 || amount == 0
            ? amount.formatted(style.precision(.fractionLength(2)))
            : amount.formatted(style.precision(.fractionLength(2...4)))
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
