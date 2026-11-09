import SwiftUI

// Layout + form helpers for the Accounts & Goals views (Tailwind grid / flex-wrap / form inputs).

/// Tailwind viewport breakpoints evaluated against the window width the Windows build would have:
/// the measured content width plus page padding and (when open) the 256 px sidebar.
struct AccBreakpoints {
    var viewport: CGFloat
    var sm: Bool { viewport >= 640 }
    var md: Bool { viewport >= 768 }
    var lg: Bool { viewport >= 1024 }
}

/// CSS grid with equal columns (`grid grid-cols-N gap-X`). Items in a row stretch to the row's height.
struct AccGrid: Layout {
    var columns: Int
    var hSpacing: CGFloat
    var vSpacing: CGFloat
    var alignment: VerticalAlignment = .top

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        let cols = CGFloat(max(1, columns))
        return max(0, (width - hSpacing * (cols - 1)) / cols)
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let colW = columnWidth(width)
        let cols = max(1, columns)
        return stride(from: 0, to: subviews.count, by: cols).map { start in
            subviews[start..<min(start + cols, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let rows = rowHeights(width: width, subviews: subviews)
        let height = rows.reduce(0, +) + vSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colW = columnWidth(bounds.width)
        let cols = max(1, columns)
        let rows = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (r, rowH) in rows.enumerated() {
            for c in 0..<cols {
                let idx = r * cols + c
                guard idx < subviews.count else { break }
                let x = bounds.minX + CGFloat(c) * (colW + hSpacing)
                let size = subviews[idx].sizeThatFits(ProposedViewSize(width: colW, height: rowH))
                let dy: CGFloat = alignment == .bottom ? rowH - min(rowH, size.height) : 0
                subviews[idx].place(at: CGPoint(x: x, y: y + dy),
                                    proposal: ProposedViewSize(width: colW, height: alignment == .bottom ? size.height : rowH))
            }
            y += rowH + vSpacing
        }
    }
}

// MARK: - Flex wrap with flex-grow / flex-basis

private struct AccFlexBasisKey: LayoutValueKey { static let defaultValue: CGFloat? = nil }
private struct AccFlexGrowKey: LayoutValueKey { static let defaultValue: CGFloat = 0 }
private struct AccFlexMinKey: LayoutValueKey { static let defaultValue: CGFloat = 0 }

extension View {
    /// `flex-[grow_1_basis] min-w-[min]`
    func accFlex(grow: CGFloat, basis: CGFloat, minWidth: CGFloat = 0) -> some View {
        layoutValue(key: AccFlexGrowKey.self, value: grow)
            .layoutValue(key: AccFlexBasisKey.self, value: basis)
            .layoutValue(key: AccFlexMinKey.self, value: minWidth)
    }
}

/// `flex flex-wrap items-end gap-X`, honoring each item's flex-grow / flex-basis.
struct AccFlexWrap: Layout {
    var spacing: CGFloat = 12

    private struct Line { var items: [Int] = []; var widths: [CGFloat] = []; var height: CGFloat = 0 }

    private func baseWidth(_ sub: LayoutSubview) -> CGFloat {
        let basis = sub[AccFlexBasisKey.self] ?? sub.sizeThatFits(.unspecified).width
        return max(basis, sub[AccFlexMinKey.self])
    }

    private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
        var result: [Line] = []
        var current = Line()
        var used: CGFloat = 0
        for idx in subviews.indices {
            let w = baseWidth(subviews[idx])
            let needed = current.items.isEmpty ? w : used + spacing + w
            if needed > width, !current.items.isEmpty {
                result.append(current)
                current = Line()
                used = 0
            }
            used = current.items.isEmpty ? w : used + spacing + w
            current.items.append(idx)
            current.widths.append(w)
        }
        if !current.items.isEmpty { result.append(current) }
        // Distribute free space by flex-grow and measure heights.
        for l in result.indices {
            let total = result[l].widths.reduce(0, +) + spacing * CGFloat(result[l].items.count - 1)
            let free = max(0, width - total)
            let growSum = result[l].items.reduce(0) { $0 + subviews[$1][AccFlexGrowKey.self] }
            if growSum > 0 {
                for (k, idx) in result[l].items.enumerated() {
                    result[l].widths[k] += free * subviews[idx][AccFlexGrowKey.self] / growSum
                }
            }
            for (k, idx) in result[l].items.enumerated() {
                result[l].widths[k] = min(result[l].widths[k], width)
                let h = subviews[idx].sizeThatFits(ProposedViewSize(width: result[l].widths[k], height: nil)).height
                result[l].height = max(result[l].height, h)
            }
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let ls = lines(width: width, subviews: subviews)
        return CGSize(width: width, height: ls.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, ls.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (k, idx) in line.items.enumerated() {
                let w = line.widths[k]
                let h = subviews[idx].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                subviews[idx].place(at: CGPoint(x: x, y: y + line.height - h), proposal: ProposedViewSize(width: w, height: h))
                x += w + spacing
            }
            y += line.height + spacing
        }
    }
}

// MARK: - Form pieces

/// `block text-[11px] text-ink-2 mb-1` + control.
struct AccLabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.zen(11)).foregroundStyle(Zen.ink2).lineLimit(1).truncationMode(.tail)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `w-full h-9 px-3 rounded-lg bg-app border border-line text-xs` text input.
struct AccTextField: View {
    var placeholder: String
    @Binding var text: String
    var height: CGFloat = 36
    var background: Color = Zen.app
    var trailing = false
    var monospacedDigits = false
    var fontSize: CGFloat = 12
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
            .textFieldStyle(.plain)
            .font(.zen(fontSize))
            .accMonoDigits(monospacedDigits)
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .foregroundStyle(Zen.ink)
            .padding(.horizontal, height >= 36 ? 12 : 10)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .onSubmit(onSubmit)
    }
}

