import SwiftUI

/// Port of src/components/Sidebar.tsx (w-64, Workspace / Groups tabs, nav, monthly summary, backup status).
struct SidebarView: View {
    @Environment(LedgerStore.self) private var store
    @State private var panel: Panel = .nav

    enum Panel { case nav, groups }

    var body: some View {
        let state = store.state
        let workspace = state.settings.activeWorkspace
        let summary = store.monthSummary(monthKey: state.activeMonthKey, workspace: workspace)

        VStack(spacing: 0) {
            // Top tabs: Workspace vs Groups (n)
            HStack(spacing: 16) {
                tab(L10n.t("sidebar.workspace"), .nav)
                tab("\(L10n.t("sidebar.groups")) (\(summary.groups.count))", .groups)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            if panel == .nav {
                NavPanel(summary: summary)
            } else {
                GroupsPanel(summary: summary)
            }
        }
        .background(Zen.surface)
    }

    private func tab(_ title: String, _ value: Panel) -> some View {
        Button { panel = value } label: {
            Text(title)
                .font(.zen(12))
                .tracking(0.3)
                .foregroundStyle(panel == value ? Zen.ink : Zen.ink3)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if panel == value { Rectangle().fill(Zen.ink).frame(height: 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NavPanel: View {
    @Environment(LedgerStore.self) private var store
    let summary: MonthSummaryMetrics

    var body: some View {
        let state = store.state
        let settings = state.settings
        let workspace = settings.activeWorkspace
        let monthTx = state.transactions.filter {
            $0.monthKey == state.activeMonthKey && workspace.includes($0.mode)
        }.count
        let netWorth = store.netWorthMetrics(workspace: workspace, monthlyOutflowReference: summary.totalOutflowActual)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ZenEyebrow(workspace == .home ? "Home Budget Ledger"
                               : workspace == .freelancer ? "Freelancer Business" : "Combined Ledger")
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)

                    ForEach(ViewTab.allCases) { tab in
                        NavItem(tab: tab, badge: badge(for: tab, monthTx: monthTx, accounts: netWorth.accounts.count))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)

            // Bottom summary & backup status
            VStack(spacing: 10) {
                MonthSnapshotCard(summary: summary, netWorth: netWorth)
                BackupStatusCard()
                Button { store.openSetupWizard() } label: {
                    HStack(spacing: 6) {
                        ZIcon("sparkles", size: 12).foregroundStyle(Zen.accent)
                        Text("Re-run Setup / Change Mode").font(.zen(11))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(.ghost, height: 28, radius: 6, padding: 10, fontSize: 11))
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1).padding(.horizontal, 8) }
        }
    }

    private func badge(for tab: ViewTab, monthTx: Int, accounts: Int) -> Int? {
        let state = store.state
        switch tab {
        case .worksheet: return summary.groups.count
        case .transactions: return monthTx > 0 ? monthTx : nil
        case .accounts: return accounts > 0 ? accounts : nil
        case .recurring:
            let n = state.recurringRules.filter(\.active).count
            return n > 0 ? n : nil
        case .goals: return state.savingsGoals.isEmpty ? nil : state.savingsGoals.count
        default: return nil
        }
    }
}

private struct NavItem: View {
    @Environment(LedgerStore.self) private var store
    let tab: ViewTab
    let badge: Int?
    @State private var hovering = false

    var body: some View {
        let selected = store.selectedTab == tab
        Button { store.selectedTab = tab } label: {
            HStack(spacing: 10) {
                ZIcon(tab.systemImage).foregroundStyle(hovering || selected ? Zen.ink : Zen.ink2)
                Text(tab.title)
                    .font(.zen(13, selected ? .medium : .regular))
                    .foregroundStyle(selected || hovering ? Zen.ink : Zen.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)").font(.zen(11)).zenAmount().foregroundStyle(Zen.ink3)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(selected || hovering ? Zen.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                if selected {
                    Circle().fill(Zen.accent).frame(width: 4, height: 4).padding(.leading, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MonthSnapshotCard: View {
    @Environment(LedgerStore.self) private var store
    let summary: MonthSummaryMetrics
    let netWorth: NetWorthSummaryMetrics

    var body: some View {
        let currency = store.state.settings.currency
        let workspace = store.state.settings.activeWorkspace

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZenEyebrow("Monthly Summary")
                Spacer()
                Text(summary.monthKey).font(.zen(11)).zenAmount().foregroundStyle(Zen.ink2)
            }

            VStack(spacing: 4) {
                row("Total Income", KobanFormat.currency(summary.incomeActual, code: currency), Zen.positive, .medium)
                row("Total Expenses", KobanFormat.currency(summary.totalOutflowActual, code: currency), Zen.ink)
                Rectangle().fill(Zen.line).frame(height: 1).padding(.vertical, 4)
                HStack {
                    Text(L10n.t("finance.net").uppercased()).foregroundStyle(Zen.ink)
                    Spacer()
                    Text(KobanFormat.currency(summary.netActual, code: currency))
                        .zenAmount()
                        .foregroundStyle(summary.netActual >= 0 ? Zen.positive : Zen.accent)
                }
                .font(.zen(12, .medium))
            }

            if workspace != .home {
                HStack {
                    Text("Deductible Exp.").foregroundStyle(Zen.ink3)
                    Spacer()
                    Text(KobanFormat.currency(summary.deductibleExpensesActual, code: currency))
                        .zenAmount().foregroundStyle(Zen.indigo)
                }
                .font(.zen(11))
                .padding(.top, 6)
                .overlay(alignment: .top) { Rectangle().fill(Zen.line.opacity(0.7)).frame(height: 1) }
            }

            Button { store.selectedTab = .accounts } label: {
                VStack(spacing: 2) {
                    HStack {
                        Text(L10n.t("finance.netWorth")).foregroundStyle(Zen.ink2)
                        Spacer()
                        Text(KobanFormat.currency(netWorth.netWorth, code: currency))
                            .zenAmount()
                            .foregroundStyle(netWorth.netWorth >= 0 ? Zen.positive : Zen.accent)
                    }
                    .font(.zen(11, .medium))
                    HStack {
                        Text("Liquid / Retirement")
                        Spacer()
                        Text("\(KobanFormat.currency(netWorth.liquidAssets, code: currency)) / \(KobanFormat.currency(netWorth.retirementAssets, code: currency))")
                            .zenAmount()
                    }
                    .font(.zen(10))
                    .foregroundStyle(Zen.ink3)
                }
                .padding(.top, 6)
                .overlay(alignment: .top) { Rectangle().fill(Zen.line.opacity(0.7)).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Accounts & Net Worth Tracker")
        }
        .padding(12)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func row(_ label: String, _ value: String, _ color: Color, _ weight: Font.Weight = .regular) -> some View {
        HStack {
            Text(label).foregroundStyle(Zen.ink2)
            Spacer()
            Text(value).zenAmount().fontWeight(weight).foregroundStyle(color)
        }
        .font(.zen(12))
    }
}

private struct BackupStatusCard: View {
    @Environment(LedgerStore.self) private var store

    var body: some View {
        let s = store.state.settings
        let dir = s.localBackupDir
        let active = !dir.isEmpty && s.autoBackup
        let problem = store.lastSaveError != nil || store.lastBackupError != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ZIcon(active && !problem ? "checkmark.circle" : "exclamationmark.circle", size: 14)
                    .foregroundStyle(problem ? Zen.accent : (active ? Zen.positive : Zen.ink3))
                Text(store.lastSaveError != nil ? "Save Failed"
                     : store.lastBackupError != nil ? "Auto-Backup Failed"
                     : (active ? "Auto-Backup Active" : "Local SQLite Saved"))
                    .font(.zen(11, .medium))
                    .foregroundStyle(problem ? Zen.accent : Zen.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !dir.isEmpty {
                    ZenMiniButton(icon: "arrow.up.right.square", size: 12, help: "Reveal Backup Folder in Finder") {
                        store.revealBackupFolder()
                    }
                }
            }
            Button { store.selectedTab = .backups } label: {
                Text(store.lastSaveError ?? store.lastBackupError
                     ?? (s.backupDirIsForeign ? "Backup folder is from another device — choose one for this Mac →"
                         : dir.isEmpty ? "Choose auto-backup path →" : dir))
                    .font(.zen(11))
                    .foregroundStyle(Zen.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(dir.isEmpty ? "Click to choose an automatic backup folder" : dir)
        }
        .padding(10)
        .background(Zen.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }
}

private struct GroupsPanel: View {
    @Environment(LedgerStore.self) private var store
    let summary: MonthSummaryMetrics

    var body: some View {
        let currency = store.state.settings.currency
        ScrollView {
            VStack(spacing: 4) {
                ForEach(summary.groups) { gs in
                    GroupRow(gs: gs, currency: currency) { store.selectedTab = .worksheet }
                }
            }
            .padding(8)
        }
    }
}

private struct GroupRow: View {
    let gs: GroupComputedSummary
    let currency: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let pct = gs.totalBudget > 0 ? min(1, gs.totalActual / gs.totalBudget) : 0
        let over = gs.group.kind != .income && gs.totalActual > gs.totalBudget

        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(Color(hexString: gs.group.color)).frame(width: 8, height: 8)
                    Text(gs.group.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(KobanFormat.currency(gs.totalActual, code: currency))
                        .font(.zen(11)).zenAmount().foregroundStyle(Zen.ink2)
                }
                HStack {
                    Text("Budget: \(KobanFormat.currency(gs.totalBudget, code: currency))")
                    Spacer()
                    Text("\(gs.totalDifference >= 0 ? "+" : "")\(KobanFormat.currency(gs.totalDifference, code: currency))")
                        .foregroundStyle(gs.totalDifference >= 0 ? Zen.positive : Zen.accent)
                }
                .font(.zen(10))
                .zenAmount()
                .foregroundStyle(Zen.ink3)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Zen.line)
                        Capsule().fill(over ? Zen.accent : Color(hexString: gs.group.color))
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(height: 4)
            }
            .padding(8)
            .background(hovering ? Zen.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
