import SwiftUI

// OWNER: Data I/O. Also embedded by SettingsView (DbLocationCard.tsx / WebDavSyncCard.tsx).

/// Port of src/components/DbLocationCard.tsx — relocate / reset the encrypted database file.
struct DbLocationCard: View {
    @Environment(LedgerStore.self) private var store
    @State private var center = DataIOCenter.shared
    @State private var isProcessing = false
    @State private var statusMsg: String?
    @State private var errorMsg: String?
    @State private var pendingMoveFolder: String?
    @State private var showConfirmReset = false

    var body: some View {
        let info = center.dbInfo
        VStack(alignment: .leading, spacing: 16) {
            // Header
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    header(info)
                    Spacer(minLength: 12)
                    finderButton(info)
                }
                VStack(alignment: .leading, spacing: 12) {
                    header(info)
                    finderButton(info)
                }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            if let statusMsg { DataIOBanner(kind: .success, text: statusMsg) }
            if let errorMsg { DataIOBanner(kind: .error, text: errorMsg) }

            // Current path + actions
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    DataIOFieldLabel(L10n.t("dbLoc.activePathLabel"))
                    HStack(spacing: 8) {
                        Text(info?.dbPath ?? L10n.t("dbLoc.detectingPath"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Zen.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 280, maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                            .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                        Button(action: browseFolder) {
                            HStack(spacing: 6) { ZIcon("folder", size: 14); Text(L10n.t("dbLoc.moveBtn")) }
                        }
                        .buttonStyle(DataIOInkButtonStyle(height: 36, padding: 14))
                        .disabled(isProcessing)
                        if info?.isCustomLocation == true {
                            Button { showConfirmReset = true } label: {
                                HStack(spacing: 6) { ZIcon("arrow.counterclockwise", size: 14); Text(L10n.t("dbLoc.resetBtn")) }
                            }
                            .buttonStyle(DataIORaisedButtonStyle(height: 36, mutedText: true))
                            .disabled(isProcessing)
                            .help(L10n.t("dbLoc.resetMacTip"))
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { stats(info); Spacer(minLength: 8); footnote }
                    VStack(alignment: .leading, spacing: 8) { stats(info); footnote }
                }
                .padding(.top, 4)
            }

            if let folder = pendingMoveFolder { moveDrawer(folder) }
            if showConfirmReset { resetDrawer }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        .task { if center.dbInfo == nil { center.refresh(store) } }
    }

    private func header(_ info: DbInfo?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZIcon("internaldrive", size: 20).foregroundStyle(Zen.indigo)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(L10n.t("dbLoc.title")).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    DataIOPill(text: L10n.t("dbLoc.expertBadge"), foreground: Zen.indigo, background: Zen.indigo.opacity(0.15),
                               border: Zen.indigo.opacity(0.2), weight: .semibold)
                    if info?.isCustomLocation == true {
                        DataIOPill(text: L10n.t("dbLoc.customBadge"), foreground: DataIOColors.amber500,
                                   background: DataIOColors.amber500.opacity(0.15), border: DataIOColors.amber500.opacity(0.2))
                    } else {
                        DataIOPill(text: L10n.t("dbLoc.defaultBadgeMac"), foreground: Zen.ink2, background: Zen.raised, border: Zen.line)
                    }
                }
                (Text(L10n.t("dbLoc.descPrefix")) + dataIOCode("koban.db")
                 + Text(L10n.t("dbLoc.descSuffix")))
                    .font(.zen(12)).foregroundStyle(Zen.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func finderButton(_ info: DbInfo?) -> some View {
        if let path = info?.dbPath, !path.isEmpty {
            Button { DataIOPanels.reveal(path) } label: {
                HStack(spacing: 6) { ZIcon("arrow.up.right.square", size: 14); Text(L10n.t("dbLoc.showInFinder")) }
            }
            .buttonStyle(DataIORaisedButtonStyle(mutedText: true))
            .help(L10n.t("dbLoc.showInFinderTip"))
            .fixedSize()
        }
    }

    private func stats(_ info: DbInfo?) -> some View {
        HStack(spacing: 12) {
            (Text("\(L10n.t("dbLoc.sizeLabel")) ") + Text(DataIOStorage.formatBytes(info?.dbSize ?? 0)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(Zen.ink2))
            (Text("\(L10n.t("dbLoc.cipherLabel")) ") + Text(info?.cipher ?? "AES-256-GCM").fontWeight(.bold).foregroundColor(Zen.ink2))
            (Text("\(L10n.t("dbLoc.recordsLabel")) ") + Text("\(info?.encryptedRecords ?? 0)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(Zen.ink2))
        }
        .font(.zen(11)).foregroundStyle(Zen.ink3)
        .fixedSize()
    }

    private var footnote: some View {
        Text(L10n.t("dbLoc.footnote"))
            .font(.zen(11)).foregroundStyle(Zen.ink3)
    }

    private func moveDrawer(_ folder: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZIcon("exclamationmark.triangle", size: 16).foregroundStyle(DataIOColors.amber500).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("dbLoc.confirmMoveTitle")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    (Text(L10n.t("dbLoc.confirmMoveBodyPrefix")) + dataIOCode("koban.db") + Text(L10n.t("dbLoc.confirmMoveBodySuffix")))
                        .font(.zen(12)).foregroundStyle(Zen.ink2)
                    Text(((try? DataIOStorage.targetDatabaseURL(forFolder: folder))?.path) ?? folder)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Zen.ink)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                    Text(L10n.t("dbLoc.confirmMoveNote"))
                        .font(.zen(11)).foregroundStyle(Zen.ink3)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t("common.cancel")) { pendingMoveFolder = nil }
                    .buttonStyle(DataIORaisedButtonStyle(background: Zen.surface))
                    .disabled(isProcessing)
                Button(action: executeMove) {
                    HStack(spacing: 6) {
                        if isProcessing { DataIOSpinner(size: 14) }
                        Text(L10n.t("dbLoc.confirmMoveBtn"))
                    }
                }
                .buttonStyle(DataIOAmberButtonStyle())
                .disabled(isProcessing)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DataIOColors.amber500.opacity(0.3), lineWidth: 1))
    }

    private var resetDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZIcon("arrow.counterclockwise", size: 16).foregroundStyle(Zen.indigo).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("dbLoc.confirmResetTitle")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    (Text(L10n.t("dbLoc.confirmResetMacPrefix"))
                     + dataIOCode("~/Library/Application Support/Koban/koban.db")
                     + Text(L10n.t("dbLoc.confirmResetSuffix")))
                        .font(.zen(12)).foregroundStyle(Zen.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t("common.cancel")) { showConfirmReset = false }
                    .buttonStyle(DataIORaisedButtonStyle(background: Zen.surface))
                    .disabled(isProcessing)
                Button(action: executeReset) {
                    HStack(spacing: 6) {
                        if isProcessing { DataIOSpinner(size: 14) }
                        Text(L10n.t("dbLoc.resetBtn"))
                    }
                }
                .buttonStyle(DataIOInkButtonStyle(padding: 16))
                .disabled(isProcessing)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func browseFolder() {
        statusMsg = nil
        errorMsg = nil
        if let url = DataIOPanels.folder(title: L10n.t("dbLoc.moveBtn")) {
            pendingMoveFolder = url.path
        }
    }

    private func executeMove() {
        guard let folder = pendingMoveFolder else { return }
        isProcessing = true
        statusMsg = nil
        errorMsg = nil
        defer { isProcessing = false }
        do {
            try store.moveDatabase(toFolder: folder)
            pendingMoveFolder = nil
            center.refresh(store)
            statusMsg = L10n.tf("dbLoc.relocatedSuccess", ["path": center.dbInfo?.dbPath ?? store.databaseURL.path])
        } catch {
            errorMsg = DataIOMessages.text(error)
            center.refresh(store)
        }
    }

    private func executeReset() {
        isProcessing = true
        statusMsg = nil
        errorMsg = nil
        defer { isProcessing = false }
        do {
            try store.resetDatabaseLocation()
            showConfirmReset = false
            center.refresh(store)
            statusMsg = L10n.t("dbLoc.resetSuccessMac")
        } catch {
            errorMsg = DataIOMessages.text(error)
            center.refresh(store)
        }
    }
}

/// Port of src/components/WebDavSyncCard.tsx — WebDAV cloud sync of the encrypted database.
struct WebDavSyncCard: View {
    @Environment(LedgerStore.self) private var store
    @State private var form: WebDavConfig?
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var isPushing = false
    @State private var isPulling = false
    @State private var feedback: (kind: DataIOBanner.Kind, text: String)?
    @State private var showConfirmPull = false
    @State private var viewport: CGFloat = 1000

    private static let blank = WebDavConfig(enabled: false, url: "", username: "", password: "",
                                            remoteFileName: WebDav.defaultRemoteFileName, autoSync: false)

    private var config: WebDavConfig { form ?? store.state.settings.webdav ?? Self.blank }
    private var busy: Bool { isTesting || isPushing || isPulling }

    private func updateConfig(_ patch: (inout WebDavConfig) -> Void) {
        var updated = config
        patch(&updated)
        form = updated
        store.applySettingsChange { $0.webdav = updated }
    }

    private func binding(_ kp: WritableKeyPath<WebDavConfig, String>) -> Binding<String> {
        Binding(get: { config[keyPath: kp] }, set: { v in updateConfig { $0[keyPath: kp] = v } })
    }

    var body: some View {
        let c = config
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) { header; Spacer(minLength: 12); enableToggle }
                VStack(alignment: .leading, spacing: 12) { header; enableToggle }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            if let feedback { DataIOBanner(kind: feedback.kind, text: feedback.text) }

            VStack(alignment: .leading, spacing: 12) {
                formGrid
                modeSection(c)
                if c.effectiveMode == .primary { primaryStatusRow(c) } else { autoSyncRow(c) }
                actionButtons
            }
            .opacity(c.enabled ? 1 : 0.6)

            if showConfirmPull { pullDrawer(c) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            // KOBAN_SNAPSHOT_ACTION=webdav-demo-primary | webdav-demo-offline | webdav-demo-paused |
            // webdav-conflict | webdav-conflict-first (debug snapshots; in-memory demo config only).
            guard let name = note.userInfo?["name"] as? String, name.hasPrefix("webdav-") else { return }
            WebDavSyncCenter.shared.debugDemo(name, store: store)
        }
        #endif
    }

    // MARK: Storage mode (WEBDAV-SPEC §6)

    private func modeDescription(_ mode: WebDavMode) -> String {
        L10n.t(mode == .backup ? "webdav.modeBackupDesc" : "webdav.modePrimaryDesc")
    }

    private func modeSection(_ c: WebDavConfig) -> some View {
        let mode = c.effectiveMode
        let picker = HStack(spacing: 2) {
            SettingsSegmentButton(title: L10n.t("webdav.modeBackup"), icon: "externaldrive", active: mode == .backup,
                                  horizontalPadding: 12) { setMode(.backup) }
            SettingsSegmentButton(title: L10n.t("webdav.modePrimary"), icon: "icloud", active: mode == .primary,
                                  horizontalPadding: 12) { setMode(.primary) }
        }
        .padding(2)
        .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
        .fixedSize()
        let description = Text(modeDescription(mode))
            .font(.zen(11)).foregroundStyle(Zen.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return VStack(alignment: .leading, spacing: 6) {
            DataIOFieldLabel(L10n.t("webdav.storageModeLabel"))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) { picker; description.frame(minWidth: 320) }
                VStack(alignment: .leading, spacing: 8) { picker; description }
            }
        }
    }

