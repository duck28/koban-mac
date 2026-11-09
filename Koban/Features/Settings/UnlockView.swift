import SwiftUI

// OWNER: Settings & Auth. Keep `init(message: String?)`: RootView shows it for a locked vault
// (phase .locked) and, with message nil, over the loaded app when `store.isAppLocked`.
/// Port of src/components/AuthLockScreen.tsx. Windows Hello / passkeys → Touch ID (LocalAuthentication)
/// with the vault passphrase kept in the Keychain (TouchIDKeychain).
///
/// Two situations:
/// - vault locked (phase .locked): the ledger is still encrypted with a custom passphrase; Touch ID
///   returns the stored passphrase, or the user types it → `store.unlock(passphrase:)`.
/// - app locked (isAppLocked): the ledger is decrypted; Touch ID / master passphrase verify the user,
///   then `store.completeSignIn()` (handleUnlockSuccess). Without any credential the first-time
///   enrollment view is shown, like on Windows.
struct UnlockView: View {
    @Environment(LedgerStore.self) private var store
    let message: String?

    @State private var displayName = ""
    @State private var passphraseInput = ""
    @State private var confirmPassphraseInput = ""
    @State private var showPassphrase = false
    @State private var isBusy = false
    @State private var errorMsg: String?
    @State private var statusMsg: String?
    @State private var autoPromptTriggered = false
    @FocusState private var passphraseFocused: Bool

    init(message: String?) {
        self.message = message
    }

    private var auth: AuthCenter { AuthCenter.shared }
    private var config: AuthConfig { auth.config }

    private var vaultLocked: Bool {
        if case .locked = store.phase { return true }
        return false
    }

    private var hasCustomDbPassphrase: Bool { vaultLocked || store.hasCustomPassphrase }

    private var hasCredentialsConfigured: Bool {
        AuthRules.hasCredentialsConfigured(config: config, hasMacCredential: auth.hasMacCredential,
                                           hasCustomDbPassphrase: hasCustomDbPassphrase)
    }

    private var ownerName: String { config.userDisplayName.isEmpty ? "Koban Owner" : config.userDisplayName }

