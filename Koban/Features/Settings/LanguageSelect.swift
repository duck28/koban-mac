import SwiftUI

// OWNER: Settings & Auth (LanguageSelect.tsx). Used in the TopBar.
/// Port of src/components/LanguageSelect.tsx.
/// - `.compact` (default, TopBar / lock screen): globe + code button with the grouped dropdown.
/// - `.full` (Settings, onboarding): select-style field.
/// Choosing a language switches `L10n` immediately and stores it in `settings.language`.
struct LanguageSelect: View {
    enum Variant { case full, compact }

    @Environment(LedgerStore.self) private var store
    var variant: Variant = .compact
    /// true: the dropdown uses the TopBar menu state (closed by the click-outside layer in MainView).
    /// false: self-contained (lock screen, cards outside MainView).
    var usesTopBarMenu = true
    var onChanged: ((String) -> Void)?

    @State private var localOpen = false
    @State private var hovering = false

    init(variant: Variant = .compact, usesTopBarMenu: Bool = true, onChanged: ((String) -> Void)? = nil) {
        self.variant = variant
        self.usesTopBarMenu = usesTopBarMenu
        self.onChanged = onChanged
    }

    private var isOpen: Bool {
        usesTopBarMenu ? store.openMenu == .language : localOpen
    }

    private func setOpen(_ open: Bool) {
        if usesTopBarMenu { store.openMenu = open ? .language : nil } else { localOpen = open }
    }

    private func select(_ code: String) {
        store.selectLanguage(code)
        onChanged?(code)
        setOpen(false)
    }

    var body: some View {
        switch variant {
        case .compact: compact
        case .full: full
        }
    }

    // MARK: Compact

    private var compact: some View {
        let current = L10n.current
        return Button { setOpen(!isOpen) } label: {
            HStack(spacing: 6) {
                ZIcon("globe", size: 14).foregroundStyle(Zen.ink2)
                Text((current.code.split(separator: "-").first.map(String.init) ?? current.code).uppercased())
                    .font(.zen(11, .medium))
                    .tracking(0.3)
                ZIcon("chevron.down", size: 12).opacity(0.6)
            }
            .foregroundStyle(hovering || isOpen ? Zen.ink : Zen.ink2)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hovering || isOpen ? Zen.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Language: \(current.native) (\(current.english))")
        .overlay(alignment: .topTrailing) {
            if isOpen {
                LanguageDropdown(selected: current.code, onSelect: select)
                    .offset(y: 38)
            }
        }
        .zIndex(isOpen ? 10 : 0)
    }

    // MARK: Full

    private var full: some View {
        let current = L10n.current
        return Menu {
            ForEach(L10n.groups, id: \.self) { group in
                Section(group) {
                    ForEach(L10n.languages.filter { $0.group == group }) { l in
                        Button { select(l.code) } label: {
                            let title = l.native != l.english ? "\(l.native) — \(l.english)" : l.native
                            if l.code == current.code { Label(title, systemImage: "checkmark") } else { Text(title) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                ZIcon("globe", size: 14).foregroundStyle(Zen.ink3)
                Text(current.native != current.english ? "\(current.native) — \(current.english)" : current.native)
                    .font(.zen(12)).foregroundStyle(Zen.ink).lineLimit(1)
                Spacer(minLength: 4)
                ZIcon("chevron.down", size: 12).foregroundStyle(Zen.ink3)
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// absolute right-0 top-full mt-1.5 w-60 max-h-80 overflow-y-auto py-1.5 … divide-y divide-line/50
private struct LanguageDropdown: View {
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(L10n.groups.enumerated()), id: \.element) { idx, group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.uppercased())
                            .font(.zen(10, .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Zen.ink3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        ForEach(L10n.languages.filter { $0.group == group }) { l in
                            LanguageRow(language: l, isSelected: l.code == selected) { onSelect(l.code) }
                        }
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .top) {
                        if idx > 0 { Rectangle().fill(Zen.line.opacity(0.5)).frame(height: 1) }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.automatic)
        .frame(width: 240, height: 320)
        .zenPanel()
    }
}

private struct LanguageRow: View {
    let language: L10n.Language
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(language.native)
                    .font(.zen(12, isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected || hovering ? Zen.ink : Zen.ink2)
                if language.native != language.english {
                    Text("(\(language.english))").font(.zen(11)).foregroundStyle(Zen.ink3)
                }
                Spacer(minLength: 4)
                if isSelected { ZIcon("checkmark", size: 14).foregroundStyle(Zen.accent) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Zen.raised : (hovering ? Zen.raised.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
