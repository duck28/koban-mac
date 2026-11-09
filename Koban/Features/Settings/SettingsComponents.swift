import SwiftUI

// Small building blocks reproducing the Tailwind markup of SettingsView.tsx / AuthLockScreen.tsx.

/// Native-looking <input type="checkbox"> (rounded border-line, accent when checked).
struct SettingsCheckbox: View {
    @Binding var isOn: Bool
    var size: CGFloat = 14

    var body: some View {
        Button { isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(isOn ? Zen.ink : Zen.surface)
                .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(isOn ? Zen.ink : Zen.ink3.opacity(0.8), lineWidth: 1))
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(Zen.onInk)
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// <label class="flex items-start justify-between gap-4 p-3 rounded-lg bg-app border border-line cursor-pointer">
struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                Text(detail).font(.zen(11)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsCheckbox(isOn: $isOn).padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

/// <section class="p-5 rounded-xl bg-surface border border-line space-y-4"> with the icon header.
struct SettingsSection<Trailing: View, Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var spacing: CGFloat = 16
    var headerPadding: CGFloat = 8
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    ZIcon(icon, size: 16).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                        Text(subtitle).font(.zen(12)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.bottom, headerPadding)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(icon: String, tint: Color, title: String, subtitle: String, spacing: CGFloat = 16,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle, spacing: spacing,
                  trailing: { EmptyView() }, content: content)
    }
}

/// grid-cols-N gap-3 with equal-height cells (CSS grid rows stretch).
struct SettingsEqualColumns<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// <label class="block text-[11px] text-ink-2 mb-1">
struct SettingsFieldLabel: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    var color: Color = Zen.ink2
    init(_ text: String, size: CGFloat = 11, weight: Font.Weight = .regular, color: Color = Zen.ink2) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
    }
    var body: some View {
        Text(text).font(.zen(size, weight)).foregroundStyle(color)
    }
}

/// Text input with an optional leading icon (relative + absolute icon, pl-8) and secure mode.
struct SettingsTextField: View {
    var icon: String?
    let placeholder: String
    @Binding var text: String
    var secure = false
    var height: CGFloat = 32
    var radius: CGFloat = 8
    var background: Color = Zen.surface
    var fontSize: CGFloat = 12
    var monospacedDigits = false
    /// Adds the eye toggle (AuthLockScreen).
    var revealToggle: Binding<Bool>?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let icon { ZIcon(icon, size: 14).foregroundStyle(Zen.ink3) }
            Group {
                if secure && !(revealToggle?.wrappedValue ?? false) {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
                }
            }
            .textFieldStyle(.plain)
            .font(.zen(fontSize))
            .foregroundStyle(Zen.ink)
            .monospacedDigit()
            .onSubmit(onSubmit)
            if let revealToggle {
                Button { revealToggle.wrappedValue.toggle() } label: {
                    ZIcon(revealToggle.wrappedValue ? "eye.slash" : "eye", size: 14).foregroundStyle(Zen.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, icon == nil ? 10 : 10)
        .padding(.trailing, 10)
        .frame(height: height)
        .background(background, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
    }
}

/// <input type="number"> bound to a Double: keeps the typed text, pushes parsed values (|| fallback).
struct SettingsNumberField: View {
    var icon: String?
    let value: Double
    var fallback: Double = 0
    var height: CGFloat = 36
    let onChange: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon { ZIcon(icon, size: 14).foregroundStyle(Zen.ink3) }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.zen(12))
                .monospacedDigit()
                .foregroundStyle(Zen.ink)
                .focused($focused)
                .onChange(of: text) { _, new in
                    guard focused else { return }
                    let parsed = Double(new.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
                    let v = parsed ?? fallback
                    if v != value { onChange(v) }
                }
                .onSubmit { text = Self.format(value) }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, new in if !focused { text = Self.format(new) } }
        .onChange(of: focused) { _, f in if !f { text = Self.format(value) } }
    }

    static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }
}

/// Segmented pill buttons (theme mode / density selectors).
struct SettingsSegmentButton: View {
    let title: String
    var icon: String?
    let active: Bool
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 10
    var activeBackground: Color = Zen.surface
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { ZIcon(icon, size: 14) }
                Text(title).font(.zen(12, active ? .medium : .regular))
            }
            .foregroundStyle(active || hovering ? Zen.ink : Zen.ink2)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 6).fill(activeBackground)
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Text button that turns vermilion on hover (hover:text-negative hover:bg-negative/10).
struct SettingsDangerButton: View {
    let title: String
    var icon: String?
    var height: CGFloat = 28
    var fontSize: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { ZIcon(icon, size: 12) }
                Text(title).font(.zen(fontSize))
            }
            .foregroundStyle(hovering ? Zen.accent : Zen.ink3)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(hovering ? Zen.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "—— OR USE PASSPHRASE ——"
struct AuthOrDivider: View {
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Zen.line).frame(height: 1)
            Text(text.uppercased()).font(.zen(10)).tracking(0.5).foregroundStyle(Zen.ink3).fixedSize()
            Rectangle().fill(Zen.line).frame(height: 1)
        }
    }
}

/// Status / error callouts (bg-indigo/10 border-indigo/25 …).
struct SettingsCallout: View {
    let text: String
    var icon: String?
    var tint: Color = Zen.indigo
    var radius: CGFloat = 8
    var padding: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon { ZIcon(icon, size: 16).foregroundStyle(tint) }
            Text(text).font(.zen(12)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}
