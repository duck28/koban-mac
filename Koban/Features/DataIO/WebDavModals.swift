import SwiftUI

// OWNER: Data I/O — WebDAV conflict dialog (WEBDAV-SPEC §5) and the first-run
// "Open Vault from WebDAV…" form (§6). Presented through store.present (window-wide ZenModal).

/// Shared header / footer chrome of the WebDAV modals (MonthCopyModal look).
private struct WebDavModalHeader: View {
    let icon: String
    let iconColor: Color
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ZIcon(icon).foregroundStyle(iconColor)
            Text(title).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onClose { ZenMiniButton(icon: "xmark", size: 16, action: onClose) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Zen.app.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }
    }
}

private extension View {
    func webDavModalFooter() -> some View {
        self.padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Zen.app.opacity(0.5))
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }
}

enum WebDavFormat {
    /// HTTP-date (RFC 7231) → local short date + time; the raw header when it doesn't parse.
    static func httpDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let d = f.date(from: raw) else { return raw }
        return time(d)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Conflict dialog

struct WebDavConflictModal: View {
    @Environment(LedgerStore.self) private var store
    let info: WebDavSyncCenter.ConflictInfo
    @State private var working: WebDavSyncCenter.Resolution?

    private var title: String {
        info.firstLink ? "A Koban vault already exists at this WebDAV location" : "Cloud vault changed on another device"
    }

    private var message: String {
        info.firstLink
            ? "This device has not synced with this WebDAV location before, and both have data. Choose which version to keep — the other one is kept as a backup file."
            : "Both the WebDAV copy and this device have changes since the last sync. Choose which version to keep — the other one is kept as a backup file."
    }

    var body: some View {
        VStack(spacing: 0) {
            WebDavModalHeader(icon: info.firstLink ? "icloud" : "exclamationmark.triangle",
                              iconColor: info.firstLink ? Zen.indigo : Zen.accent, title: title)

            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(.zen(12)).foregroundStyle(Zen.ink).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    infoRow(icon: "icloud", label: "WebDAV copy last modified",
                            value: WebDavFormat.httpDate(info.remoteLastModified) ?? "Unknown")
                    infoRow(icon: "desktopcomputer", label: "This device last saved",
                            value: info.localSavedAt.map(WebDavFormat.time) ?? "Unknown")
                    if let target = store.state.settings.webdav.map(WebDav.targetURL) {
                        infoRow(icon: "server.rack", label: "Location", value: target, mono: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))

                (Text("Using the cloud version keeps this device's data as ") + dataIOCode("koban-pre-webdav-sync-<time>.db", color: Zen.ink2)
                 + Text("; keeping this device's version saves the cloud copy as ") + dataIOCode("koban-webdav-conflict-<time>.db", color: Zen.ink2)
                 + Text(" next to your local vault."))
                    .font(.zen(11)).foregroundStyle(Zen.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            HStack(spacing: 10) {
                Button(info.firstLink ? "Cancel" : "Decide later") {
                    resolve(info.firstLink ? .cancelFirstLink : .decideLater)
                }
                .buttonStyle(.zen(.ghost, height: 34, padding: 14))
                .keyboardShortcut(.cancelAction)
                .help(info.firstLink ? "Switch WebDAV back to backup mode" : "Pause sync until you decide")
                Spacer(minLength: 8)
                Button { resolve(.keepLocal) } label: {
                    HStack(spacing: 6) {
                        if working == .keepLocal { DataIOSpinner(size: 14) } else { ZIcon("icloud.and.arrow.up", size: 14) }
                        Text(info.firstLink ? "Upload this device's data" : "Keep this device's version")
                    }
                }
                .buttonStyle(.zen(.outline, height: 34, padding: 14))
                Button { resolve(.useCloud) } label: {
                    HStack(spacing: 6) {
                        if working == .useCloud { DataIOSpinner(size: 14) } else { ZIcon("icloud.and.arrow.down", size: 14) }
                        Text(info.firstLink ? "Use the cloud vault" : "Use cloud version").fontWeight(.medium)
                    }
                }
                .buttonStyle(.zen(.ink, height: 34, padding: 16))
                .keyboardShortcut(.defaultAction)
            }
            .disabled(working != nil)
            .webDavModalFooter()
        }
        .frame(width: 560)
    }

    private func infoRow(icon: String, label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZIcon(icon, size: 14).foregroundStyle(Zen.ink3)
            Text(label).font(.zen(12)).foregroundStyle(Zen.ink2)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .zen(12, .medium))
                .foregroundStyle(Zen.ink)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func resolve(_ r: WebDavSyncCenter.Resolution) {
        working = r
        Task {
            await WebDavSyncCenter.shared.resolve(r)
            working = nil
        }
    }
}

// MARK: - First run: Open Vault from WebDAV…

struct WebDavConnectModal: View {
    @Environment(LedgerStore.self) private var store
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var fileName = WebDav.defaultRemoteFileName
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var isDownloading = false
    @State private var feedback: (kind: DataIOBanner.Kind, text: String)?

    private var busy: Bool { isTesting || isDownloading }

    private var config: WebDavConfig {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return WebDavConfig(enabled: true, url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                            remoteFileName: name.isEmpty ? WebDav.defaultRemoteFileName : name,
                            autoSync: true, mode: .primary)
    }

