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
                .help("Lock Koban immediately (⌘L)")

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
            subtitle: "Require authentication when opening Koban using Touch ID or a Master Passphrase"
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
                                  detail: "Lock the ledger behind Touch ID or Master Passphrase on startup.",
                                  isOn: authBinding(\.enabled))
                SettingsToggleRow(title: "Auto-prompt Touch ID on launch",
                                  detail: "Automatically open the Touch ID prompt as soon as the lock screen appears.",
                                  isOn: authBinding(\.autoPromptPasskeyOnLaunch))
            }

            SettingsEqualColumns {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel("Account Owner Display Name", weight: .medium)
                    SettingsTextField(placeholder: "e.g. Roland", text: authBinding(\.userDisplayName))
                }
                .padding(12)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel("Inactivity Auto-Lock Timer", weight: .medium)
                    SettingsMenuField(options: [(0, "Never auto-lock while open"), (5, "Lock after 5 minutes idle"),
                                                (15, "Lock after 15 minutes idle"), (30, "Lock after 30 minutes idle"),
                                                (60, "Lock after 60 minutes idle")],
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
                Text("Enrolled Touch ID & Passkey Credentials (\(count))").font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                Text("Register Touch ID (or your Mac login password) on this Mac. Windows Hello / Passkey credentials enrolled on Windows are kept for Windows.")
                    .font(.zen(11)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
            }

            if count > 0 {
                VStack(spacing: 6) {
                    ForEach(config.passkeys) { pk in
                        credentialRow(name: pk.name,
                                      detail: "\(pk.isWindowsHelloNative ? "Touch ID on Mac · Windows Hello on Windows" : "WebAuthn FIDO2 Passkey · Windows only") • Added \(Self.date(pk.createdAt))",
                                      icon: pk.isWindowsHelloNative ? "laptopcomputer" : "key.horizontal") {
                            var next = auth.config
                            next.passkeys.removeAll { $0.id == pk.id }
                            store.updateAuthConfig(next)
                            if !auth.hasMacCredential { TouchIDKeychain.removeSecret(account: auth.account) }
                            authStatusMsg = "Removed Passkey credential."
                        }
                    }
                }
            } else {
                Text("No Touch ID or Passkey credential registered yet.")
                    .font(.zen(12)).foregroundStyle(Zen.ink3).padding(.vertical, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel("Credential Label", size: 10, color: Zen.ink3)
                    SettingsTextField(placeholder: "e.g. Touch ID (MacBook Pro)", text: $newCredentialLabel)
                }
                .frame(minWidth: 160, maxWidth: .infinity)

                Button { Task { await registerTouchID() } } label: {
                    HStack(spacing: 6) {
                        ZIcon("plus", size: 14)
                        Text("Enroll Touch ID").fontWeight(.medium)
                    }
                }
                .buttonStyle(.zen(.ink, height: 32, radius: 8, padding: 14))
                .disabled(isRegisteringPasskey || !TouchIDKeychain.anyAuthAvailable)
                .help(TouchIDKeychain.anyAuthAvailable ? "Stores a Touch ID-protected unlock key for this vault in your Keychain"
                                                       : "Touch ID / device authentication is not available on this Mac")
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
                SettingsFieldLabel(config.hasMasterPassphrase ? "Update Master Passphrase / PIN (Configured)"
                                                              : "Set Optional Backup Master Passphrase / PIN", weight: .medium)
                SettingsTextField(icon: "key", placeholder: "Enter new Master Passphrase or PIN…", text: $newPassphrase,
                                  secure: true, onSubmit: setMasterPassphrase)
            }
            .frame(minWidth: 180, maxWidth: .infinity)

            Button(action: setMasterPassphrase) {
                Text(config.hasMasterPassphrase ? "Update Passphrase" : "Save Passphrase").fontWeight(.medium)
            }
            .buttonStyle(.zen(.outline, height: 32, radius: 8, padding: 14))
            .disabled(newPassphrase.trimmingCharacters(in: .whitespaces).isEmpty)

            if config.hasMasterPassphrase {
                SettingsDangerButton(title: "Remove Passphrase", height: 32, fontSize: 12) {
                    store.updateAuthConfig(auth.config.withoutMasterPassphrase())
                    authStatusMsg = "Removed Master Passphrase."
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
            authStatusMsg = "Master Passphrase / PIN must be at least 4 characters."
            return
        }
        store.updateAuthConfig(auth.config.withMasterPassphrase(trimmed))
        newPassphrase = ""
        authStatusMsg = "Updated Master Passphrase / PIN."
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
            authStatusMsg = "Enrolled \"\(record.name)\" successfully."
        } catch {
            authStatusMsg = error.localizedDescription.isEmpty ? "Touch ID registration failed." : error.localizedDescription
        }
    }

    static func date(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .numeric, time: .omitted)
    }

    // MARK: - Month copy behavior

    private var copySection: some View {
        SettingsSection(icon: "doc.on.doc", tint: Zen.positive, title: L10n.t("settings.copy.title"),
                        subtitle: "Control how Koban copies last month's values into the next month and when confirmation prompts appear") {
            VStack(spacing: 12) {
                SettingsToggleRow(title: "Ask for confirmation before copying values between months",
                                  detail: "When enabled, Koban always asks if you are sure before copying last month's values into the next month or across all 12 months.",
                                  isOn: setting(\.confirmBeforeMonthCopy, default: true))
                SettingsToggleRow(title: "Show carry-over prompt when viewing an empty month",
                                  detail: "When navigating to a month with 0.00 budgets and actuals, display a quick prompt to copy the previous month's values.",
                                  isOn: setting(\.autoPromptCopyOnEmptyMonth, default: true))
                SettingsToggleRow(title: "Overwrite existing non-zero values in target month by default",
                                  detail: "If disabled, copying a month will only fill categories that are currently 0.00 in the target month.",
                                  isOn: setting(\.monthCopyOverwriteExisting, default: true))

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Values to Copy Between Months").font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        Text("Choose whether copying last month carries over only Planned Budgets or both Budgets and Direct Actuals.")
                            .font(.zen(11)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    ZenSelect(options: [(MonthCopyScope.budgetsAndActuals, "Copy Both Planned Budgets & Direct Actuals"),
                                        (MonthCopyScope.budgetsOnly, "Copy Planned Budgets Only (Reset Actuals)")],
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
                        subtitle: "Control import data preview & confirmation prompts, table visibility, and deletion safety") {
            SettingsToggleRow(title: L10n.t("settings.import.preview"),
                              detail: "When enabled, importing an Excel workbook, CSV budget sheet, transaction statement, or encrypted database backup shows a detailed preview table of parsed categories, amounts, or transactions and asks for your confirmation before modifying the ledger.",
                              isOn: setting(\.confirmAndPreviewBeforeImport, default: true))
            SettingsEqualColumns {
                SettingsToggleRow(title: "Ask for confirmation before deleting categories, groups, or accounts",
                                  detail: "Prevents accidental removal of categories or financial accounts that have historical data.",
                                  isOn: setting(\.confirmBeforeDelete, default: true))
                SettingsToggleRow(title: "Hide 0.00 rows by default in Monthly Worksheet",
                                  detail: "Start the Monthly Budget worksheet with inactive (0 budget & 0 actual) categories collapsed.",
                                  isOn: setting(\.defaultHideZeroRows, default: false))
            }
        }
    }

    // MARK: - Workspace, currency, tax

    private var workspaceSection: some View {
        SettingsSection(icon: "globe", tint: Zen.accent, title: L10n.t("settings.workspace.title"),
                        subtitle: "Regional currency formatting, Freelancer VAT/Tax reserve rates, and Washi/Sumi theme") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel("Enabled Profile Mode")
                    SettingsMenuField(options: [(ProfileSetupMode.both, "Both (Home + Freelancer)"),
                                                (.home, "Home Budget Only"),
                                                (.freelancer, "Freelancer / Business Only")],
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
                    SettingsMenuField(options: [("CHF", "CHF — Swiss Franc"), ("EUR", "EUR (€) — Euro"),
                                                ("USD", "USD ($) — US Dollar"), ("GBP", "GBP (£) — British Pound"),
                                                ("JPY", "JPY (¥) — Japanese Yen")],
                                      selection: setting(\.currency), height: 36)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel("Default Freelancer VAT %")
                    SettingsNumberField(icon: "plus.forwardslash.minus", value: settings.defaultVatRate) { v in
                        store.applySettingsChange { $0.defaultVatRate = v }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    SettingsFieldLabel("Tax Reserve Set-Aside %")
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
                        swatches: [0xB9432F, 0x3F704D, 0x3F6E8C, 0xB8862D], badge: "Default Zen"),
            PaletteInfo(id: .monochrome, name: L10n.t("settings.palette.monochrome"), desc: L10n.t("settings.palette.monochromeDesc"),
                        swatches: [0x111111, 0x383838, 0x757575, 0xFFFFFF], badge: "Pure B&W"),
            PaletteInfo(id: .slate, name: L10n.t("settings.palette.slate"), desc: L10n.t("settings.palette.slateDesc"),
                        swatches: [0x0284C7, 0x059669, 0x3B82F6, 0xD97706], badge: "Arctic Nord"),
            PaletteInfo(id: .forest, name: L10n.t("settings.palette.forest"), desc: L10n.t("settings.palette.forestDesc"),
                        swatches: [0x1E5A38, 0x2E7D32, 0x2C6E64, 0xC28100], badge: "Botanical"),
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
                        Text("Comfortable spacious layout or compact data density").font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        SettingsSegmentButton(title: "Cozy", active: (settings.density ?? .comfortable) == .comfortable,
                                              height: 24, horizontalPadding: 8, activeBackground: Zen.raised) {
                            store.applySettingsChange { $0.density = .comfortable }
                        }
                        SettingsSegmentButton(title: "Compact", active: settings.density == .compact,
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
                        title: "AES-256-GCM Database & Auto-Backup Preferences",
                        subtitle: "Automatic encrypted snapshots to your chosen directory") {
            SettingsLinkButton(title: "Open Full Vault & Backup Manager →") { store.selectedTab = .backups }
        } content: {
            GeometryReader { geo in
                let unit = (geo.size.width - 12 * 11) / 12
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsFieldLabel("Automatic Backup Folder Path")
                        HStack(spacing: 8) {
                            SettingsTextField(placeholder: "Choose a folder for automatic encrypted backups…",
                                              text: setting(\.backupDir), height: 36, background: Zen.app)
                            Button(action: chooseBackupFolder) {
                                HStack(spacing: 6) {
                                    ZIcon("folder", size: 14)
                                    Text("Browse…")
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
                        SettingsFieldLabel("Max Rolling Snapshots")
                        SettingsNumberField(value: Double(settings.maxBackups), fallback: 20) { v in
                            store.applySettingsChange { $0.maxBackups = max(3, Int(v) == 0 ? 20 : Int(v)) }
                        }
                    }
                    .frame(width: unit * 3 + 12 * 2)

                    HStack(spacing: 8) {
                        SettingsCheckbox(isOn: setting(\.autoBackup))
                        Text("Auto-Backup").font(.zen(12)).foregroundStyle(Zen.ink)
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
