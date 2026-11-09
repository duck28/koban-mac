import AppKit
import SwiftUI

// Small controls used by the Yearly Planner, reproducing the exact Tailwind sizes of
// YearlyBudgetPlannerView.tsx (h-7 / text-[11px] selects, no-spinner number inputs …).

// MARK: - <select>

/// A `<select>` look-alike: auto-sized to its widest option (like the browser does),
/// optionally capped (`max-w-[190px]`) or stretched (`w-full`).
struct YPSelect: View {
    let options: [(String, String)]
    let selection: String
    var height: CGFloat = 32
    var fontSize: CGFloat = 12
    var radius: CGFloat = 8
    var textColor: Color = Zen.ink
    var background: Color = Zen.raised
    var border: Color = Zen.line
    var fullWidth = false
    var maxWidth: CGFloat?
    var help: String = ""
    let onChange: (String) -> Void

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? options.first?.1 ?? ""
    }

    // Performance: a SwiftUI Menu per control (three per planner row) plus hidden copies of every
    // option for sizing made the planner slow to build and scroll. This is a plain button that
    // builds a native pop-up menu only when clicked, and sizes itself from a cached measurement.
    var body: some View {
        Button { popUpMenu() } label: {
            HStack(spacing: 4) {
                Text(currentLabel).font(.zen(fontSize)).foregroundStyle(textColor).lineLimit(1)
                    .frame(width: fullWidth ? nil : YPSelect.widestLabel(options.map(\.1), fontSize: fontSize),
                           alignment: .leading)
                    .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
                ZIcon("chevron.down", size: max(9, fontSize - 1)).foregroundStyle(Zen.ink3)
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : maxWidth, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth && maxWidth == nil, vertical: true)
        .help(help)
    }

    private func popUpMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var selectedItem: NSMenuItem?
        for (value, label) in options {
            let item = YPMenuAction.item(title: label) { if value != selection { onChange(value) } }
            if value == selection {
                item.state = .on
                selectedItem = item
            }
            menu.addItem(item)
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        let location = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: selectedItem, at: location, in: content)
    }

    nonisolated(unsafe) private static var widthCache: [String: CGFloat] = [:]

    /// Width of the widest option label (the old hidden-copies sizing), measured once per option set.
    static func widestLabel(_ labels: [String], fontSize: CGFloat) -> CGFloat {
        let size = fontSize * ZenPersonalization.scale
        let key = "\(size)|" + labels.joined(separator: "\u{1F}")
        if let cached = widthCache[key] { return cached }
        let font = NSFont.systemFont(ofSize: size)
        let width = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let rounded = ceil(width) + 1
        widthCache[key] = rounded
        return rounded
    }
}

/// NSMenuItem target that runs a closure.
private final class YPMenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }

    static func item(title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = YPMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action // keeps the target alive
        return item
    }
}

// MARK: - <input type="number" class="no-spinner">

/// Controlled number input: reports every parseable edit (`parseFloat(v) || 0` semantics),
/// re-syncs from the model while not focused.
struct YPNumberField: View {
    let value: Double
    /// Text shown for `value` while not editing.
    var display: (Double) -> String = { NumberParsing.editable($0) }
    var placeholder: String = "0"
    var width: CGFloat? = nil
    var height: CGFloat = 28
    var fontSize: CGFloat = 12
    var weight: Font.Weight = .regular
    var radius: CGFloat = 4
    var textColor: Color = Zen.ink2
    var focusedColor: Color = Zen.ink
    var background: Color = Zen.raised
    var focusBorder: Color = Zen.line
    var chrome = true
    var help: String = ""
    /// With an EditFocus in the environment, the field renders as text until clicked / tabbed into.
    var cellID: String? = nil
    let onChange: (Double) -> Void

    @Environment(EditFocus.self) private var editFocus: EditFocus?

    var body: some View {
        if let editFocus, let cellID, editFocus.active != cellID {
            let shown = display(value)
            Text(shown.isEmpty ? placeholder : shown)
                .font(.zen(fontSize, weight))
                .monospacedDigit()
                .foregroundStyle(shown.isEmpty ? Zen.ink3 : textColor)
                .lineLimit(1)
                .padding(.horizontal, chrome ? 8 : 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(width: width, height: height)
                .background { if chrome { RoundedRectangle(cornerRadius: radius).fill(background) } }
                .overlay { if chrome { RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1) } }
                .contentShape(Rectangle())
                .onTapGesture { editFocus.active = cellID }
                .help(help)
        } else {
            YPNumberEditor(field: self, autoFocus: cellID != nil && editFocus != nil) {
                if let cellID { editFocus?.end(cellID) }
            }
        }
    }
}

