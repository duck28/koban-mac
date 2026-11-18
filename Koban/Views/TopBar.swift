import SwiftUI

/// Port of src/components/TopBar.tsx: 48 pt bar with sidebar toggle, logo, workspace switcher,
/// month navigator, quick actions and the Import / Export buttons.
struct TopBar: View {
    @Environment(LedgerStore.self) private var store

    /// Room for the traffic lights, which WindowConfigurator centers in this bar.
    static let trafficLightInset: CGFloat = 78

    var body: some View {
        // Windows hides button labels at narrow widths (sm/md breakpoints); here the compact
        // layout is used whenever the full one doesn't fit (e.g. long translations).
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .padding(.leading, Self.trafficLightInset)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(Zen.surface)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    private func bar(compact: Bool) -> some View {
        let settings = store.state.settings

        return HStack(spacing: 8) {
            // Left: sidebar toggle, logo, workspace switcher
            HStack(spacing: 6) {
                Button { store.toggleSidebar() } label: { ZIcon("sidebar.left") }
                    .buttonStyle(.zen(.icon, radius: 6, padding: 6, active: store.isSidebarOpen))
                    .help(L10n.t("topbar.toggleSidebar"))

                KobanLogo(height: 20)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)

                Rectangle().fill(Zen.line).frame(width: 1, height: 16).padding(.horizontal, 4)

                WorkspaceSwitcher(active: settings.activeWorkspace, compact: compact) { store.setWorkspace($0) }
            }
            .fixedSize()

            Spacer(minLength: 8)

            MonthNavigator()

            Spacer(minLength: 8)

            // Right: quick add, backup indicator, theme, language, settings, setup, lock, import, export
            HStack(spacing: 4) {
                Button { store.openQuickAdd() } label: {
                    HStack(spacing: 6) {
                        ZIcon("plus", size: 14).foregroundStyle(Zen.accent)
                        if !compact { Text(L10n.t("topbar.addEntry")) }
                    }
                }
                .buttonStyle(.zen(.raised, radius: 6, padding: 10))
                .help(L10n.t("topbar.addEntryTip").replacingOccurrences(of: "Ctrl+", with: "⌘"))

                Button { store.manualBackup() } label: {
                    ZIcon("checkmark.circle")
                        .foregroundStyle(store.isSaving ? Zen.warning
                                         : (!settings.localBackupDir.isEmpty && settings.autoBackup) ? Zen.positive : Zen.ink3)
                }
                .buttonStyle(.zenIcon)
                .help((settings.localBackupDir.isEmpty
                       ? L10n.t("topbar.backupTipDefault")
                       : L10n.tf("topbar.backupTipActive", ["dir": settings.localBackupDir]))
                    .replacingOccurrences(of: "Ctrl+", with: "⌘"))

                Button { store.cycleTheme() } label: { ZIcon(themeIcon(settings.theme)) }
                    .buttonStyle(.zenIcon)
                    .help(L10n.tf("topbar.themeTip", ["theme": L10n.t("settings.themeMode.\(settings.theme.rawValue)")]))

                LanguageSelect()

                Button { store.selectedTab = .settings } label: { ZIcon("slider.horizontal.3") }
                    .buttonStyle(.zenIcon)
                    .help(L10n.t("topbar.settingsTip"))

                Button { store.openSetupWizard() } label: { ZIcon("sparkles") }
                    .buttonStyle(.zenIcon)
                    .help(L10n.t("topbar.wizardTip"))

                Button { store.lockVault() } label: { ZIcon("lock") }
                    .buttonStyle(.zenIcon)
                    .help(L10n.t("topbar.lock").replacingOccurrences(of: "Ctrl+", with: "⌘"))

                Button { store.openImport() } label: {
                    HStack(spacing: 6) {
                        ZIcon("square.and.arrow.up", size: 14).foregroundStyle(Zen.indigo)
                        if !compact { Text(L10n.t("topbar.import")).foregroundStyle(Zen.ink) }
                    }
                }
                .buttonStyle(.zen(.outline, radius: 6, padding: 10))
                .help(L10n.t("topbar.importTip"))

                Button { store.toggleMenu(.export) } label: {
                    HStack(spacing: 6) {
                        Text(L10n.t("topbar.export"))
                        ZIcon("chevron.down", size: 14).opacity(0.7)
                    }
                }
                .buttonStyle(.zen(.ink, radius: 6, padding: 12))
                .help(L10n.t("topbar.exportTip"))
                .overlay(alignment: .topTrailing) {
                    if store.openMenu == .export {
                        ExportMenu().offset(y: 40)
                    }
                }
            }
            .fixedSize()
        }
    }

    private func themeIcon(_ theme: ThemePreference) -> String {
        switch theme {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "display"
        }
    }
}

