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
                Text("Open Another Database…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.zen(.ink, height: 36, radius: 10))
        } footer: {
            Text(store.databaseURL.path).lineLimit(1).truncationMode(.middle)
        }
    }
}
