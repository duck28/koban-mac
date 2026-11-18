import AppKit
import SwiftUI

// OWNER: Settings & Auth.
/// Port of src/components/SettingsView.tsx (Settings & Behavioral Options).
/// Windows Hello / passkey enrollment → Touch ID (TouchIDKeychain); everything else 1:1.
struct SettingsView: View {
    @Environment(LedgerStore.self) private var store

    @State private var newCredentialLabel = "Touch ID (This Mac)"
    @State private var newPassphrase = ""
    @State private var authStatusMsg: String?
    @State private var isRegisteringPasskey = false

    private var auth: AuthCenter { AuthCenter.shared }
    private var settings: AppSettings { store.state.settings }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    languageSection
                    loginSection.id("login")
                    copySection.id("copy")
                    importSection.id("import")
                    workspaceSection.id("workspace")
                    themeSection.id("theme")
                    backupSection.id("backups")
                    DbLocationCard().id("db")
                    WebDavSyncCard().id("webdav")
                    updatesSection.id("updates")
                }
                .padding(24)
                .frame(maxWidth: 1024)
                .frame(maxWidth: .infinity)
            }
            .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
                // KOBAN_SNAPSHOT_ACTION=settings-scroll-<section id> (debug snapshots of lower sections)
                guard let name = note.userInfo?["name"] as? String, name.hasPrefix("settings-scroll-") else { return }
                proxy.scrollTo(String(name.dropFirst("settings-scroll-".count)), anchor: .top)
            }
        }
        .onAppear { auth.refresh(store: store) }
    }

    // MARK: - Bindings

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { store.state.settings[keyPath: keyPath] },
                set: { v in store.applySettingsChange { $0[keyPath: keyPath] = v } })
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool?>, default def: Bool) -> Binding<Bool> {
        Binding(get: { store.state.settings[keyPath: keyPath] ?? def },
                set: { v in store.applySettingsChange { $0[keyPath: keyPath] = v } })
    }

    private func authBinding<T>(_ keyPath: WritableKeyPath<AuthConfig, T>) -> Binding<T> {
        Binding(get: { auth.config[keyPath: keyPath] },
                set: { v in
                    var next = auth.config
                    next[keyPath: keyPath] = v
                    store.updateAuthConfig(next)
                })
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("settings.subtitle").uppercased())
                    .font(.zen(11, .medium))
                    .tracking(1.5)
                    .foregroundStyle(Zen.ink3)
                Text(L10n.t("settings.title"))
                    .font(.zen(20, .medium))
                    .tracking(-0.3)
                    .foregroundStyle(Zen.ink)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button { store.lockVault() } label: {
                    HStack(spacing: 6) {
                        ZIcon("lock", size: 14).foregroundStyle(Zen.indigo)
                        Text(L10n.t("settings.lockNow")).foregroundStyle(Zen.ink)
                    }
                }
                .buttonStyle(.zen(.raised, height: 32, radius: 8, padding: 14))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                .help(L10n.t("settings.lockNowTip").replacingOccurrences(of: "Ctrl+", with: "⌘"))

                Button { store.openSetupWizard() } label: {
                    HStack(spacing: 6) {
                        ZIcon("sparkles", size: 14).foregroundStyle(Zen.accent)
                        Text(L10n.t("settings.wizard")).foregroundStyle(Zen.ink)
                    }
                }
                .buttonStyle(.zen(.outline, height: 32, radius: 8, padding: 14))
            }
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    // MARK: - Language

    private var languageSection: some View {
        SettingsSection(icon: "globe", tint: Zen.accent, title: L10n.t("settings.language.title"),
                        subtitle: L10n.t("settings.language.desc"), spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsFieldLabel(L10n.t("settings.language.label"))
                LanguageSelect(variant: .full, usesTopBarMenu: false)
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    // MARK: - Login & Touch ID

    private var loginSection: some View {
        let config = auth.config
        return SettingsSection(
            icon: "touchid", tint: Zen.indigo, title: L10n.t("settings.login.title"),
            subtitle: L10n.t("settings.login.descMac")
        ) {
            HStack(spacing: 4) {
                ZIcon("checkmark.circle", size: 12)
                Text(config.enabled ? L10n.t("settings.login.enabled") : L10n.t("settings.login.disabled"))
                    .font(.zen(11, .medium))
            }
            .foregroundStyle(config.enabled ? Zen.positive : Zen.ink3)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(config.enabled ? Zen.positive.opacity(0.12) : Zen.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(config.enabled ? Zen.positive.opacity(0.3) : Zen.line, lineWidth: 1))
        } content: {
            if let authStatusMsg {
                SettingsCallout(text: authStatusMsg)
            }

            SettingsEqualColumns {
                SettingsToggleRow(title: L10n.t("settings.login.require"),
                                  detail: L10n.t("settings.login.requireDesc"),
                                  isOn: authBinding(\.enabled))
                SettingsToggleRow(title: L10n.t("settings.login.autoPrompt"),
                                  detail: L10n.t("settings.login.autoPromptDesc"),
                                  isOn: authBinding(\.autoPromptPasskeyOnLaunch))
            }

            SettingsEqualColumns {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("settings.login.ownerName"), weight: .medium)
                    SettingsTextField(placeholder: L10n.t("settings.login.ownerPlaceholder"), text: authBinding(\.userDisplayName))
                }
                .padding(12)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("settings.login.autoLock"), weight: .medium)
                    SettingsMenuField(options: [(0, L10n.t("settings.login.autoLockNever")),
                                                (5, L10n.t("settings.login.autoLock5")),
                                                (15, L10n.t("settings.login.autoLock15")),
                                                (30, L10n.t("settings.login.autoLock30")),
                                                (60, L10n.t("settings.login.autoLock60"))],
                                      selection: authBinding(\.autoLockMinutes), background: Zen.surface)
                }
                .padding(12)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }

            credentialsBox(config)
            masterPassphraseForm(config)
        }
    }

    private func credentialsBox(_ config: AuthConfig) -> some View {
        let count = config.passkeys.count
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tf("settings.login.enrolledTitleMac", ["count": count])).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                Text(L10n.t("settings.login.enrolledDescMac"))
                    .font(.zen(11)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
            }

            if count > 0 {
                VStack(spacing: 6) {
                    ForEach(config.passkeys) { pk in
                        credentialRow(name: pk.name,
                                      detail: "\(pk.isWindowsHelloNative ? L10n.t("settings.login.nativeVerifierMac") : L10n.t("settings.login.webauthnVerifierMac")) • \(L10n.t("settings.login.addedPrefix")) \(Self.date(pk.createdAt))",
                                      icon: pk.isWindowsHelloNative ? "laptopcomputer" : "key.horizontal") {
                            var next = auth.config
                            next.passkeys.removeAll { $0.id == pk.id }
                            store.updateAuthConfig(next)
                            if !auth.hasMacCredential { TouchIDKeychain.removeSecret(account: auth.account) }
                            authStatusMsg = L10n.t("settings.login.removedPasskey")
                        }
                    }
                }
            } else {
                Text(L10n.t("settings.login.noneEnrolledMac"))
                    .font(.zen(12)).foregroundStyle(Zen.ink3).padding(.vertical, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("settings.login.credLabel"), size: 10, color: Zen.ink3)
                    SettingsTextField(placeholder: L10n.t("settings.login.credPlaceholderMac"), text: $newCredentialLabel)
                }
                .frame(minWidth: 160, maxWidth: .infinity)

                Button { Task { await registerTouchID() } } label: {
                    HStack(spacing: 6) {
                        ZIcon("plus", size: 14)
                        Text(L10n.t("settings.login.enrollBtn")).fontWeight(.medium)
                    }
                }
                .buttonStyle(.zen(.ink, height: 32, radius: 8, padding: 14))
                .disabled(isRegisteringPasskey || !TouchIDKeychain.anyAuthAvailable)
                .help(TouchIDKeychain.anyAuthAvailable ? L10n.t("settings.login.enrollTouchIdHelp")
                                                       : L10n.t("settings.login.touchIdUnavailableHelp"))
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func credentialRow(name: String, detail: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                ZIcon(icon, size: 14).foregroundStyle(Zen.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    Text(detail).font(.zen(10)).foregroundStyle(Zen.ink3)
                }
            }
            Spacer(minLength: 8)
            SettingsDangerButton(title: L10n.t("common.remove"), icon: "trash", action: onRemove)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func masterPassphraseForm(_ config: AuthConfig) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsFieldLabel(config.hasMasterPassphrase ? L10n.t("settings.login.updatePassphraseLabel")
                                                              : L10n.t("settings.login.setPassphraseLabel"), weight: .medium)
                SettingsTextField(icon: "key", placeholder: L10n.t("settings.login.passphrasePlaceholder"), text: $newPassphrase,
                                  secure: true, onSubmit: setMasterPassphrase)
            }
            .frame(minWidth: 180, maxWidth: .infinity)

            Button(action: setMasterPassphrase) {
                Text(config.hasMasterPassphrase ? L10n.t("settings.login.updatePassphraseBtn") : L10n.t("settings.login.savePassphraseBtn")).fontWeight(.medium)
            }
            .buttonStyle(.zen(.outline, height: 32, radius: 8, padding: 14))
            .disabled(newPassphrase.trimmingCharacters(in: .whitespaces).isEmpty)

            if config.hasMasterPassphrase {
                SettingsDangerButton(title: L10n.t("settings.login.removePassphraseBtn"), height: 32, fontSize: 12) {
                    store.updateAuthConfig(auth.config.withoutMasterPassphrase())
                    authStatusMsg = L10n.t("settings.login.removedPassphraseMsg")
                }
            }
        }
        .padding(14)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func setMasterPassphrase() {
        let trimmed = newPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else {
            authStatusMsg = L10n.t("settings.login.errPassphraseShort")
            return
        }
        store.updateAuthConfig(auth.config.withMasterPassphrase(trimmed))
        newPassphrase = ""
        authStatusMsg = L10n.t("settings.login.updatedPassphraseMsg")
    }

    private func registerTouchID() async {
        isRegisteringPasskey = true
        authStatusMsg = nil
        defer { isRegisteringPasskey = false }
        let label = newCredentialLabel.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Touch ID (This Mac)" : newCredentialLabel.trimmingCharacters(in: .whitespaces)
        do {
            let record = try await TouchIDKeychain.enroll(
                account: auth.account, label: label, vaultSecret: store.vault?.passphrase,
                displayName: auth.config.userDisplayName.isEmpty ? "Koban Owner" : auth.config.userDisplayName)
            var next = auth.config
            next.enabled = true
            next.passkeys.append(record)
            store.updateAuthConfig(next)
            authStatusMsg = L10n.tf("settings.login.enrollSuccess", ["name": record.name])
        } catch {
            authStatusMsg = error.localizedDescription.isEmpty ? L10n.t("settings.login.enrollFailed") : error.localizedDescription
        }
    }

    static func date(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .numeric, time: .omitted)
    }

    // MARK: - Month copy behavior

    private var copySection: some View {
        SettingsSection(icon: "doc.on.doc", tint: Zen.positive, title: L10n.t("settings.copy.title"),
                        subtitle: L10n.t("settings.copy.desc")) {
            VStack(spacing: 12) {
                SettingsToggleRow(title: L10n.t("settings.copy.confirmTitle"),
                                  detail: L10n.t("settings.copy.confirmDesc"),
                                  isOn: setting(\.confirmBeforeMonthCopy, default: true))
                SettingsToggleRow(title: L10n.t("settings.copy.autoPromptTitle"),
                                  detail: L10n.t("settings.copy.autoPromptDesc"),
                                  isOn: setting(\.autoPromptCopyOnEmptyMonth, default: true))
                SettingsToggleRow(title: L10n.t("settings.copy.overwriteTitle"),
                                  detail: L10n.t("settings.copy.overwriteDesc"),
                                  isOn: setting(\.monthCopyOverwriteExisting, default: true))

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("settings.copy.scopeTitle")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        Text(L10n.t("settings.copy.scopeDesc"))
                            .font(.zen(11)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    ZenSelect(options: [(MonthCopyScope.budgetsAndActuals, L10n.t("settings.copy.scopeBoth")),
                                        (MonthCopyScope.budgetsOnly, L10n.t("settings.copy.scopeBudgetsOnly"))],
                              selection: Binding(get: { settings.monthCopyScope ?? .budgetsAndActuals },
                                                 set: { v in store.applySettingsChange { $0.monthCopyScope = v } }),
                              background: Zen.surface)
                }
                .padding(12)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }
        }
    }

    // MARK: - Import preview / deletion safety

    private var importSection: some View {
        SettingsSection(icon: "slider.horizontal.3", tint: Zen.indigo, title: L10n.t("settings.import.title"),
                        subtitle: L10n.t("settings.import.desc")) {
            SettingsToggleRow(title: L10n.t("settings.import.preview"),
                              detail: L10n.t("settings.import.previewDesc"),
                              isOn: setting(\.confirmAndPreviewBeforeImport, default: true))
            SettingsEqualColumns {
                SettingsToggleRow(title: L10n.t("settings.import.confirmDeleteTitle"),
                                  detail: L10n.t("settings.import.confirmDeleteDesc"),
                                  isOn: setting(\.confirmBeforeDelete, default: true))
                SettingsToggleRow(title: L10n.t("settings.import.hideZeroTitle"),
                                  detail: L10n.t("settings.import.hideZeroDesc"),
                                  isOn: setting(\.defaultHideZeroRows, default: false))
            }
        }
    }

    // MARK: - Workspace, currency, tax

    private var workspaceSection: some View {
        SettingsSection(icon: "globe", tint: Zen.accent, title: L10n.t("settings.workspace.title"),
                        subtitle: L10n.t("settings.workspace.desc")) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("settings.workspace.profileMode"))
                    SettingsMenuField(options: [(ProfileSetupMode.both, L10n.t("settings.workspace.modeBoth")),
                                                (.home, L10n.t("settings.workspace.modeHome")),
                                                (.freelancer, L10n.t("settings.workspace.modeFreelancer"))],
                                      selection: Binding(get: { settings.setupMode }, set: { mode in
                                          store.applySettingsChange {
                                              $0.setupMode = mode
                                              $0.activeWorkspace = mode == .freelancer ? .freelancer
                                                  : mode == .home ? .home : $0.activeWorkspace
                                          }
                                      }), height: 36)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("settings.currency"))
                    SettingsMenuField(options: [("CHF", L10n.t("settings.currency.chf")), ("EUR", L10n.t("settings.currency.eur")),
                                                ("USD", L10n.t("settings.currency.usd")), ("GBP", L10n.t("settings.currency.gbp")),
                                                ("JPY", L10n.t("settings.currency.jpy"))],
                                      selection: setting(\.currency), height: 36)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("onboarding.s1.vatLabel"))
                    SettingsNumberField(icon: "plus.forwardslash.minus", value: settings.defaultVatRate) { v in
                        store.applySettingsChange { $0.defaultVatRate = v }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel(L10n.t("onboarding.s1.taxReserveLabel"))
                    SettingsNumberField(value: settings.taxReserveRate) { v in
                        store.applySettingsChange { $0.taxReserveRate = v }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Themes & personalization

    private struct PaletteInfo {
        let id: ThemePalette
        let name: String
        let desc: String
        let swatches: [UInt32]
        let badge: String
    }

    private var palettes: [PaletteInfo] {
        [
            PaletteInfo(id: .zen, name: L10n.t("settings.palette.default"), desc: L10n.t("settings.palette.defaultDesc"),
                        swatches: [0xB9432F, 0x3F704D, 0x3F6E8C, 0xB8862D], badge: L10n.t("settings.palette.badgeDefault")),
            PaletteInfo(id: .monochrome, name: L10n.t("settings.palette.monochrome"), desc: L10n.t("settings.palette.monochromeDesc"),
                        swatches: [0x111111, 0x383838, 0x757575, 0xFFFFFF], badge: L10n.t("settings.palette.badgeMono")),
            PaletteInfo(id: .slate, name: L10n.t("settings.palette.slate"), desc: L10n.t("settings.palette.slateDesc"),
                        swatches: [0x0284C7, 0x059669, 0x3B82F6, 0xD97706], badge: L10n.t("settings.palette.badgeSlate")),
            PaletteInfo(id: .forest, name: L10n.t("settings.palette.forest"), desc: L10n.t("settings.palette.forestDesc"),
                        swatches: [0x1E5A38, 0x2E7D32, 0x2C6E64, 0xC28100], badge: L10n.t("settings.palette.badgeForest")),
        ]
    }

    private var themeSection: some View {
        SettingsSection(icon: "paintpalette", tint: Zen.accent, title: L10n.t("settings.themeAndPersonalization.title"),
                        subtitle: L10n.t("settings.themeAndPersonalization.desc"), headerPadding: 12) {
            HStack(spacing: 6) {
                ForEach([(ThemePreference.system, L10n.t("settings.themeMode.system"), "display"),
                         (.light, L10n.t("settings.themeMode.light"), "sun.max"),
                         (.dark, L10n.t("settings.themeMode.dark"), "moon")], id: \.0) { item in
                    SettingsSegmentButton(title: item.1, icon: item.2, active: settings.theme == item.0) {
                        store.applySettingsChange { $0.theme = item.0 }
                    }
                }
            }
            .padding(4)
            .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("settings.palette.title")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                SettingsEqualColumns {
                    ForEach(palettes, id: \.id) { p in
                        PaletteCard(name: p.name, desc: p.desc, badge: p.badge, swatches: p.swatches,
                                    active: (settings.themePalette ?? .zen) == p.id) {
                            store.setPalette(p.id)
                        }
                    }
                }
            }

            SettingsEqualColumns(spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("settings.density.title")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        Text(L10n.t("settings.density.desc")).font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        SettingsSegmentButton(title: L10n.t("settings.density.cozyBtn"), active: (settings.density ?? .comfortable) == .comfortable,
                                              height: 24, horizontalPadding: 8, activeBackground: Zen.raised) {
                            store.applySettingsChange { $0.density = .comfortable }
                        }
                        SettingsSegmentButton(title: L10n.t("settings.density.compactBtn"), active: settings.density == .compact,
                                              height: 24, horizontalPadding: 8, activeBackground: Zen.raised) {
                            store.applySettingsChange { $0.density = .compact }
                        }
                    }
                    .padding(4)
                    .background(Zen.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Zen.line, lineWidth: 1))
                    .fixedSize()
                }
                .padding(12)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("settings.contrast.title")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        Text(L10n.t("settings.contrast.desc")).font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                    Spacer(minLength: 8)
                    SettingsCheckbox(isOn: setting(\.highContrastAmounts, default: false), size: 16)
                }
                .padding(12)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
        }
    }

    // MARK: - Backups

    private var backupSection: some View {
        SettingsSection(icon: "checkmark.shield", tint: Zen.positive,
                        title: L10n.t("settings.backups.title"),
                        subtitle: L10n.t("settings.backups.desc")) {
            SettingsLinkButton(title: L10n.t("settings.backups.openManager")) { store.selectedTab = .backups }
        } content: {
            GeometryReader { geo in
                let unit = (geo.size.width - 12 * 11) / 12
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsFieldLabel(L10n.t("settings.backups.folderLabel"))
                        HStack(spacing: 8) {
                            SettingsTextField(placeholder: L10n.t("settings.backups.folderPlaceholder"),
                                              text: setting(\.backupDir), height: 36, background: Zen.app)
                            Button(action: chooseBackupFolder) {
                                HStack(spacing: 6) {
                                    ZIcon("folder", size: 14)
                                    Text(L10n.t("settings.backups.browse"))
                                }
                                .foregroundStyle(Zen.ink)
                            }
                            .buttonStyle(.zen(.raised, height: 36, radius: 8, padding: 12))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                            .fixedSize()
                        }
                    }
                    .frame(width: unit * 7 + 12 * 6)

                    VStack(alignment: .leading, spacing: 4) {
                        SettingsFieldLabel(L10n.t("settings.backups.maxSnapshots"))
                        SettingsNumberField(value: Double(settings.maxBackups), fallback: 20) { v in
                            store.applySettingsChange { $0.maxBackups = max(3, Int(v) == 0 ? 20 : Int(v)) }
                        }
                    }
                    .frame(width: unit * 3 + 12 * 2)

                    HStack(spacing: 8) {
                        SettingsCheckbox(isOn: setting(\.autoBackup))
                        Text(L10n.t("settings.backups.autoBackup")).font(.zen(12)).foregroundStyle(Zen.ink)
                    }
                    .frame(width: unit * 2 + 12, height: 36, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.applySettingsChange { $0.autoBackup.toggle() } }
                }
            }
            .frame(height: 36 + 4 + 15)
        }
    }

    /// handleChooseBackupFolder (pickFolderDialog) → NSOpenPanel.
    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Automatic Encrypted Database Backup Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !settings.backupDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.backupDir, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.applySettingsChange {
            $0.backupDir = url.path
            $0.autoBackup = true
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        let checker = UpdateChecker.shared
        return SettingsSection(icon: "arrow.triangle.2.circlepath", tint: Zen.indigo,
                               title: L10n.t("settings.updates.title"),
                               subtitle: L10n.t("settings.updates.desc")) {
            Text("\(L10n.t("settings.updates.currentVersion")): v\(checker.currentVersion)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Zen.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Zen.app, in: Capsule())
                .overlay(Capsule().strokeBorder(Zen.line, lineWidth: 1))
        } content: {
            SettingsToggleRow(title: L10n.t("settings.updates.autoCheck"),
                              detail: L10n.t("settings.updates.autoCheckDesc"),
                              isOn: setting(\.autoCheckUpdates, default: true))

            HStack(spacing: 12) {
                Group {
                    if checker.isChecking {
                        Text(L10n.t("settings.updates.checking"))
                            .foregroundStyle(Zen.ink2)
                    } else if let err = checker.lastError {
                        Text(L10n.t("settings.updates.error").replacingOccurrences(of: "{error}", with: err))
                            .foregroundStyle(Zen.accent)
                    } else if checker.hasChecked {
                        if checker.updateAvailable, let latest = checker.latestVersion {
                            Text(L10n.t("settings.updates.available")
                                .replacingOccurrences(of: "{latest}", with: latest)
                                .replacingOccurrences(of: "{current}", with: checker.currentVersion))
                                .fontWeight(.medium)
                                .foregroundStyle(Zen.positive)
                        } else {
                            Text(L10n.t("settings.updates.upToDate")
                                .replacingOccurrences(of: "{version}", with: checker.currentVersion))
                                .foregroundStyle(Zen.ink2)
                        }
                    }
                }
                .font(.zen(12))
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    checker.openReleasesPage()
                } label: {
                    HStack(spacing: 6) {
                        ZIcon("arrow.up.right.square", size: 13)
                        Text(L10n.t("settings.updates.viewReleases"))
                    }
                }
                .buttonStyle(.zen(.outline, height: 34, radius: 8, padding: 12))

                if checker.updateAvailable, let latest = checker.latestVersion {
                    Button {
                        checker.openDownloadOrRelease()
                    } label: {
                        HStack(spacing: 6) {
                            ZIcon("arrow.down.circle", size: 13)
                            Text(L10n.t("settings.updates.download").replacingOccurrences(of: "{version}", with: latest))
                                .fontWeight(.medium)
                        }
                        .font(.zen(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Zen.positive, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await checker.checkNow(notifyStore: store) }
                } label: {
                    HStack(spacing: 6) {
                        ZIcon("arrow.triangle.2.circlepath", size: 13)
                        Text(checker.isChecking ? L10n.t("settings.updates.checking") : L10n.t("settings.updates.checkNow"))
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.zen(.ink, height: 34, radius: 8, padding: 16))
                .disabled(checker.isChecking)
            }
        }
    }
}

// MARK: - Pieces

/// Full-width select (w-full h-9 px-2.5 rounded-lg bg-app border border-line text-xs).
struct SettingsMenuField<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 32
    var background: Color = Zen.app

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.zen(12)).foregroundStyle(Zen.ink).lineLimit(1)
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
}

/// text-xs text-indigo hover:underline
private struct SettingsLinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.zen(12)).foregroundStyle(Zen.indigo).underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PaletteCard: View {
    let name: String
    let desc: String
    let badge: String
    let swatches: [UInt32]
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name).font(.zen(12, .semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                        if active { ZIcon("checkmark", size: 14).foregroundStyle(Zen.accent) }
                    }
                    Spacer(minLength: 4)
                    Text(badge.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Zen.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                        .fixedSize()
                }
                .padding(.bottom, 4)
                Text(desc)
                    .font(.zen(11)).foregroundStyle(Zen.ink2)
                    .lineLimit(2).lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, hex in
                        Circle().fill(Color(nsColor: NSColor(hex: hex)))
                            .overlay(Circle().strokeBorder(Zen.line.opacity(0.8), lineWidth: 1))
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.05), radius: 0.5, y: 0.5)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(active ? Zen.raised.opacity(0.7) : (hovering ? Zen.raised.opacity(0.4) : Zen.app),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active ? Zen.ink : (hovering ? Zen.ink3 : Zen.line), lineWidth: 1))
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 12).inset(by: -1.5).strokeBorder(Zen.ink.opacity(0.3), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
