import SwiftUI

// OWNER: Onboarding. Port of src/components/OnboardingModal.tsx.

/// First-run screen (RootView, phase == .needsSetup): the 4-step setup wizard on the app background.
struct SetupScreen: View {
    var body: some View {
        ZStack {
            Zen.app.ignoresSafeArea()
            WindowDragArea().ignoresSafeArea()
            ScrollView(.vertical) {
                SetupWizardView(isFirstRun: true)
                    .zenPanel(radius: 16)
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                    .padding(16)
                    .padding(.top, 32)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The wizard panel (max-w-4xl). Used full-screen on first run and as a window-wide modal
/// when re-running setup (LedgerStore.openSetupWizard()).
struct SetupWizardView: View {
    @Environment(LedgerStore.self) private var store
    let isFirstRun: Bool
    var initialStep: Int = 1
    /// Keeps the wizard's state when it is re-presented (returning from the Import modal).
    var existingModel: SetupWizardModel?
    @State private var model: SetupWizardModel?

    var body: some View {
        Group {
            if let model {
                SetupWizardPanel(model: model)
            } else {
                Color.clear.frame(width: SetupWizardPanel.width, height: 560)
            }
        }
        .onAppear {
            if model == nil, let existingModel {
                model = existingModel
            } else if model == nil {
                model = SetupWizardModel(base: store.setupBaseState, auth: store.loadSetupAuthConfig(),
                                         isFirstRun: isFirstRun, initialStep: initialStep)
            }
        }
    }
}

struct SetupWizardPanel: View {
    static let width: CGFloat = 896

    @Environment(LedgerStore.self) private var store
    @Bindable var model: SetupWizardModel
    @State private var windowHeight: CGFloat = 880
    @State private var bodyContentHeight: CGFloat = 0

    private static let stepsMeta: [(num: Int, title: String, subtitle: String)] = [
        (1, "1. Profile & Currency", "Choose Home, Freelancer, or Both"),
        (2, "2. Budget Categories", "Select & customize categories"),
        (3, "3. Accounts & Net Worth", "Liquid & retirement (or skip)"),
        (4, "4. Vault & Preferences", "Backups, encryption & behavior"),
    ]

    /// onClose is only offered when re-running setup over a completed ledger.
    private var canClose: Bool { model.setupCompleted && !model.isFirstRun }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBar
            stepBody
            footer
        }
        .frame(width: Self.width)
        .modifier(WindowHeightReader(height: $windowHeight))
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            // KOBAN_SNAPSHOT_ACTION=setup-step-<n> / setup-finish (debug snapshots only).
            guard let name = note.userInfo?["name"] as? String, name.hasPrefix("setup-") else { return }
            if let n = Int(name.split(separator: "-").last ?? ""), (1...4).contains(n) { model.step = n }
            if name.contains("skip") { model.skipAccountsSetup = true }
            if name == "setup-finish" { model.finish(store: store) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            // KOBAN_SNAPSHOT_ACTION=webdav-connect[-filled]: the first-run "Open Vault from WebDAV…" form.
            guard let name = note.userInfo?["name"] as? String, name.hasPrefix("webdav-connect"),
                  model.isFirstRun else { return }
            store.presentWebDavConnect()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 14) {
                KobanLogo(height: 22)
                Rectangle().fill(Zen.line).frame(width: 1, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Setup Wizard").font(.zen(16, .medium)).foregroundStyle(Zen.ink).tracking(-0.2)
                        Text("Step \(model.step) of 4")
                            .font(.zen(10, .medium)).foregroundStyle(Zen.ink2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Zen.raised, in: Capsule())
                            .overlay(Capsule().strokeBorder(Zen.line, lineWidth: 1))
                    }
                    Text(Self.stepsMeta[model.step - 1].subtitle).font(.zen(12)).foregroundStyle(Zen.ink2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                LanguageSelect()
                Button {
                    store.openImportFromSetupWizard(model: model)
                } label: {
                    HStack(spacing: 6) {
                        ZIcon("square.and.arrow.up", size: 14).foregroundStyle(Zen.indigo)
                        Text("Import Existing Data…").foregroundStyle(Zen.ink)
                    }
                }
                .buttonStyle(.zen(.raised, height: 32, radius: 8, padding: 12, fontSize: 12))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1).allowsHitTesting(false))
                .help("Import existing data or restore a backup")

                if canClose {
                    ZenMiniButton(icon: "xmark", size: 16, tint: Zen.ink3, hoverTint: Zen.ink, help: "Close") {
                        store.dismissModal()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Zen.app.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    // MARK: Progress bar

    private var progressBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.stepsMeta, id: \.num) { s in
                StepTab(title: s.title, subtitle: s.subtitle,
                        isActive: model.step == s.num, isCompleted: model.step > s.num) { model.step = s.num }
                if s.num < 4 { Rectangle().fill(Zen.line).frame(width: 1) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Zen.app.opacity(0.3))
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    // MARK: Body

    private var stepBody: some View {
        let maxHeight = max(380, windowHeight * 0.68)
        return ScrollView(.vertical) {
            Group {
                switch model.step {
                case 1: SetupStepProfile(model: model)
                case 2: SetupStepCategories(model: model, listMaxHeight: windowHeight * 0.43)
                case 3: SetupStepAccounts(model: model)
                default: SetupStepVault(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyContentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(bodyContentHeight, 380), maxHeight))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if model.step > 1 {
                    Button { model.step -= 1 } label: {
                        HStack(spacing: 6) {
                            ZIcon("arrow.left", size: 14)
                            Text("Back")
                        }
                        .foregroundStyle(Zen.ink)
                    }
                    .buttonStyle(.zen(.outline, height: 36, radius: 8, padding: 16, fontSize: 12))
                } else if canClose {
                    Button("Cancel") { store.dismissModal() }
                        .buttonStyle(.zen(.ghost, height: 36, radius: 8, padding: 16, fontSize: 12))
                } else if model.isFirstRun {
                    // macOS: switch to an existing koban.db (e.g. copied from Windows) instead of setting up.
                    Button { store.openExistingDatabase() } label: {
                        HStack(spacing: 6) {
                            ZIcon("folder", size: 14)
                            Text("Open Existing koban.db…")
                        }
                    }
                    .buttonStyle(.zen(.ghost, height: 36, radius: 8, padding: 16, fontSize: 12))
                    .help("Use an existing encrypted koban.db (e.g. from Windows or a synced folder)")

                    // New device: download the vault another device keeps on WebDAV (WEBDAV-SPEC §6).
                    Button { store.presentWebDavConnect() } label: {
                        HStack(spacing: 6) {
                            ZIcon("icloud.and.arrow.down", size: 14)
                            Text("Open Vault from WebDAV…")
                        }
                    }
                    .buttonStyle(.zen(.ghost, height: 36, radius: 8, padding: 16, fontSize: 12))
                    .help("Download your vault from a WebDAV server (Nextcloud, ownCloud, NAS …) and use it as primary storage")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if model.step == 3 {
                    Button {
                        model.skipAccountsSetup = true
                        model.step = 4
                    } label: {
                        HStack(spacing: 6) {
                            ZIcon("forward", size: 14)
                            Text("Skip This Step for Setup Later")
                        }
                    }
                    .buttonStyle(.zen(.outline, height: 36, radius: 8, padding: 16, fontSize: 12))
                }

                if model.step < 4 {
                    Button {
                        if model.step == 3 { model.skipAccountsSetup = false }
                        model.step += 1
                    } label: {
                        HStack(spacing: 8) {
                            Text(model.step == 1 ? "Next: Categories"
                                 : model.step == 2 ? "Next: Accounts & Net Worth" : "Next: Vault & Preferences")
                                .fontWeight(.medium)
                            ZIcon("arrow.right", size: 14)
                        }
                    }
                    .buttonStyle(.zen(.ink, height: 36, radius: 8, padding: 20, fontSize: 12))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button { model.finish(store: store) } label: {
                        HStack(spacing: 8) {
                            ZIcon("sparkles", size: 14)
                            Text(model.setupCompleted ? "Save Setup & Preferences" : "Finish Setup & Launch Koban")
                                .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.zen(.ink, height: 36, radius: 8, padding: 20, fontSize: 12))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Zen.app.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }
}

/// One column of the 4-step progress bar.
private struct StepTab: View {
    let title: String
    let subtitle: String
    let isActive: Bool
    let isCompleted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.zen(11, .medium)).foregroundStyle(isActive ? Zen.ink : Zen.ink2)
                    Spacer(minLength: 4)
                    if isCompleted {
                        ZIcon("checkmark", size: 14, weight: .regular).foregroundStyle(Zen.positive)
                    }
                }
                Text(subtitle).font(.zen(10)).foregroundStyle(Zen.ink3).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .bottom) {
                if isActive { Rectangle().fill(Zen.ink).frame(height: 2) }
            }
            .opacity(!isActive && !isCompleted && !hovering ? 0.65 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isActive { return Zen.surface }
        if isCompleted { return Zen.raised.opacity(hovering ? 0.7 : 0.4) }
        return .clear
    }
}