/// Home | Freelancer | Combined segmented switcher (bg-raised/70 p-0.5 rounded-lg).
struct WorkspaceSwitcher: View {
    let active: ActiveWorkspace
    /// Only the active segment keeps its label.
    var compact = false
    let onChange: (ActiveWorkspace) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.home, icon: "house", tint: Zen.accent)
            segment(.freelancer, icon: "briefcase", tint: Zen.indigo)
            segment(.combined, icon: "square.3.layers.3d", tint: Zen.positive)
        }
        .padding(2)
        .background(Zen.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line.opacity(0.6), lineWidth: 1))
    }

    private func segment(_ ws: ActiveWorkspace, icon: String, tint: Color) -> some View {
        let isActive = ws == active
        return Button { onChange(ws) } label: {
            HStack(spacing: 6) {
                ZIcon(icon, size: 14).foregroundStyle(tint)
                if !compact || isActive {
                Text(ws.title)
                    .font(.zen(12, isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Zen.ink : Zen.ink2)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Zen.surface)
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ws.help)
    }
}

/// ‹ November 2026 ⌄ › with the year / month grid dropdown.
struct MonthNavigator: View {
    @Environment(LedgerStore.self) private var store

    var body: some View {
        let s = store.state.settings
        HStack(spacing: 4) {
            Button { store.shiftMonth(by: -1) } label: { ZIcon("chevron.left") }
                .buttonStyle(.zenIcon)
                .help(L10n.t("topbar.prevMonth") + " (⌘[)")

            Button { store.toggleMenu(.month) } label: {
                HStack(spacing: 6) {
                    Text("\(L10n.monthName(s.activeMonth)) \(String(s.activeYear))")
                        .font(.zen(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Zen.ink)
                    ZIcon("chevron.down", size: 14).foregroundStyle(Zen.ink3)
                }
            }
            .buttonStyle(.zen(.ghost, radius: 6, padding: 12, fontSize: 13, active: store.openMenu == .month))
            .overlay(alignment: .top) {
                if store.openMenu == .month {
                    MonthGridMenu().offset(y: 40)
                }
            }

            Button { store.shiftMonth(by: 1) } label: { ZIcon("chevron.right") }
                .buttonStyle(.zenIcon)
                .help(L10n.t("topbar.nextMonth") + " (⌘])")
        }
        .fixedSize()
    }
}

private struct MonthGridMenu: View {
    @Environment(LedgerStore.self) private var store

    var body: some View {
        let s = store.state.settings
        VStack(spacing: 8) {
            HStack {
                ZenMiniButton(icon: "chevron.left", size: 16, tint: Zen.ink2) {
                    store.setMonth(year: s.activeYear - 1, month: s.activeMonth)
                }
                Spacer()
                Text(String(s.activeYear)).font(.zen(13, .semibold)).monospacedDigit().foregroundStyle(Zen.ink)
                Spacer()
                ZenMiniButton(icon: "chevron.right", size: 16, tint: Zen.ink2) {
                    store.setMonth(year: s.activeYear + 1, month: s.activeMonth)
                }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(0..<12, id: \.self) { idx in
                    MonthCell(label: L10n.monthName(idx + 1, short: true), active: idx + 1 == s.activeMonth) {
                        store.setMonth(year: s.activeYear, month: idx + 1)
                        store.openMenu = nil
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 256)
        .zenPanel()
        .fixedSize()
    }
}

private struct MonthCell: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.zen(12, active ? .medium : .regular))
                .foregroundStyle(active ? Zen.onInk : (hovering ? Zen.ink : Zen.ink2))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(active ? Zen.ink : (hovering ? Zen.raised : .clear), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ExportMenu: View {
    @Environment(LedgerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZenEyebrow(L10n.t("topbar.exportMenuHeader")).padding(.horizontal, 12).padding(.vertical, 4)
            item("tablecells", tint: Zen.positive, title: L10n.t("topbar.exportExcelTitle"),
                 detail: L10n.t("topbar.exportExcelDesc"), bold: true) { store.exportExcel() }
            item("arrow.down.doc", tint: Zen.indigo, title: L10n.t("topbar.exportBudgetCsvTitle"),
                 detail: L10n.t("topbar.exportBudgetCsvDesc")) { store.exportBudgetCSV() }
            item("arrow.down.doc", tint: Zen.ink2, title: L10n.t("topbar.exportTxCsvTitle"),
                 detail: L10n.t("topbar.exportTxCsvDesc")) { store.exportTransactionsCSV() }
            Rectangle().fill(Zen.line).frame(height: 1).padding(.vertical, 4)
            item("square.and.arrow.up", tint: Zen.accent, title: L10n.t("topbar.importItemTitle"),
                 detail: L10n.t("topbar.importItemDesc")) { store.openImport() }
            item("cylinder", tint: Zen.ink2, title: L10n.t("topbar.backupNowTitle").replacingOccurrences(of: "Ctrl+", with: "⌘"),
                 detail: L10n.t("topbar.backupNowDesc")) { store.manualBackup() }
        }
        .padding(.vertical, 6)
        .frame(width: 288)
        .zenPanel()
        .fixedSize()
    }

    private func item(_ icon: String, tint: Color, title: String, detail: String, bold: Bool = false,
                      action: @escaping () -> Void) -> some View {
        MenuRow(action: {
            store.openMenu = nil
            action()
        }) {
            HStack(alignment: .top, spacing: 10) {
                ZIcon(icon).foregroundStyle(tint).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.zen(12, bold ? .medium : .regular)).foregroundStyle(Zen.ink)
                    Text(detail).font(.zen(11)).foregroundStyle(Zen.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Full-width menu row with hover highlight (px-3 py-2 hover:bg-raised).
struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Zen.raised : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