    private var complete: Bool {
        let c = config
        return !c.url.isEmpty && !c.username.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            WebDavModalHeader(icon: "icloud.and.arrow.down", iconColor: Zen.indigo, title: "Open Vault from WebDAV",
                              onClose: busy ? nil : { store.dismissModal() })

            VStack(alignment: .leading, spacing: 14) {
                Text("Download an existing Koban vault — for example one kept by your Windows PC or another Mac — and use the WebDAV copy as this device's primary storage. Koban keeps an encrypted local cache for offline use.")
                    .font(.zen(12)).foregroundStyle(Zen.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let feedback { DataIOBanner(kind: feedback.kind, text: feedback.text) }

                field("WebDAV Server URL") {
                    DataIOTextField(placeholder: "https://nextcloud.example.com/remote.php/dav/files/myuser/Koban/",
                                    text: $url, icon: "server.rack")
                }
                HStack(alignment: .top, spacing: 12) {
                    field("WebDAV Username") {
                        DataIOTextField(placeholder: "user@example.com or username", text: $username)
                    }
                    field("Remote Database Filename") {
                        DataIOTextField(placeholder: WebDav.defaultRemoteFileName, text: $fileName, monospaced: true)
                    }
                    .frame(width: 200)
                }
                field("WebDAV Password / App Token") {
                    ZStack(alignment: .trailing) {
                        DataIOTextField(placeholder: "Account password or generated WebDAV app token",
                                        text: $password, icon: "lock", secure: !showPassword, trailingPadding: 36)
                        ZenMiniButton(icon: showPassword ? "eye.slash" : "eye", size: 14,
                                      help: showPassword ? "Hide password" : "Show password") { showPassword.toggle() }
                            .padding(.trailing, 6)
                    }
                }
                (Text("An existing local vault on this Mac is kept as ") + dataIOCode("koban-pre-webdav-sync-<time>.db", color: Zen.ink2)
                 + Text(". A vault protected by a custom passphrase asks for it after the download."))
                    .font(.zen(11)).foregroundStyle(Zen.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            HStack(spacing: 10) {
                Button("Cancel") { store.dismissModal() }
                    .buttonStyle(.zen(.ghost, height: 34, padding: 14))
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Spacer(minLength: 8)
                Button(action: test) {
                    HStack(spacing: 6) {
                        if isTesting { DataIOSpinner(size: 14) } else { ZIcon("arrow.clockwise", size: 14) }
                        Text("Test")
                    }
                }
                .buttonStyle(.zen(.outline, height: 34, padding: 14))
                .disabled(busy)
                Button(action: download) {
                    HStack(spacing: 6) {
                        if isDownloading { DataIOSpinner(size: 14) } else { ZIcon("icloud.and.arrow.down", size: 14) }
                        Text("Download & Open").fontWeight(.medium)
                    }
                }
                .buttonStyle(.zen(.ink, height: 34, padding: 16))
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
            .webDavModalFooter()
        }
        .frame(width: 560)
        #if DEBUG
        .onAppear {
            // Debug snapshots: KOBAN_SNAPSHOT_ACTION=webdav-connect-filled shows a filled-in form.
            if ProcessInfo.processInfo.environment["KOBAN_SNAPSHOT_ACTION"] == "webdav-connect-filled" {
                url = "https://cloud.example.com/remote.php/dav/files/me/Koban/"
                username = "me"
                password = "app-token"
                feedback = (.success, "WebDAV connection verified successfully (HTTP 207/200). Found koban-vault.db (148 KB).")
            }
        }
        #endif
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DataIOFieldLabel(label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func test() {
        guard complete else {
            feedback = (.error, "Please enter WebDAV Server URL, Username, and Password / App Token.")
            return
        }
        isTesting = true
        feedback = nil
        let c = config
        Task {
            defer { isTesting = false }
            do {
                let msg = try await WebDav.testConnection(url: c.url, username: c.username, password: c.password ?? "")
                let info = try await WebDav.remoteInfo(url: c.url, username: c.username, password: c.password ?? "",
                                                       filename: c.remoteFileName)
                let name = c.remoteFileName ?? WebDav.defaultRemoteFileName
                if info.exists {
                    let size = info.size.map { " (\(DataIOStorage.formatBytes(Int64($0))))" } ?? ""
                    feedback = (.success, "\(msg) Found \(name)\(size).")
                } else {
                    feedback = (.error, "\(msg) But no vault named \(name) exists at this location yet.")
                }
            } catch {
                feedback = (.error, DataIOMessages.text(error))
            }
        }
    }

    private func download() {
        guard complete else {
            feedback = (.error, "Please enter WebDAV Server URL, Username, and Password / App Token.")
            return
        }
        isDownloading = true
        feedback = nil
        let c = config
        Task {
            defer { isDownloading = false }
            do {
                try await WebDavSyncCenter.shared.connectNewDevice(store, config: c)
                if store.modal?.id == WebDavSyncCenter.connectModalId { store.dismissModal() }
                if case .failed(let message) = store.phase {
                    store.notify("The downloaded vault could not be opened: \(message)")
                }
            } catch {
                feedback = (.error, DataIOMessages.text(error))
            }
        }
    }
}