private struct YPNumberEditor: View {
    let field: YPNumberField
    let autoFocus: Bool
    let onEnd: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let f = field
        TextField("", text: $text, prompt: Text(f.placeholder).font(.zen(f.fontSize, f.weight)).foregroundStyle(Zen.ink3))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.zen(f.fontSize, f.weight))
            .monospacedDigit()
            .foregroundStyle(focused ? f.focusedColor : f.textColor)
            .padding(.horizontal, f.chrome ? 8 : 0)
            .frame(width: f.width, height: f.height)
            .background {
                if f.chrome { RoundedRectangle(cornerRadius: f.radius).fill(f.background) }
            }
            .overlay {
                if f.chrome {
                    RoundedRectangle(cornerRadius: f.radius).strokeBorder(focused ? f.focusBorder : Zen.line, lineWidth: 1)
                }
            }
            .focused($focused)
            .help(f.help)
            .onAppear {
                text = f.display(f.value)
                if autoFocus { focused = true }
            }
            .onChange(of: f.value) { _, newValue in
                if !focused { text = f.display(newValue) }
            }
            .onChange(of: text) { _, newText in
                guard focused else { return }
                if newText.isEmpty { f.onChange(0); return }
                if let parsed = NumberParsing.parse(newText) { f.onChange(parsed) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    text = f.display(f.value)
                    onEnd()
                }
            }
            .onSubmit { focused = false }
            .onExitCommand { focused = false }
    }
}

// MARK: - Flex-wrap with flex-basis / flex-grow

private struct FlexBasisKey: LayoutValueKey { static let defaultValue: CGFloat? = nil }
private struct FlexGrowKey: LayoutValueKey { static let defaultValue: CGFloat = 0 }

extension View {
    /// `flex-[grow_1_basis]` inside a `YPFlexWrap`.
    func ypFlex(grow: CGFloat, basis: CGFloat?) -> some View {
        layoutValue(key: FlexGrowKey.self, value: grow).layoutValue(key: FlexBasisKey.self, value: basis)
    }
}

/// `flex flex-wrap gap-x` with flex-basis/flex-grow distribution; items wider than the line
/// are clamped to it (`max-w-full` + truncate).
struct YPFlexWrap: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat? = nil
    var alignment: VerticalAlignment = .center

    private struct Line { var items: [(index: Int, width: CGFloat)] = []; var height: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(width: width, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + (lineSpacing ?? spacing) * CGFloat(max(0, lines.count - 1))
        let used = lines.map { $0.items.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, $0.items.count - 1)) }.max() ?? 0
        return CGSize(width: width.isFinite ? width : used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                let size = subviews[item.index].sizeThatFits(ProposedViewSize(width: item.width, height: nil))
                let dy: CGFloat = alignment == .bottom ? line.height - size.height
                    : alignment == .top ? 0 : (line.height - size.height) / 2
                subviews[item.index].place(at: CGPoint(x: x, y: y + dy),
                                           proposal: ProposedViewSize(width: item.width, height: size.height))
                x += item.width + spacing
            }
            y += line.height + (lineSpacing ?? spacing)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var groups: [[(Int, CGFloat)]] = [[]]
        var lineWidth: CGFloat = 0
        for idx in subviews.indices {
            let basis = subviews[idx][FlexBasisKey.self] ?? subviews[idx].sizeThatFits(.unspecified).width
            let w = min(basis, width)
            let needed = groups[groups.count - 1].isEmpty ? w : lineWidth + spacing + w
            if needed > width && !groups[groups.count - 1].isEmpty {
                groups.append([])
                lineWidth = w
            } else {
                lineWidth = needed
            }
            groups[groups.count - 1].append((idx, w))
        }
        return groups.filter { !$0.isEmpty }.map { group in
            let used = group.reduce(0) { $0 + $1.1 } + spacing * CGFloat(group.count - 1)
            let totalGrow = group.reduce(0) { $0 + subviews[$1.0][FlexGrowKey.self] }
            let free = width.isFinite ? max(0, width - used) : 0
            var line = Line()
            for (idx, w) in group {
                let grow = subviews[idx][FlexGrowKey.self]
                let final = totalGrow > 0 ? w + free * grow / totalGrow : w
                let h = subviews[idx].sizeThatFits(ProposedViewSize(width: final, height: nil)).height
                line.items.append((idx, final))
                line.height = max(line.height, h)
            }
            return line
        }
    }
}

// MARK: - Equal-height grid (CSS grid-cols-N)

struct YPGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    var spacing: CGFloat = 12
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: max(1, columns)).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r]) { item in
                        cell(item).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in
                        Color.clear.frame(height: 0)
                    }
                }
            }
        }
    }
}
