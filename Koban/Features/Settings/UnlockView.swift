import AppKit
import SwiftUI

/// Vault Format v2 Unlock & Legacy v1 Migration screen.
/// Mirrors `src/components/AuthLockScreen.tsx`.
struct UnlockView: View {
    @Environment(LedgerStore.self) private var store
    let message: String?

    @State private var unlockTab: UnlockTab = .password
    @State private var passphrase = ""
    @State private var showPassphrase = false
    @State private var keyfileURL: URL?
    @State private var showKeyFileBox = false
    @State private var rememberKeyfile = false
    @State private var recoveryInput = ""

    // Legacy v1 -> Vault v2 migration state
    @State private var v1Passphrase = ""
    @State private var v1Unlocked = false
    @State private var v1OwnerName: String?
    @State private var newPassphrase = ""
    @State private var confirmNewPassphrase = ""
    @State private var migrationKeyfileURL: URL?
    @State private var rememberMigrationKeyfile = false
    @State private var createRecoveryKey = true

    @State private var busy = false
    @State private var errorMsg: String?
    @State private var statusNote: String?
    @State private var didAutoTouchID = false

    enum UnlockTab { case password, recovery }

    private var vaultStatus: VaultStatus? { AuthCenter.shared.vaultStatus }
    private var needsMigration: Bool { vaultStatus?.needsMigration ?? false }
    private var hasLegacyCustom: Bool { vaultStatus?.hasLegacyCustomPassphrase ?? false }
    private var requiresKeyFile: Bool { vaultStatus?.requiresKeyFile ?? false }
    private var touchIDEnrolled: Bool { vaultStatus?.deviceSlotEnrolled ?? false }

