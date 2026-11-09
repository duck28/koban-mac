import SwiftUI

// Small building blocks for the Transactions & Recurring views (Tailwind grid, <select> with
// <optgroup>, <input type="date">). Prefixed `Tx` to stay out of other features' namespaces.

// MARK: - CSS grid (grid-cols-N gap-3, col-span-N)

private struct TxGridSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

extension View {
    /// `col-span-N` inside a `TxGridLayout`.
    func txGridSpan(_ span: Int) -> some View { layoutValue(key: TxGridSpanKey.self, value: span) }
}

/// Equal-width columns that wrap to new rows, like `grid grid-cols-N gap-x`.
struct TxGridLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 12

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rows(_ subviews: Subviews) -> [[(index: Int, column: Int, span: Int)]] {
        var rows: [[(Int, Int, Int)]] = [[]]
        var col = 0
        for (i, sub) in subviews.enumerated() {
            let span = min(columns, max(1, sub[TxGridSpanKey.self]))
            if col + span > columns { rows.append([]); col = 0 }
            rows[rows.count - 1].append((i, col, span))
            col += span
        }
        return rows.map { $0.map { (index: $0.0, column: $0.1, span: $0.2) } }
    }

    private func cellWidth(_ span: Int, _ colW: CGFloat) -> CGFloat {
        colW * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let colW = columnWidth(width)
        var height: CGFloat = 0
        let all = rows(subviews)
        for (r, row) in all.enumerated() {
            let h = row.map { subviews[$0.index].sizeThatFits(.init(width: cellWidth($0.span, colW), height: nil)).height }.max() ?? 0
            height += h + (r > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colW = columnWidth(bounds.width)
        var y = bounds.minY
        for row in rows(subviews) {
            let h = row.map { subviews[$0.index].sizeThatFits(.init(width: cellWidth($0.span, colW), height: nil)).height }.max() ?? 0
            for cell in row {
                let x = bounds.minX + CGFloat(cell.column) * (colW + spacing)
                subviews[cell.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: .init(width: cellWidth(cell.span, colW), height: h))
            }
            y += h + spacing
        }
    }
}

// MARK: - Labeled field

/// `<label className="block text-[11px] text-ink-2 mb-1">` above an input.
struct TxField<Content: View>: View {
    let label: String
    var size: CGFloat = 11
    var color: Color = Zen.ink2
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.zen(size)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Select

struct TxOptionGroup<T: Hashable> {
    var label: String?
    var options: [(T, String)]
}

/// A `<select>` (optionally with `<optgroup>`s) drawn like the Windows control:
/// `h-8 px-2.5 rounded-lg bg-raised border border-line text-xs`.
struct TxSelect<T: Hashable>: View {
    let groups: [TxOptionGroup<T>]
    @Binding var selection: T
    var height: CGFloat = 32
    var radius: CGFloat = 8
    var fontSize: CGFloat = 12
    var background: Color = Zen.raised
    var textColor: Color = Zen.ink
    var fullWidth = true
    var onChange: ((T) -> Void)?

    init(options: [(T, String)], selection: Binding<T>, height: CGFloat = 32, radius: CGFloat = 8,
         fontSize: CGFloat = 12, background: Color = Zen.raised, textColor: Color = Zen.ink,
         fullWidth: Bool = true, onChange: ((T) -> Void)? = nil) {
        self.init(groups: [TxOptionGroup(label: nil, options: options)], selection: selection, height: height,
                  radius: radius, fontSize: fontSize, background: background, textColor: textColor,
                  fullWidth: fullWidth, onChange: onChange)
    }

    init(groups: [TxOptionGroup<T>], selection: Binding<T>, height: CGFloat = 32, radius: CGFloat = 8,
         fontSize: CGFloat = 12, background: Color = Zen.raised, textColor: Color = Zen.ink,
         fullWidth: Bool = true, onChange: ((T) -> Void)? = nil) {
        self.groups = groups
        self._selection = selection
        self.height = height
        self.radius = radius
        self.fontSize = fontSize
        self.background = background
        self.textColor = textColor
        self.fullWidth = fullWidth
        self.onChange = onChange
    }

    private var currentLabel: String {
        for g in groups { if let hit = g.options.first(where: { $0.0 == selection }) { return hit.1 } }
        // A controlled <select> whose value matches no option shows the first option.
        return groups.first(where: { !$0.options.isEmpty })?.options.first?.1 ?? ""
    }

    var body: some View {
        Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                if let label = group.label {
                    Section(label) { items(group.options) }
                } else {
                    items(group.options)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.zen(fontSize)).foregroundStyle(textColor).lineLimit(1).truncationMode(.tail)
                if fullWidth { Spacer(minLength: 4) }
                ZIcon("chevron.down", size: 11).foregroundStyle(Zen.ink3)
            }
            .padding(.horizontal, height < 30 ? 8 : 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fullWidth, vertical: true)
    }

    @ViewBuilder private func items(_ options: [(T, String)]) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            Button {
                selection = option.0
                onChange?(option.0)
            } label: {
                if option.0 == selection { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
            }
        }
    }
}

// MARK: - Text input

extension View {
    /// `h-8 px-2.5 rounded-lg bg-raised border border-line text-xs` (h-7 rounded: `height: 28, radius: 4`).
    func txInput(height: CGFloat = 32, radius: CGFloat = 8, background: Color = Zen.raised,
                 fontSize: CGFloat = 12, padding: CGFloat = 10, invalid: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(.zen(fontSize))
            .foregroundStyle(Zen.ink)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(invalid ? Zen.accent : Zen.line, lineWidth: 1))
    }
}

/// Placeholder in the ink-3 color (placeholder:text-ink-3).
func txPrompt(_ text: String) -> Text { Text(text).foregroundStyle(Zen.ink3) }

// MARK: - Date input

/// `<input type="date">`: an editable YYYY-MM-DD field with a calendar popover.
struct TxDateField: View {
    @Binding var date: String
    @State private var showPicker = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: txPrompt("YYYY-MM-DD"))
                .textFieldStyle(.plain)
                .font(.zen(12))
                .monospacedDigit()
                .foregroundStyle(Zen.ink)
                .focused($focused)
                .onSubmit(commit)
            Button { showPicker.toggle() } label: {
                ZIcon("calendar", size: 13).foregroundStyle(Zen.ink2)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                DatePicker("", selection: pickerBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(12)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
        .onAppear { text = date }
        .onChange(of: date) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let d = Self.formatter.date(from: trimmed) {
            date = Self.formatter.string(from: d)
        } else if trimmed.isEmpty {
            date = ""
        }
        text = date
    }

    private var pickerBinding: Binding<Date> {
        Binding(
            get: { Self.formatter.date(from: date) ?? Date() },
            set: { date = Self.formatter.string(from: $0); text = date }
        )
    }
}

// MARK: - Segmented pill (bg-raised p-0.5 rounded-lg)

struct TxSegment: View {
    let label: String
    let active: Bool
    var activeBackground: Color = Zen.surface
    var shadow = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.zen(12, active ? .medium : .regular))
                .foregroundStyle(active || hovering ? Zen.ink : Zen.ink2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(active ? activeBackground : .clear, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: active && shadow ? .black.opacity(0.06) : .clear, radius: 1, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
