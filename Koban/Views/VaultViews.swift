import SwiftUI

/// Centered paper card used by the lock / welcome screens (AuthLockScreen.tsx layout).
/// Shared by UnlockView (Settings & Auth) and SetupScreen (Onboarding).
struct VaultCard<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ZStack {
            Zen.app.ignoresSafeArea()
            WindowDragArea().ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    KobanLogo(height: 30)
                    HStack(spacing: 6) {
                        ZIcon("checkmark.shield", size: 12)
                        Text(L10n.t("lock.encrypted")).font(.zen(11))
                    }
                    .foregroundStyle(Zen.positive)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Zen.positive.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Zen.positive.opacity(0.35), lineWidth: 1))
                    Text(title).font(.zen(18, .semibold)).foregroundStyle(Zen.ink).padding(.top, 2)
                    Text(subtitle)
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(24)

                footer()
                    .font(.zen(11))
                    .foregroundStyle(Zen.ink3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
            }
            .frame(width: 446)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Zen.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VaultErrorView: View {
    @Environment(LedgerStore.self) private var store
    let error: String

    var body: some View {
        VaultCard(title: "Koban could not open its database", subtitle: "The vault file exists but could not be read.") {
            Text(error)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Zen.accent)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
            Button { store.openExistingDatabase() } label: {
                Text(L10n.t("lock.openAnotherDb")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.zen(.ink, height: 36, radius: 10))
        } footer: {
            Text(store.databaseURL.path).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Shared Vault Format v2 UI Components (macOS)

struct PassphraseStrengthBarView: View {
    let passphrase: String
    var minimumLength: Int = VaultCrypto.minPassphraseLength
    var onGenerate: ((String) -> Void)?

    var body: some View {
        let info = AuthCrypto.evaluatePassphraseStrength(passphrase, minimumLength: minimumLength)
        let color: Color = {
            switch info.score {
            case 0, 1: return Zen.accent
            case 2: return Zen.warning
            case 3: return Zen.indigo
            default: return Zen.positive
            }
        }()
        let pct = info.length == 0 ? 0.0 : min(1.0, max(0.12, Double(info.score) * 0.25))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(info.length > 0 ? "\(info.label) · ~\(info.estimatedBits) bits" : info.label)
                    .font(.zen(11, .medium))
                    .foregroundStyle(info.meetsMinimum ? Zen.ink2 : Zen.accent)
                Spacer()
                if let onGenerate {
                    Button {
                        onGenerate(AuthCrypto.generateStrongPassphrase())
                    } label: {
                        HStack(spacing: 4) {
                            ZIcon("sparkles", size: 11)
                            Text("Generate Passphrase")
                        }
                        .font(.zen(11, .medium))
                        .foregroundStyle(Zen.indigo)
                    }
                    .buttonStyle(.plain)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Zen.raised)
                    Capsule().fill(color).frame(width: geo.size.width * pct)
                }
            }
            .frame(height: 5)
        }
    }
}