    var body: some View {
        VaultCard(
            title: needsMigration ? "Upgrade Legacy Database (v2)" : L10n.t("lock.signIn"),
            subtitle: vaultStatus?.dbPath.components(separatedBy: "/").last ?? "koban.db"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let err = errorMsg ?? message, !err.isEmpty {
                    callOut(text: err, isError: true)
                }
                if let statusNote, errorMsg == nil {
                    callOut(text: statusNote, isError: false)
                }

                if needsMigration {
                    migrationBody
                } else {
                    v2UnlockBody
                }
            }
        } footer: {
            HStack {
                Button { store.openExistingDatabase() } label: {
                    HStack(spacing: 5) {
                        ZIcon("folder", size: 12)
                        Text(L10n.t("lock.openAnotherDb"))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Zen.ink2)

                Spacer()

                Button { store.presentWebDavConnect() } label: {
                    HStack(spacing: 5) {
                        ZIcon("icloud.and.arrow.down", size: 12)
                        Text(L10n.t("onboarding.openWebDav"))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Zen.ink2)
            }
        }
        .onAppear {
            AuthCenter.shared.refresh(store: store, force: true)
            if let remembered = AuthCenter.shared.rememberedKeyfileURL {
                keyfileURL = remembered
                rememberKeyfile = true
                showKeyFileBox = true
            } else if requiresKeyFile {
                showKeyFileBox = true
            }
            v1Unlocked = !hasLegacyCustom
            if needsMigration && !hasLegacyCustom {
                if let preview = try? store.unlockV1ForMigration(passphrase: nil) {
                    v1Unlocked = true
                    v1OwnerName = preview.state.settings.ownerDisplayName
                }
            }
            autoTriggerTouchIDIfReady()
        }
    }

    // MARK: - Vault Format v2 Unlock

    @ViewBuilder
    private var v2UnlockBody: some View {
        if touchIDEnrolled {
            Button {
                triggerTouchID()
            } label: {
                HStack(spacing: 8) {
                    ZIcon("touchid", size: 15)
                    Text("Unlock with \(TouchIDKeychain.methodName)")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zen(.ink, height: 38, radius: 10))
            .disabled(busy)
        }

        HStack(spacing: 4) {
            tabPill(L10n.t("lock.passphraseLabel"), icon: "lock", selected: unlockTab == .password) {
                unlockTab = .password
                errorMsg = nil
            }
            tabPill("Recovery Key", icon: "key", selected: unlockTab == .recovery) {
                unlockTab = .recovery
                errorMsg = nil
            }
        }
        .padding(3)
        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))

        if unlockTab == .password {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("lock.passphraseLabel"))
                    .font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                passwordField(
                    text: $passphrase,
                    placeholder: L10n.t("lock.passphrasePlaceholder"),
                    revealed: $showPassphrase,
                    onSubmit: submitPasswordUnlock
                )

                if requiresKeyFile || showKeyFileBox {
                    KeyFileSelectorView(
                        keyfileURL: $keyfileURL,
                        allowGenerate: false,
                        rememberBinding: $rememberKeyfile,
                        requiredBadge: requiresKeyFile,
                        compact: true
                    )
                } else {
                    Button { showKeyFileBox = true } label: {
                        HStack(spacing: 5) {
                            ZIcon("key.viewfinder", size: 12)
                            Text("Use Key File (.key)")
                        }
                        .font(.zen(11, .medium)).foregroundStyle(Zen.indigo)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: submitPasswordUnlock) {
                    Text(L10n.t("lock.unlockPassphrase")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(touchIDEnrolled ? .outline : .ink, height: 38, radius: 10))
                .disabled(busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("160-bit Recovery Key (Crockford Base32)")
                    .font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                TextField("", text: $recoveryInput, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX").foregroundStyle(Zen.ink3))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Zen.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                    .onSubmit(submitRecoveryUnlock)

                Button(action: submitRecoveryUnlock) {
                    Text("Unlock with Recovery Key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(.ink, height: 38, radius: 10))
                .disabled(busy)
            }
        }
    }

    // MARK: - Legacy v1 -> v2 Migration

    @ViewBuilder
    private var migrationBody: some View {
        if !v1Unlocked {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter your legacy v1 vault passphrase to inspect and upgrade this database to Vault Format v2.")
                    .font(.zen(12)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $v1Passphrase, prompt: Text("Legacy v1 passphrase").foregroundStyle(Zen.ink3))
                    .textFieldStyle(.plain)
                    .font(.zen(12)).foregroundStyle(Zen.ink)
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                    .onSubmit(verifyLegacyV1)
                Button(action: verifyLegacyV1) {
                    Text("Verify Legacy Vault").frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(.ink, height: 38, radius: 10))
                .disabled(busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(v1OwnerName.map { "Upgrading vault for \($0). " } ?? "")Upgrades your database from v1 to Argon2id key derivation, composite Key File support, 160-bit recovery key, and strict sync protection.")
                    .font(.zen(11)).foregroundStyle(Zen.ink2).fixedSize(horizontal: false, vertical: true)

                let minLen = migrationKeyfileURL != nil ? VaultCrypto.minCompositePassphraseLength : VaultCrypto.minPassphraseLength
                Text("New Master Password (min \(minLen) chars)")
                    .font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                passwordField(text: $newPassphrase, placeholder: "Choose Master Password", revealed: $showPassphrase, onSubmit: {})
                PassphraseStrengthBarView(passphrase: newPassphrase, minimumLength: minLen) { generated in
                    newPassphrase = generated
                    confirmNewPassphrase = generated
                    showPassphrase = true
                }

                Text("Confirm Master Password").font(.zen(11, .medium)).foregroundStyle(Zen.ink2)
                passwordField(text: $confirmNewPassphrase, placeholder: "Repeat Master Password", revealed: $showPassphrase, onSubmit: submitMigration)

                KeyFileSelectorView(
                    keyfileURL: $migrationKeyfileURL,
                    allowGenerate: true,
                    rememberBinding: $rememberMigrationKeyfile,
                    onStatus: { statusNote = $0 }
                )

                Toggle("Generate a 160-bit emergency Recovery Key (recommended)", isOn: $createRecoveryKey)
                    .toggleStyle(.checkbox)
                    .font(.zen(12))
                    .foregroundStyle(Zen.ink2)

                Button(action: submitMigration) {
                    Text("Upgrade & Encrypt Vault (v2)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(.ink, height: 38, radius: 10))
                .disabled(busy)
            }
        }
    }

    // MARK: - Actions

    private func autoTriggerTouchIDIfReady() {
        guard !needsMigration,
              touchIDEnrolled,
              vaultStatus?.authSettings.autoPromptDevice == true,
              !didAutoTouchID else { return }
        didAutoTouchID = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            triggerTouchID()
        }
    }

    private func triggerTouchID() {
        errorMsg = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.unlockWithTouchID()
            } catch {
                errorMsg = DataIOMessages.text(error)
            }
        }
    }

    private func submitPasswordUnlock() {
        errorMsg = nil
        guard !passphrase.isEmpty else {
            errorMsg = "Please enter your Master Password."
            return
        }
        if requiresKeyFile && keyfileURL == nil {
            showKeyFileBox = true
            errorMsg = "Please select your Key File (.key) in addition to your Master Password."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try store.unlockWithCredentials(
                passphrase: passphrase,
                keyfileURL: keyfileURL,
                rememberKeyfile: keyfileURL != nil && rememberKeyfile
            )
            passphrase = ""
        } catch {
            errorMsg = DataIOMessages.text(error)
        }
    }

    private func submitRecoveryUnlock() {
        errorMsg = nil
        let clean = recoveryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorMsg = "Please enter your 160-bit Recovery Key."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try store.unlockWithRecovery(clean)
            recoveryInput = ""
        } catch {
            errorMsg = DataIOMessages.text(error)
        }
    }

    private func verifyLegacyV1() {
        errorMsg = nil
        busy = true
        defer { busy = false }
        do {
            let preview = try store.unlockV1ForMigration(passphrase: v1Passphrase.isEmpty ? nil : v1Passphrase)
            v1OwnerName = preview.state.settings.ownerDisplayName
            v1Unlocked = true
        } catch {
            errorMsg = DataIOMessages.text(error)
        }
    }

    private func submitMigration() {
        errorMsg = nil
        let minLen = migrationKeyfileURL != nil ? VaultCrypto.minCompositePassphraseLength : VaultCrypto.minPassphraseLength
        guard newPassphrase.count >= minLen else {
            errorMsg = "Master Password must be at least \(minLen) characters."
            return
        }
        guard newPassphrase.trimmingCharacters(in: .whitespacesAndNewlines) == newPassphrase else {
            errorMsg = "Master Password cannot start or end with spaces."
            return
        }
        guard newPassphrase == confirmNewPassphrase else {
            errorMsg = "Passphrases do not match."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try store.migrateV1ToV2(
                v1Passphrase: hasLegacyCustom ? v1Passphrase : nil,
                newPassphrase: newPassphrase,
                keyfileURL: migrationKeyfileURL,
                rememberKeyfile: rememberMigrationKeyfile,
                createRecoveryKey: createRecoveryKey
            )
        } catch {
            errorMsg = DataIOMessages.text(error)
        }
    }

    // MARK: - Subviews

    private func tabPill(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZIcon(icon, size: 12)
                Text(title).font(.zen(12, .medium))
            }
            .foregroundStyle(selected ? Zen.ink : Zen.ink3)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(selected ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func passwordField(text: Binding<String>, placeholder: String, revealed: Binding<Bool>, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Group {
                if revealed.wrappedValue {
                    TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
                } else {
                    SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(Zen.ink3))
                }
            }
            .textFieldStyle(.plain)
            .font(.zen(12)).foregroundStyle(Zen.ink)
            .onSubmit(onSubmit)

            Button { revealed.wrappedValue.toggle() } label: {
                ZIcon(revealed.wrappedValue ? "eye.slash" : "eye", size: 13).foregroundStyle(Zen.ink3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func callOut(text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZIcon(isError ? "exclamationmark.triangle" : "checkmark.circle", size: 14)
                .foregroundStyle(isError ? Zen.accent : Zen.positive)
                .padding(.top, 1)
            Text(text)
                .font(.zen(12))
                .foregroundStyle(isError ? Zen.accent : Zen.positive)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Zen.accent : Zen.positive).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((isError ? Zen.accent : Zen.positive).opacity(0.25), lineWidth: 1))
    }
}