    private func setMode(_ mode: WebDavMode) {
        guard config.effectiveMode != mode else { return }
        updateConfig { $0.mode = mode }
        let center = WebDavSyncCenter.shared
        center.install(store: store)
        center.modeChanged(to: mode)
    }

    // MARK: Primary storage status (§4 status line)

    private struct StatusLine {
        var icon: String
        var color: Color
        var title: String
        var detail: String?
    }

    private func statusLine(_ c: WebDavConfig) -> StatusLine {
        let center = WebDavSyncCenter.shared
        guard c.enabled, credentialsComplete else {
            return StatusLine(icon: "pause.circle", color: Zen.ink3, title: L10n.t("webdav.statusNotActive"),
                              detail: L10n.t("webdav.statusEnableHint"))
        }
        switch center.status {
        case .syncing:
            return StatusLine(icon: "arrow.triangle.2.circlepath", color: Zen.indigo, title: L10n.t("webdav.statusSyncing"))
        case .synced(let date):
            return StatusLine(icon: "checkmark.circle", color: Zen.positive, title: "\(L10n.t("webdav.statusSynced")) (\(WebDavFormat.time(date)))")
        case .offline:
            return StatusLine(icon: "wifi.slash", color: DataIOColors.amber600, title: L10n.t("webdav.statusOffline"),
                              detail: WebDavSyncCenter.offlineMessage)
        case .paused:
            return StatusLine(icon: "pause.circle", color: DataIOColors.amber600, title: L10n.t("webdav.statusPaused"),
                              detail: WebDavSyncCenter.pausedMessage)
        case .error(let message):
            return StatusLine(icon: "exclamationmark.triangle", color: DataIOColors.negative, title: message)
        case .none:
            if c.lastSyncMessage == WebDavSyncCenter.offlineMessage {
                return StatusLine(icon: "wifi.slash", color: DataIOColors.amber600, title: L10n.t("webdav.statusOffline"),
                                  detail: WebDavSyncCenter.offlineMessage)
            }
            if c.lastSyncStatus == .error {
                return StatusLine(icon: "exclamationmark.triangle", color: DataIOColors.negative,
                                  title: c.lastSyncMessage ?? L10n.t("webdav.statusError"))
            }
            if let at = c.lastSyncAt, at > 0, c.lastSyncStatus == .success {
                return StatusLine(icon: "checkmark.circle", color: Zen.positive,
                                  title: "\(L10n.t("webdav.statusSynced")) (\(WebDavFormat.time(Date(timeIntervalSince1970: at))))")
            }
            return StatusLine(icon: "circle.dashed", color: Zen.ink3, title: L10n.t("webdav.statusNotSyncedYet"))
        }
    }