struct KeyFileSelectorView: View {
    @Binding var keyfileURL: URL?
    var allowGenerate: Bool = true
    var rememberBinding: Binding<Bool>?
    var requiredBadge: Bool = false
    var compact: Bool = false
    var onStatus: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: 8) {
                ZIcon("key.viewfinder", size: 14).foregroundStyle(Zen.indigo).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Optional Key File (.key)")
                            .font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                        if requiredBadge {
                            Text("Required")
                                .font(.zen(10, .medium))
                                .foregroundStyle(Zen.warning)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Zen.warning.opacity(0.14), in: Capsule())
                        }
                    }
                    if !compact {
                        Text("Pair a local Key File alongside your Master Password (KeePassXC-style composite key). Store the .key file outside cloud-synced folders.")
                            .font(.zen(11)).foregroundStyle(Zen.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if keyfileURL != nil {
                    Button { keyfileURL = nil } label: { ZIcon("xmark", size: 12).foregroundStyle(Zen.ink3) }
                        .buttonStyle(.plain)
                }
            }

            if let url = keyfileURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Zen.ink)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Zen.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Zen.line, lineWidth: 1))
            }

            HStack(spacing: 8) {
                Button {
                    if let url = DataIOPanels.open(extensions: [], title: "Select Key File (.key or any file)") {
                        keyfileURL = url
                    }
                } label: {
                    HStack(spacing: 6) {
                        ZIcon("folder", size: 12)
                        Text("Select Key File")
                    }
                }
                .buttonStyle(.zen(.outline, height: 28, radius: 6, padding: 10, fontSize: 11))

                if allowGenerate {
                    Button {
                        if let url = DataIOPanels.save(defaultName: "koban-vault.key", extensions: ["key"], title: "Create New Key File (.key)") {
                            if let generated = try? VaultCrypto.generateKeyFileJSON() {
                                try? Data(generated.json.utf8).write(to: url, options: .atomic)
                                keyfileURL = url
                                onStatus?("Created 256-bit Key File (\(generated.fingerprint))")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            ZIcon("sparkles", size: 12)
                            Text("Create Key File (.key)")
                        }
                    }
                    .buttonStyle(.zen(.raised, height: 28, radius: 6, padding: 10, fontSize: 11))
                }
            }

            if keyfileURL != nil, let rememberBinding {
                Toggle("Remember Key File path on this Mac (file still required on unlock)", isOn: rememberBinding)
                    .toggleStyle(.checkbox)
                    .font(.zen(11))
                    .foregroundStyle(Zen.ink2)
            }
        }
        .padding(compact ? 10 : 12)
        .background(Zen.app.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))
    }
}

struct RecoveryKeyOverlayModal: View {
    let recoveryKey: String
    let onConfirm: () -> Void

    @State private var confirmed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZIcon("key.fill", size: 18).foregroundStyle(Zen.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("One-Time Emergency Recovery Key (160-bit)")
                            .font(.zen(14, .semibold)).foregroundStyle(Zen.ink)
                        Text("Crockford Base32 · Shown once and never stored in plaintext")
                            .font(.zen(11)).foregroundStyle(Zen.ink3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(Zen.app.opacity(0.6))
                .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Save this Recovery Key offline (printed paper or a password manager). It is the only way to recover your Koban database if you forget your Master Password or lose your Key File.")
                        .font(.zen(12)).foregroundStyle(Zen.ink2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(recoveryKey)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Zen.ink)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Zen.app, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Zen.line, lineWidth: 1))

                    HStack(spacing: 10) {
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recoveryKey, forType: .string)
                            copied = true
                        } label: {
                            HStack(spacing: 6) {
                                ZIcon(copied ? "checkmark" : "doc.on.doc", size: 12)
                                Text(copied ? "Copied" : "Copy Key")
                            }
                        }
                        .buttonStyle(.zen(.outline, height: 30, radius: 8, padding: 12, fontSize: 12))

                        Button {
                            if let url = DataIOPanels.save(defaultName: "koban-recovery-key.txt", extensions: ["txt"], title: "Save Recovery Key") {
                                let body = "Koban Vault Format v2 — Emergency Recovery Key\n==================================================\n\nRecovery Key: \(recoveryKey)\n\nStore offline in a safe place.\n"
                                try? Data(body.utf8).write(to: url, options: .atomic)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                ZIcon("square.and.arrow.down", size: 12)
                                Text("Save .txt Backup")
                            }
                        }
                        .buttonStyle(.zen(.outline, height: 30, radius: 8, padding: 12, fontSize: 12))
                        Spacer()
                    }

                    Toggle("I have saved this Recovery Key in a safe place", isOn: $confirmed)
                        .toggleStyle(.checkbox)
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink)
                }
                .padding(20)

                HStack {
                    Spacer()
                    Button("Continue to Vault", action: onConfirm)
                        .buttonStyle(.zen(.ink, height: 34, radius: 8, padding: 18, fontSize: 12))
                        .disabled(!confirmed)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Zen.app.opacity(0.5))
                .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
            }
            .frame(width: 500)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Zen.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
    }
}