    var body: some View {
        ZStack {
            Zen.app.ignoresSafeArea()
            WindowDragArea().ignoresSafeArea()
            DotGrid().opacity(0.03).allowsHitTesting(false).ignoresSafeArea()

            GeometryReader { geo in
                ScrollView {
                    card
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: appear)
        .onChange(of: message) { _, new in if let new { errorMsg = new; statusMsg = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            #if DEBUG
            if (note.userInfo?["name"] as? String) == "auth-error" {
                errorMsg = "Incorrect Master Passphrase or PIN. Please try again."
            }
            #endif
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 20) {
                if let errorMsg {
                    SettingsCallout(text: errorMsg, icon: "exclamationmark.circle", tint: Zen.accent, radius: 12, padding: 12)
                } else if let statusMsg {
                    SettingsCallout(text: statusMsg, icon: "sparkles", tint: Zen.indigo, radius: 12, padding: 12)
                }
                if hasCredentialsConfigured { signInView } else { enrollmentView }
            }
            .padding(24)
            footer
        }
        .frame(width: 448)
        .background(Zen.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Zen.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            LanguageSelect(variant: .compact, usesTopBarMenu: false)
                .padding(14)
        }
        .shadow(color: .black.opacity(0.22), radius: 32, y: 18)
    }

    private var header: some View {
        VStack(spacing: 0) {
            KobanLogo(height: 28).padding(.bottom, 14)
            HStack(spacing: 6) {
                ZIcon("checkmark.shield", size: 12)
                Text(L10n.t("lock.encrypted")).font(.zen(10, .medium))
            }
            .foregroundStyle(Zen.positive)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(Zen.positive.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(Zen.positive.opacity(0.25), lineWidth: 1))
            .padding(.bottom, 8)

            Text(hasCredentialsConfigured ? L10n.t("lock.signIn") : L10n.t("lock.configure"))
                .font(.zen(18, .semibold))
                .foregroundStyle(Zen.ink)

            Text(hasCredentialsConfigured
                 ? "Welcome back, \(ownerName). Verify your identity to decrypt and unlock your ledger."
                 : "Protect your Home Budget, Freelance Ledger & Net Worth with Touch ID or a Master Passphrase.")
                .font(.zen(12))
                .foregroundStyle(Zen.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Zen.app.opacity(0.5))
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ZIcon("checkmark.circle", size: 14).foregroundStyle(Zen.positive)
                Text(TouchIDKeychain.biometryAvailable ? "Touch ID & Keychain Ready" : "macOS Keychain Ready")
            }
            Spacer()
            Text("Local Zero-Knowledge Vault")
        }
        .font(.zen(11))
        .foregroundStyle(Zen.ink3)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Zen.app.opacity(0.4))
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    // MARK: Existing user sign-in

    @ViewBuilder
    private var signInView: some View {
        let hasMac = auth.hasMacCredential
        if hasMac {
            Button { Task { await signInWithTouchID() } } label: {
                HStack(spacing: 10) {
                    ZIcon("touchid", size: 16)
                    Text(L10n.t("lock.passkeyBtn"))
                    ZIcon("arrow.right", size: 14).padding(.leading, 2)
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.medium)
            }
            .buttonStyle(.zen(.ink, height: 44, radius: 12, fontSize: 12))
            .disabled(isBusy)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }

        if hasMac && (config.hasMasterPassphrase || hasCustomDbPassphrase) {
            AuthOrDivider(text: L10n.t("lock.orPassphrase"))
        }

        if config.hasMasterPassphrase || hasCustomDbPassphrase || !hasMac {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hasCustomDbPassphrase && vaultLocked ? "Vault Passphrase" : L10n.t("lock.passphraseLabel"))
                        .font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                    SettingsTextField(icon: "key", placeholder: "Enter passphrase or PIN…", text: $passphraseInput,
                                      secure: true, height: 40, radius: 12, background: Zen.raised,
                                      revealToggle: $showPassphrase, onSubmit: signInWithPassphrase)
                        .focused($passphraseFocused)
                }
                Button(action: signInWithPassphrase) {
                    HStack(spacing: 8) {
                        ZIcon("lock", size: 14)
                        Text(L10n.t("lock.unlockPassphrase"))
                    }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.medium)
                }
                .buttonStyle(.zen(hasMac ? .raised : .ink, height: 40, radius: 12, fontSize: 12))
                .overlay {
                    if hasMac { RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1) }
                }
                .keyboardShortcut(hasMac ? nil : .defaultAction)
                .disabled(isBusy)
            }
        }

        if vaultLocked {
            Button { store.openExistingDatabase() } label: {
                Text("Open Another Database…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.zen(.ghost, height: 30, radius: 8, fontSize: 11))
        }
    }

    // MARK: First-time enrollment

    private var enrollmentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Account Display Name").font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                SettingsTextField(icon: "person.badge.shield.checkmark", placeholder: "e.g. Roland", text: $displayName,
                                  height: 36, radius: 12, background: Zen.raised)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ZIcon("touchid", size: 16).foregroundStyle(Zen.indigo).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Touch ID (Recommended)").font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        Text(TouchIDKeychain.biometryAvailable
                             ? "Sign in with your fingerprint on this Mac without typing a password. The key stays in your macOS Keychain."
                             : "This Mac has no Touch ID; your macOS login password is used to confirm it's you instead.")
                            .font(.zen(11)).foregroundStyle(Zen.ink2).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let windowsOnly = config.passkeys.filter { $0.kind != TouchIDKeychain.recordKind }.count
                if windowsOnly > 0 {
                    Text("\(windowsOnly) WebAuthn passkey\(windowsOnly == 1 ? "" : "s") from Windows can only be used on Windows and \(windowsOnly == 1 ? "is" : "are") kept unchanged.")
                        .font(.zen(11)).foregroundStyle(Zen.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { Task { await enrollTouchIDFirstTime() } } label: {
                    HStack(spacing: 8) {
                        ZIcon("touchid", size: 16)
                        Text(L10n.t("lock.enroll"))
                    }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.medium)
                }
                .buttonStyle(.zen(.ink, height: 40, radius: 12, fontSize: 12))
                .disabled(isBusy || !TouchIDKeychain.anyAuthAvailable)
                .padding(.top, 4)
            }
            .padding(14)
            .background(Zen.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.indigo.opacity(0.25), lineWidth: 1))

            AuthOrDivider(text: "Or set Master Passphrase / PIN")

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SettingsTextField(placeholder: "Passphrase or PIN…", text: $passphraseInput, secure: !showPassphrase,
                                      height: 36, radius: 12, background: Zen.raised)
                    SettingsTextField(placeholder: "Confirm…", text: $confirmPassphraseInput, secure: !showPassphrase,
                                      height: 36, radius: 12, background: Zen.raised, onSubmit: enrollPassphraseOnly)
                }
                Button(action: enrollPassphraseOnly) {
                    Text("Save Passphrase & Sign In").frame(maxWidth: .infinity)
                    .fontWeight(.medium)
                }
                .buttonStyle(.zen(.raised, height: 36, radius: 12, fontSize: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
                .disabled(isBusy || passphraseInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Actions

    private func appear() {
        auth.refresh(store: store)
        if displayName.isEmpty { displayName = ownerName }
        if let message { errorMsg = message }
        passphraseFocused = !auth.hasMacCredential
        #if DEBUG
        if ProcessInfo.processInfo.environment["KOBAN_SNAPSHOT"] != nil { return }
        #endif
        // Auto-prompt Touch ID on launch (autoPromptPasskeyOnLaunch).
        if hasCredentialsConfigured, config.autoPromptPasskeyOnLaunch, auth.hasMacCredential, !autoPromptTriggered {
            autoPromptTriggered = true
            Task { await signInWithTouchID() }
        }
    }

    private func signInWithTouchID() async {
        errorMsg = nil
        statusMsg = "Waiting for Touch ID verification…"
        isBusy = true
        defer { isBusy = false }
        do {
            let stored = try await TouchIDKeychain.authenticate(account: auth.account, displayName: ownerName)
            let secret = auth.resolveSecret(keychainSecret: stored)
            statusMsg = "Verified via Touch ID."
            if vaultLocked {
                guard let secret, !secret.isEmpty else {
                    statusMsg = nil
                    errorMsg = "Touch ID has no vault passphrase stored for this vault yet. Enter the passphrase once — Touch ID will use it from then on."
                    return
                }
                store.unlock(passphrase: secret)
                if store.phase == .ready {
                    TouchIDKeychain.updateSecret(secret, account: auth.account)
                    store.completeSignIn(updatedConfig: auth.configMarkingUsed())
                } else {
                    statusMsg = nil
                    errorMsg = "The passphrase stored for Touch ID no longer opens this vault. Enter the current vault passphrase."
                }
            } else {
                store.completeSignIn(updatedConfig: auth.configMarkingUsed())
            }
        } catch {
            statusMsg = nil
            errorMsg = error.localizedDescription
        }
    }

    private func signInWithPassphrase() {
        let trimmed = passphraseInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMsg = "Please enter your Master Passphrase or PIN."
            return
        }
        errorMsg = nil
        if vaultLocked {
            let raw = passphraseInput
            store.unlock(passphrase: trimmed)
            if store.phase != .ready, raw != trimmed { store.unlock(passphrase: raw) }
            if store.phase == .ready {
                // Keep the Touch ID secret in sync with the passphrase that just worked (also gives
                // vaults enrolled during onboarding, which store no secret, their Touch ID unlock).
                if auth.hasMacCredential { TouchIDKeychain.updateSecret(store.vault?.passphrase, account: auth.account) }
                passphraseInput = ""
                store.completeSignIn()
            } else if case .locked(let msg) = store.phase {
                errorMsg = msg ?? "Wrong passphrase. Please try again."
            }
            return
        }
        guard AuthRules.acceptsAppPassphrase(trimmed, config: config, vaultPassphrase: store.vault?.passphrase) else {
            errorMsg = "Incorrect Master Passphrase or PIN. Please try again."
            return
        }
        passphraseInput = ""
        store.completeSignIn()
    }

    private func enrollTouchIDFirstTime() async {
        errorMsg = nil
        statusMsg = "Opening Touch ID registration prompt…"
        isBusy = true
        defer { isBusy = false }
        let cleanName = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Koban Owner"
            : displayName.trimmingCharacters(in: .whitespaces)
        let typed = passphraseInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let record = try await TouchIDKeychain.enroll(account: auth.account, label: TouchIDKeychain.methodName,
                                                          vaultSecret: store.vault?.passphrase, displayName: cleanName)
            var next = config
            next.passkeys.append(record)
            next.enabled = true
            next.userDisplayName = cleanName
            if !typed.isEmpty { next = next.withMasterPassphrase(typed) }
            store.completeSignIn(updatedConfig: next)
        } catch {
            statusMsg = nil
            errorMsg = error.localizedDescription
        }
    }

    private func enrollPassphraseOnly() {
        let p1 = passphraseInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let p2 = confirmPassphraseInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p1.count >= 4 else {
            errorMsg = "Master Passphrase / PIN must be at least 4 characters."
            return
        }
        guard p1 == p2 else {
            errorMsg = "Passphrases do not match."
            return
        }
        errorMsg = nil
        let cleanName = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Koban Owner"
            : displayName.trimmingCharacters(in: .whitespaces)
        var next = config.withMasterPassphrase(p1)
        next.userDisplayName = cleanName
        passphraseInput = ""
        confirmPassphraseInput = ""
        store.completeSignIn(updatedConfig: next)
    }
}

/// radial-gradient(circle at 1px 1px, currentColor 1px, transparent 0) / 28px grid.
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 28
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Zen.ink))
                    x += step
                }
                y += step
            }
        }
    }
}