    private func primaryStatusRow(_ c: WebDavConfig) -> some View {
        let center = WebDavSyncCenter.shared
        let line = statusLine(c)
        let paused: Bool = { if case .paused = center.status { return true }; return center.isPaused }()
        let syncing: Bool = { if case .syncing = center.status { return true }; return false }()
        let status = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ZIcon(line.icon, size: 14).foregroundStyle(line.color)
                Text(line.title).font(.zen(12, .medium)).foregroundStyle(line.color)
                    .lineLimit(2).textSelection(.enabled)
            }
            Text(line.detail ?? L10n.t("webdav.primaryFootnote"))
                .font(.zen(11)).foregroundStyle(Zen.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let buttons = HStack(spacing: 8) {
            if paused {
                Button { center.reopenConflict() } label: {
                    HStack(spacing: 6) {
                        ZIcon("exclamationmark.triangle", size: 14)
                        Text(L10n.t("webdav.resolveBtn"))
                    }
                }
                .buttonStyle(DataIOAmberButtonStyle())
            }
            Button { center.install(store: store); center.syncNowManually() } label: {
                HStack(spacing: 6) {
                    if syncing { DataIOSpinner(size: 14) } else { ZIcon("arrow.triangle.2.circlepath", size: 14) }
                    Text(L10n.t("webdav.syncNowBtn"))
                }
            }
            .buttonStyle(DataIORaisedButtonStyle(height: 32, padding: 12, background: Zen.surface))
            .disabled(syncing || busy || !c.enabled || !credentialsComplete)
        }
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) { status; buttons }
            VStack(alignment: .leading, spacing: 10) { status; buttons }
        }
        .padding(12)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZIcon("cloud", size: 20).foregroundStyle(Zen.indigo)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(L10n.t("webdav.title")).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    DataIOPill(text: "Nextcloud · ownCloud · NAS · mailbox.org", foreground: Zen.ink2, background: Zen.raised, border: Zen.line)
                }
                Text(L10n.t("webdav.desc"))
                    .font(.zen(12)).foregroundStyle(Zen.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enableToggle: some View {
        Button { updateConfig { $0.enabled.toggle() } } label: {
            HStack(spacing: 8) {
                Text(L10n.t("webdav.enableToggle")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                DataIOCheckSquare(isOn: config.enabled, size: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private var formGrid: some View {
        let url = VStack(alignment: .leading, spacing: 4) {
            DataIOFieldLabel(L10n.t("webdav.urlLabel"))
            DataIOTextField(placeholder: "https://nextcloud.example.com/remote.php/dav/files/myuser/Koban/",
                            text: binding(\.url), icon: "server.rack")
            (Text(L10n.t("webdav.urlTipPrefix")) + dataIOCode("/Koban/", color: Zen.ink2) + Text(L10n.t("webdav.urlTipSuffix")))
                .font(.zen(10)).foregroundStyle(Zen.ink3)
        }
        let file = VStack(alignment: .leading, spacing: 4) {
            DataIOFieldLabel(L10n.t("webdav.filenameLabel"))
            DataIOTextField(placeholder: WebDav.defaultRemoteFileName,
                            text: Binding(get: {
                                let v = config.remoteFileName ?? ""
                                return v.isEmpty ? WebDav.defaultRemoteFileName : v
                            }, set: { v in updateConfig { $0.remoteFileName = v } }),
                            monospaced: true)
            Text(" ").font(.zen(10))
        }
        let user = VStack(alignment: .leading, spacing: 4) {
            DataIOFieldLabel(L10n.t("webdav.usernameLabel"))
            DataIOTextField(placeholder: L10n.t("webdav.usernamePlaceholder"), text: binding(\.username))
            Text(" ").font(.zen(10))
        }
        let pass = VStack(alignment: .leading, spacing: 4) {
            DataIOFieldLabel(L10n.t("webdav.passwordLabel"))
            ZStack(alignment: .trailing) {
                DataIOTextField(placeholder: L10n.t("webdav.passwordPlaceholder"),
                                text: Binding(get: { config.password ?? "" }, set: { v in updateConfig { $0.password = v } }),
                                icon: "lock", secure: !showPassword, trailingPadding: 36)
                ZenMiniButton(icon: showPassword ? "eye.slash" : "eye", size: 14,
                              help: showPassword ? L10n.t("webdav.passwordHideTip") : L10n.t("webdav.passwordShowTip")) { showPassword.toggle() }
                    .padding(.trailing, 6)
            }
            Text(L10n.t("webdav.passwordTip"))
                .font(.zen(10)).foregroundStyle(Zen.ink3)
        }

        if viewport >= 720 {
            GeometryReader { geo in
                let unit = (geo.size.width - 12 * 11) / 12
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        url.frame(width: unit * 8 + 12 * 7)
                        file.frame(width: unit * 4 + 12 * 3)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        user.frame(width: unit * 6 + 12 * 5)
                        pass.frame(width: unit * 6 + 12 * 5)
                    }
                }
            }
            .frame(height: 152)
        } else {
            VStack(alignment: .leading, spacing: 12) { url; file; user; pass }
        }
    }

    private func autoSyncRow(_ c: WebDavConfig) -> some View {
        let toggle = DataIOCheckbox(isOn: Binding(get: { config.autoSync ?? false }, set: { v in updateConfig { $0.autoSync = v } }),
                                    size: 16) {
            (Text("\(L10n.t("webdav.autoSyncLabel")) ").fontWeight(.bold) + Text(L10n.t("webdav.autoSyncBackupDesc")))
                .font(.zen(12)).foregroundStyle(Zen.ink)
                .multilineTextAlignment(.leading)
        }
        let status = HStack(spacing: 12) {
            (Text("\(L10n.t("webdav.lastSyncedLabel")) ") + Text(formatLastSync(c.lastSyncAt)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(Zen.ink2))
                .font(.zen(11)).foregroundStyle(Zen.ink3)
            if c.lastSyncStatus == .success {
                Text(L10n.t("webdav.statusUpToDate")).font(.zen(11, .medium)).foregroundStyle(Zen.positive)
            } else if c.lastSyncStatus == .error {
                Text(L10n.t("webdav.statusError")).font(.zen(11, .medium)).foregroundStyle(DataIOColors.negative)
            }
        }
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { toggle.fixedSize(); Spacer(minLength: 12); status }
            VStack(alignment: .leading, spacing: 8) { toggle; status }
        }
        .padding(12)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private var actionButtons: some View {
        let test = Button(action: testConnection) {
            HStack(spacing: 6) {
                if isTesting { DataIOSpinner(size: 14) } else { ZIcon("arrow.clockwise", size: 14) }
                Text(L10n.t("webdav.testBtn"))
            }
        }
        .buttonStyle(DataIORaisedButtonStyle(height: 36, padding: 14))
        .disabled(busy)

        let syncButtons = HStack(spacing: 8) {
            Button(action: push) {
                HStack(spacing: 6) {
                    if isPushing { DataIOSpinner(size: 14) } else { ZIcon("icloud.and.arrow.up", size: 14).foregroundStyle(Zen.indigo) }
                    Text(L10n.t("webdav.pushBtn"))
                }
            }
            .buttonStyle(DataIORaisedButtonStyle(height: 36, padding: 14))
            .help(L10n.t("webdav.pushTip"))
            .disabled(busy)

            Button { showConfirmPull = true } label: {
                HStack(spacing: 6) {
                    if isPulling { DataIOSpinner(size: 14) } else { ZIcon("icloud.and.arrow.down", size: 14) }
                    Text(L10n.t("webdav.pullBtn"))
                }
            }
            .buttonStyle(DataIOInkButtonStyle(height: 36, padding: 14))
            .help(L10n.t("webdav.pullTip"))
            .disabled(busy)
        }

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { test; Spacer(minLength: 8); syncButtons }
            VStack(alignment: .leading, spacing: 8) { test; syncButtons }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
    }

    private func pullDrawer(_ c: WebDavConfig) -> some View {
        let name = (c.remoteFileName ?? "").isEmpty ? WebDav.defaultRemoteFileName : c.remoteFileName!
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZIcon("exclamationmark.triangle", size: 16).foregroundStyle(DataIOColors.amber500).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("webdav.confirmPullTitle")).font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    (Text(L10n.t("webdav.confirmPullPrefix")) + dataIOCode(name)
                     + Text(L10n.t("webdav.confirmPullSuffix")))
                        .font(.zen(12)).foregroundStyle(Zen.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t("webdav.confirmPullSafety"))
                        .font(.zen(11)).foregroundStyle(Zen.ink3)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t("common.cancel")) { showConfirmPull = false }
                    .buttonStyle(DataIORaisedButtonStyle(background: Zen.surface))
                    .disabled(isPulling)
                Button(action: executePull) {
                    HStack(spacing: 6) {
                        if isPulling { DataIOSpinner(size: 14) }
                        Text(L10n.t("webdav.confirmPullBtn"))
                    }
                }
                .buttonStyle(DataIOAmberButtonStyle())
                .disabled(isPulling)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DataIOColors.amber500.opacity(0.3), lineWidth: 1))
    }

    private func formatLastSync(_ secs: Double?) -> String {
        guard let secs, secs > 0 else { return L10n.t("webdav.never") }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: secs))
    }

    private var credentialsComplete: Bool {
        let c = config
        return !c.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !c.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(c.password ?? "").isEmpty
    }

    private func testConnection() {
        guard credentialsComplete else {
            feedback = (.error, L10n.t("webdav.errEnterCreds"))
            return
        }
        isTesting = true
        feedback = nil
        let c = config
        Task {
            defer { isTesting = false }
            do {
                let msg = try await WebDav.testConnection(url: c.url, username: c.username, password: c.password ?? "")
                feedback = (.success, msg)
                updateConfig { $0.lastSyncStatus = .success; $0.lastSyncMessage = msg }
            } catch {
                let msg = DataIOMessages.text(error)
                feedback = (.error, msg)
                updateConfig { $0.lastSyncStatus = .error; $0.lastSyncMessage = msg }
            }
        }
    }

    private func push() {
        guard credentialsComplete else {
            feedback = (.error, L10n.t("webdav.errCompleteCreds"))
            return
        }
        isPushing = true
        feedback = nil
        let c = config
        Task {
            defer { isPushing = false }
            do {
                let res = try await store.webDavPush(c)
                feedback = (.success, res.message)
                updateConfig { $0.lastSyncAt = res.timestamp; $0.lastSyncStatus = .success; $0.lastSyncMessage = res.message }
            } catch {
                let msg = DataIOMessages.text(error)
                feedback = (.error, msg)
                updateConfig { $0.lastSyncStatus = .error; $0.lastSyncMessage = msg }
            }
        }
    }

    private func executePull() {
        guard credentialsComplete else {
            feedback = (.error, L10n.t("webdav.errCompleteCreds"))
            return
        }
        isPulling = true
        showConfirmPull = false
        feedback = nil
        let c = config
        Task {
            defer { isPulling = false }
            do {
                let res = try await store.webDavPull(c)
                feedback = (.success, "\(res.message) Reloading active ledger state…")
                // Keep this machine's WebDAV credentials and sync status in the reloaded ledger.
                updateConfig { $0.lastSyncAt = res.timestamp; $0.lastSyncStatus = .success; $0.lastSyncMessage = res.message }
            } catch {
                let msg = DataIOMessages.text(error)
                feedback = (.error, msg)
                updateConfig { $0.lastSyncStatus = .error; $0.lastSyncMessage = msg }
            }
        }
    }
}
