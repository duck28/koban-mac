import SwiftUI

struct RootView: View {
    @Environment(LedgerStore.self) private var store

    private var appearanceKey: String {
        let s = store.state.settings
        return [(s.themePalette ?? .zen).rawValue, (s.density ?? .comfortable).rawValue,
                String(s.highContrastAmounts ?? false), s.language ?? ""].joined(separator: "|")
    }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                VStack(spacing: 12) {
                    KobanLogo(height: 28)
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .locked(let message):
                UnlockView(message: message)
            case .needsSetup:
                SetupScreen()
            case .ready:
                if store.isAppLocked {
                    UnlockView(message: nil)
                } else {
                    MainView()
                }
            case .failed(let error):
                VaultErrorView(error: error)
            }
        }
        .background(Zen.app)
        .foregroundStyle(Zen.ink)
        .tint(Zen.ink)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator(barHeight: 48))
        // Re-render everything when palette, density, high contrast or language change
        // (tokens, scaled fonts and L10n strings are read at render time).
        .id(appearanceKey)
        .overlay {
            // Never draw a dialog (import, export, setup…) on top of the app lock screen.
            if let modal = store.modal, !store.isAppLocked {
                ZenModal(onDismiss: { if modal.dismissOnBackdrop { store.dismissModal() } }, width: nil) {
                    modal.content
                }
                .id(modal.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.modal?.id)
        .onAppear { DigitKeyNavigation.install(store: store) }
    }
}

/// h-screen flex-col: TopBar, then Sidebar + main, with the toast bottom-right.
struct MainView: View {
    @Environment(LedgerStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .zIndex(2)
            if UpdateChecker.shared.updateAvailable && !UpdateChecker.shared.bannerDismissed,
               let latest = UpdateChecker.shared.latestVersion {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ZIcon("arrow.down.circle", size: 14).foregroundStyle(Zen.positive)
                        Text(L10n.t("settings.updates.available")
                            .replacingOccurrences(of: "{latest}", with: latest)
                            .replacingOccurrences(of: "{current}", with: UpdateChecker.shared.currentVersion))
                            .font(.zen(12, .medium))
                            .foregroundStyle(Zen.ink)
                    }
                    Spacer(minLength: 8)
                    Button {
                        UpdateChecker.shared.openDownloadOrRelease()
                    } label: {
                        HStack(spacing: 6) {
                            ZIcon("arrow.down.circle", size: 12)
                            Text(L10n.t("settings.updates.download").replacingOccurrences(of: "{version}", with: latest))
                        }
                        .font(.zen(11, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Zen.positive, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    ZenMiniButton(icon: "xmark", size: 14, tint: Zen.ink3, hoverTint: Zen.ink, help: L10n.t("common.close")) {
                        UpdateChecker.shared.bannerDismissed = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Zen.positive.opacity(0.12))
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.positive.opacity(0.3)).frame(height: 1) }
            }
            HStack(spacing: 0) {
                if store.isSidebarOpen {
                    SidebarView()
                        .frame(width: 256)
                        .overlay(alignment: .trailing) { Rectangle().fill(Zen.line).frame(width: 1) }
                        .transition(.move(edge: .leading))
                }
                detail(for: store.selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Zen.app)
            }
            .overlay {
                // Click outside closes the TopBar dropdowns (useClickOutside). Sits below the
                // TopBar (zIndex 2), so the dropdowns drawn by the TopBar stay clickable.
                if store.openMenu != nil {
                    Color.black.opacity(0.001)
                        .onTapGesture { store.openMenu = nil }
                }
            }
            .zIndex(1)
        }
        .onExitCommand { store.openMenu = nil }
        // Debug snapshots: KOBAN_SNAPSHOT_ACTION=setup-wizard[-<step>] opens the re-run wizard.
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            guard let name = note.userInfo?["name"] as? String, name.hasPrefix("setup-wizard") else { return }
            store.openSetupWizard(step: Int(name.split(separator: "-").last ?? "") ?? 1)
        }
        .overlay {
            if let request = store.copyRequest {
                MonthCopyModal(request: request)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = store.toast {
                ZenToast(message: toast.message, filePath: toast.filePath) { store.dismissToast() }
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.isSidebarOpen)
        .animation(.easeOut(duration: 0.18), value: store.toast)
        .animation(.easeOut(duration: 0.15), value: store.copyRequest)
    }

    @ViewBuilder
    private func detail(for tab: ViewTab) -> some View {
        switch tab {
        case .worksheet: MonthlyWorksheetView()
        case .yearlyPlanner: YearlyPlannerView()
        case .transactions: TransactionsView()
        case .accounts: AccountsView()
        case .reports: ReportsView()
        case .categories: CategoriesView()
        case .recurring: RecurringView()
        case .goals: GoalsView()
        case .backups: BackupsView()
        case .settings: SettingsView()
        }
    }
}

/// Placeholder for views that are not ported yet, laid out like a Windows page (p-6 header + card).
struct NotYetPortedView: View {
    let tab: ViewTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(tab.pageTitle)
                    .font(.zen(20))
                    .foregroundStyle(Zen.ink)

                VStack(spacing: 12) {
                    ZIcon(tab.systemImage, size: 28).foregroundStyle(Zen.ink3)
                    Text("Not yet available on macOS")
                        .font(.zen(14, .medium))
                        .foregroundStyle(Zen.ink)
                    Text("This view is still being ported from the Windows build (src/components/\(tab.windowsSource)).\nYour data for it is kept intact in the shared koban.db.")
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
                .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .padding(24)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
        }
    }
}
