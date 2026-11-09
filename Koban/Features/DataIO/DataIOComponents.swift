import SwiftUI

// Small building blocks shared by the Data I/O views (Tailwind snippets of
// BackupsExportView / DbLocationCard / WebDavSyncCard / ImportDataModal).

enum DataIOColors {
    /// Tailwind amber-500 / amber-600 (the move / pull confirmation drawers).
    static let amber500 = Color(light: 0xF59E0B, dark: 0xF59E0B)
    static let amber600 = Color(light: 0xD97706, dark: 0xD97706)
    /// `text-negative` (not a token in App.css; the vermilion accent stands in).
    static var negative: Color { Zen.accent }
}

/// px-2 py-0.5 rounded-full text-[10px] badge.
struct DataIOPill: View {
    let text: String
    var foreground: Color = Zen.ink2
    var background: Color = Zen.raised
    var border: Color? = nil
    var weight: Font.Weight = .medium

    var body: some View {
        Text(text)
            .font(.zen(10, weight))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .overlay { if let border { Capsule().strokeBorder(border, lineWidth: 1) } }
            .fixedSize()
    }
}

/// p-3 rounded-lg border status banner (success / error / info).
struct DataIOBanner: View {
    enum Kind { case success, error, info }
    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .success: return Zen.positive
        case .error: return DataIOColors.negative
        case .info: return Zen.indigo
        }
    }

    private var icon: String {
        switch kind {
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZIcon(icon, size: 16)
            Text(text).font(.zen(12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .foregroundStyle(color)
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.2), lineWidth: 1))
    }
}

/// A small native-looking checkbox square (the `<input type="checkbox">` of the Windows UI).
struct DataIOCheckSquare: View {
    let isOn: Bool
    var size: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(isOn ? Zen.ink : Zen.surface)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isOn ? Zen.ink : Zen.ink3, lineWidth: 1))
            .overlay {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(Zen.onInk)
                }
            }
            .frame(width: size, height: size)
    }
}

struct DataIOCheckbox<Label: View>: View {
    @Binding var isOn: Bool
    var size: CGFloat = 13
    var spacing: CGFloat = 8
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: spacing) {
                DataIOCheckSquare(isOn: isOn, size: size)
                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small indeterminate spinner (Loader2 animate-spin).
struct DataIOSpinner: View {
    var size: CGFloat = 14
    @State private var spin = false

    var body: some View {
        ZIcon("arrow.triangle.2.circlepath", size: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// block text-[11px] text-ink-2 mb-1 field label.
struct DataIOFieldLabel: View {
    let text: String
    var size: CGFloat = 11
    init(_ text: String, size: CGFloat = 11) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(.zen(size)).foregroundStyle(Zen.ink2)
    }
}

/// Text input with an optional leading icon (relative + absolute icon in the Windows markup).
struct DataIOTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var secure = false
    var monospaced = false
    var height: CGFloat = 36
    var background: Color = Zen.app
    var trailingPadding: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            if let icon { ZIcon(icon, size: 14).foregroundStyle(Zen.ink3) }
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .zen(12))
            .foregroundStyle(Zen.ink)
        }
        .padding(.leading, icon == nil ? 12 : 10)
        .padding(.trailing, trailingPadding)
        .frame(height: height)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }
}

/// `<code className="text-ink">` inside running text.
func dataIOCode(_ s: String, color: Color = Zen.ink) -> Text {
    Text(s).font(.system(size: 11.5, design: .monospaced)).foregroundColor(color)
}

/// Amber primary button of the confirmation drawers (bg-amber-600 hover:bg-amber-500 text-white).
struct DataIOAmberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AmberBody(configuration: configuration)
    }

    private struct AmberBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.zen(12, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(hovering ? DataIOColors.amber500 : DataIOColors.amber600, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

/// `grid grid-cols-N gap` helper: lays out equal columns, wrapping into rows.
struct DataIOGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    var spacing: CGFloat = 16
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: max(columns, 1)).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[r]) { cell($0).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    if rows[r].count < columns {
                        ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `bg-raised border border-line` buttons. `mutedText` = text-ink-2 hover:text-ink,
/// otherwise text-ink with hover:bg-line/60–70.
struct DataIORaisedButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var padding: CGFloat = 12
    var fontSize: CGFloat = 12
    var weight: Font.Weight = .regular
    var mutedText = false
    var background: Color? = nil
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyle.Configuration
        let style: DataIORaisedButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let base = style.background ?? Zen.raised
            configuration.label
                .font(.zen(style.fontSize, style.weight))
                .lineLimit(1)
                .foregroundStyle(style.mutedText ? (hovering ? Zen.ink : Zen.ink2) : Zen.ink)
                .padding(.horizontal, style.padding)
                .frame(height: style.height)
                .background(!style.mutedText && hovering ? (style.background == nil ? Zen.line.opacity(0.65) : Zen.raised) : base,
                            in: RoundedRectangle(cornerRadius: style.radius))
                .overlay(RoundedRectangle(cornerRadius: style.radius).strokeBorder(Zen.line, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: style.radius))
                .onHover { hovering = $0 }
        }
    }
}

/// bg-ink text-on-ink primary button with explicit metrics.
struct DataIOInkButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var padding: CGFloat = 12
    var fontSize: CGFloat = 12
    var weight: Font.Weight = .medium
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyle.Configuration
        let style: DataIOInkButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.zen(style.fontSize, style.weight))
                .lineLimit(1)
                .foregroundStyle(Zen.onInk)
                .padding(.horizontal, style.padding)
                .frame(height: style.height)
                .background(Zen.ink, in: RoundedRectangle(cornerRadius: style.radius))
                .opacity(isEnabled ? (hovering ? 0.9 : 1) : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: style.radius))
                .onHover { hovering = $0 }
        }
    }
}