private extension View {
    @ViewBuilder func accMonoDigits(_ on: Bool) -> some View {
        if on { self.monospacedDigit() } else { self }
    }
}

/// Full-width `<select>` with optional `<optgroup>` sections.
struct AccSelect<T: Hashable>: View {
    struct Section: Identifiable {
        var title: String?
        var options: [(T, String)]
        var id: String { title ?? options.map(\.1).joined() }
    }

    let sections: [Section]
    @Binding var selection: T
    var height: CGFloat = 36
    var background: Color = Zen.app

    init(options: [(T, String)], selection: Binding<T>, height: CGFloat = 36, background: Color = Zen.app) {
        self.sections = [Section(title: nil, options: options)]
        self._selection = selection
        self.height = height
        self.background = background
    }

    init(sections: [Section], selection: Binding<T>, height: CGFloat = 36, background: Color = Zen.app) {
        self.sections = sections
        self._selection = selection
        self.height = height
        self.background = background
    }

    private var selectedLabel: String {
        sections.flatMap(\.options).first(where: { $0.0 == selection })?.1 ?? ""
    }

    var body: some View {
        Menu {
            ForEach(sections) { section in
                if let title = section.title {
                    SwiftUI.Section(title) { items(section.options) }
                } else {
                    items(section.options)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedLabel).font(.zen(12)).foregroundStyle(Zen.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                ZIcon("chevron.down", size: 12).foregroundStyle(Zen.ink3)
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    @ViewBuilder private func items(_ options: [(T, String)]) -> some View {
        ForEach(options, id: \.0) { value, label in
            Button {
                selection = value
            } label: {
                if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
            }
        }
    }
}

/// `<input type="date">`: a yyyy-MM-dd text field with a calendar popover.
struct AccDateField: View {
    @Binding var text: String
    var height: CGFloat = 32
    var background: Color = Zen.raised
    @State private var showPicker = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var dateBinding: Binding<Date> {
        Binding(
            get: { Self.formatter.date(from: text) ?? Date() },
            set: { text = Self.formatter.string(from: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: Text("yyyy-mm-dd").foregroundStyle(Zen.ink3))
                .textFieldStyle(.plain)
                .font(.zen(12))
                .monospacedDigit()
                .foregroundStyle(Zen.ink)
            Button { showPicker.toggle() } label: {
                ZIcon("calendar", size: 14).foregroundStyle(Zen.ink2)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    .padding(12)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }
}

/// Small checkbox + label (`<label class="flex items-center gap-2"><input type=checkbox>…`).
struct AccCheckbox: View {
    let isOn: Bool
    let label: String
    var fontSize: CGFloat = 12
    var color: Color = Zen.ink2
    var hoverColor: Color? = nil
    var gap: CGFloat = 8
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn ? Zen.ink : Zen.surface)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isOn ? Zen.ink : Zen.ink3, lineWidth: 1))
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Zen.onInk)
                        }
                    }
                    .frame(width: 13, height: 13)
                Text(label).font(.zen(fontSize)).foregroundStyle(hovering ? (hoverColor ?? color) : color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Text-only link button (`text-xs text-ink-3 hover:text-ink`).
struct AccTextButton: View {
    let title: String
    var fontSize: CGFloat = 12
    var color: Color = Zen.ink3
    var hoverColor: Color = Zen.ink
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.zen(fontSize)).foregroundStyle(hovering ? hoverColor : color)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// `p-X rounded-xl bg-surface border border-line` with an optional custom border.
    func accSurfaceCard(padding: CGFloat, border: Color = Zen.line, radius: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
    }

    /// `border-b border-line` drawn under the view.
    func accBottomHairline(_ color: Color = Zen.line) -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 1) }
    }

    func accTopHairline(_ color: Color = Zen.line) -> some View {
        overlay(alignment: .top) { Rectangle().fill(color).frame(height: 1) }
    }
}

/// One CSS-grid row of `grid-cols-<total>` with `col-span-N` children; children stretch to the row height.
struct AccSpanRow: Layout {
    var spans: [Int]
    var total: Int = 12
    var spacing: CGFloat = 24

    private func widths(_ width: CGFloat) -> [CGFloat] {
        let col = (width - spacing * CGFloat(total - 1)) / CGFloat(total)
        return spans.map { col * CGFloat($0) + spacing * CGFloat($0 - 1) }
    }

    private func height(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let ws = widths(width)
        return subviews.indices.map { i in
            subviews[i].sizeThatFits(ProposedViewSize(width: ws[min(i, ws.count - 1)], height: nil)).height
        }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        return CGSize(width: width, height: height(width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ws = widths(bounds.width)
        let h = height(bounds.width, subviews)
        var x = bounds.minX
        for i in subviews.indices {
            let w = ws[min(i, ws.count - 1)]
            subviews[i].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: h))
            x += w + spacing
        }
    }
}
