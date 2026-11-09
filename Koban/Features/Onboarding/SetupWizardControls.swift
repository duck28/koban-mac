import AppKit
import SwiftUI

// Small controls matching the Tailwind inputs used in OnboardingModal.tsx.

/// <select> with configurable height / font (h-7 text-[11px] … h-9 text-xs).
struct OnbSelect<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 36
    var fontSize: CGFloat = 12
    var textColor: Color = Zen.ink
    var background: Color = Zen.surface
    var radius: CGFloat = 8
    var fullWidth = false
    var horizontalPadding: CGFloat = 12

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.zen(fontSize)).foregroundStyle(textColor).lineLimit(1)
                if fullWidth { Spacer(minLength: 4) }
                ZIcon("chevron.down", size: max(10, fontSize - 1)).foregroundStyle(Zen.ink3)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fullWidth, vertical: false)
    }
}

/// Plain bordered text input (h-9 px-3 rounded-lg bg-surface border border-line text-xs).
struct OnbTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var height: CGFloat = 36
    var fontSize: CGFloat = 12
    var textColor: Color = Zen.ink
    var background: Color = Zen.surface
    var radius: CGFloat = 8
    var horizontalPadding: CGFloat = 12
    var alignment: TextAlignment = .leading
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
            .textFieldStyle(.plain)
            .font(.zen(fontSize))
            .foregroundStyle(textColor)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
            .onSubmit(onSubmit)
    }
}

/// <input type="number"> bound to a Double: `parseFloat(value) || 0` on every edit.
struct OnbNumberField: View {
    @Binding var value: Double
    var placeholder: String = ""
    /// Show an empty field for 0 (`value={x || ''}`).
    var emptyForZero = false
    var height: CGFloat = 36
    var fontSize: CGFloat = 12
    var background: Color = Zen.surface
    var radius: CGFloat = 8
    var horizontalPadding: CGFloat = 12
    var alignment: TextAlignment = .leading

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
            .textFieldStyle(.plain)
            .font(.zen(fontSize))
            .monospacedDigit()
            .foregroundStyle(Zen.ink)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
            .onAppear { text = display(value) }
            .onChange(of: text) { _, new in
                let parsed = NumberParsing.parse(new) ?? 0
                if parsed != value { value = parsed }
            }
            .onChange(of: value) { _, new in
                if !focused, NumberParsing.parse(text) ?? 0 != new { text = display(new) }
            }
    }

    private func display(_ v: Double) -> String {
        if emptyForZero { return NumberParsing.editable(v) }
        if v == v.rounded() { return String(Int(v)) }
        return String(v)
    }
}

/// Square checkbox + label (input type=checkbox rounded border-line).
struct OnbCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        ZenCheckbox(isOn: $isOn, label: label, fontSize: 12, color: Zen.ink2)
    }
}

/// A ScrollView that is only as tall as its content, capped at `maxHeight` (max-h-… overflow-y-auto).
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    var minHeight: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, minHeight), maxHeight))
    }
}

/// Tracks the window height so `vh`-based limits (max-h-[68vh], max-h-[43vh]) can be applied.
struct WindowHeightReader: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in refresh() }
    }

    private func refresh() {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            height = window.contentLayoutRect.height > 0 ? window.frame.height : height
        }
    }
}
