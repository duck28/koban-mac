import SwiftUI

/// Port of src/components/BackupsExportView.tsx — encrypted vault status, passphrase, backup
/// folder & snapshots, import / export cards, database location and WebDAV sync.
struct BackupsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var center = DataIOCenter.shared
    @State private var restorePassphrase = ""
    @State private var restoreKeyfileURL: URL?
    @State private var showRestoreCreds = false
    @State private var maxBackupsText = ""
    @State private var viewport: CGFloat = 1360

    var body: some View {
        let settings = store.state.settings
        let info = center.dbInfo

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("backups.title"))
                        .font(.zen(20)).tracking(-0.3).foregroundStyle(Zen.ink)
                    Text(L10n.t("backups.subtitle"))
                        .font(.zen(12)).foregroundStyle(Zen.ink2)
                }

                vaultSection(settings: settings, info: info)
                exportsSection
                DbLocationCard().id("dataio.dblocation")
                WebDavSyncCard().id("dataio.webdav")
            }
            .padding(24)
            .frame(maxWidth: 1152)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            let name = note.userInfo?["name"] as? String ?? ""
            if name == "dataio-scroll-bottom" || name.hasPrefix("webdav-") { proxy.scrollTo("dataio.webdav", anchor: .bottom) }
        }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 + (store.isSidebarOpen ? 256 : 0) }
        .task(id: "\(settings.backupDir)|\(settings.lastBackupAt ?? 0)") { center.refresh(store) }
        .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
            handleDebugAction(note.userInfo?["name"] as? String)
        }
    }

    // MARK: 1. AES-256-GCM vault & automatic backups

    @ViewBuilder
    private func vaultSection(settings: AppSettings, info: DbInfo?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                vaultTitle(info: info)
                Spacer(minLength: 12)
                vaultButtons(info: info)
            }

            passphraseRow(info: info)
            backupFolderRow(settings: settings)
            snapshotList(settings: settings)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func vaultTitle(info: DbInfo?) -> some View {
        HStack(spacing: 10) {
            ZIcon("checkmark.shield", size: 20).foregroundStyle(Zen.positive)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(L10n.t("backups.vaultTitle")).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    DataIOPill(text: L10n.tf("backups.encryptedRecordsBadge", ["cipher": info?.cipher ?? "AES-256-GCM", "count": info?.encryptedRecords ?? 0]),
                               foreground: Zen.positive, background: Zen.positive.opacity(0.15))
                }
                (Text("\(L10n.t("backups.primaryDbLabel")) ").foregroundColor(Zen.ink3)
                 + dataIOCode(info?.dbPath ?? L10n.t("backups.loading"), color: Zen.ink2)
                 + Text(" (\(DataIOStorage.formatBytes(info?.dbSize ?? 0)))").foregroundColor(Zen.ink3))
                    .font(.zen(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(info?.dbPath ?? "")
            }
        }
    }

    private func vaultButtons(info: DbInfo?) -> some View {
        HStack(spacing: 8) {
            if let path = info?.dbPath, !path.isEmpty {
                Button { DataIOPanels.reveal(path) } label: {
                    HStack(spacing: 6) { ZIcon("arrow.up.right.square", size: 14); Text(L10n.t("backups.locateDbBtn")) }
                }
                .buttonStyle(DataIORaisedButtonStyle(mutedText: true))
                .help(L10n.t("sidebar.revealBackupMac"))
            }
            Button {
                store.manualBackup()
                center.refresh(store)
            } label: {
                HStack(spacing: 6) { ZIcon("cylinder.split.1x2", size: 14); Text(L10n.t("backups.backupNowBtn")) }
            }
            .buttonStyle(DataIOInkButtonStyle(padding: 14))
        }
        .fixedSize()
    }

    private func passphraseRow(info: DbInfo?) -> some View {
        let status = AuthCenter.shared.vaultStatus
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZIcon("lock", size: 16).foregroundStyle(Zen.positive).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status?.formatVersion == 2
                         ? "Vault Format v2 · Argon2id + AES-256-GCM"
                         : "Legacy Vault v1 (Upgrade Recommended)")
                        .font(.zen(12, .medium)).foregroundStyle(Zen.ink)
                    HStack(spacing: 6) {
                        DataIOPill(text: "Master Password", foreground: Zen.positive, background: Zen.positive.opacity(0.12))
                        if status?.requiresKeyFile == true {
                            DataIOPill(text: "Key File (.key)", foreground: Zen.indigo, background: Zen.indigo.opacity(0.12))
                        }
                        if status?.deviceSlotEnrolled == true {
                            DataIOPill(text: TouchIDKeychain.methodName, foreground: Zen.positive, background: Zen.positive.opacity(0.12))
                        }
                        if status?.slots.contains(where: { $0.kind == "recovery" }) == true {
                            DataIOPill(text: "Recovery Key", foreground: Zen.warning, background: Zen.warning.opacity(0.12))
                        }
                    }
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)

            Button("Manage Credentials & Keys") {
                store.selectedTab = .settings
            }
            .buttonStyle(DataIORaisedButtonStyle())
        }
        .padding(14)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func backupFolderRow(settings: AppSettings) -> some View {
        let wide = viewport >= 768
        let folder = VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("backups.folderLabel")).font(.zen(12)).foregroundStyle(Zen.ink2)
            HStack(spacing: 8) {
                DataIOTextField(placeholder: L10n.t("backups.folderPlaceholder"),
                                text: Binding(get: { store.state.settings.backupDir },
                                              set: { v in store.applySettingsChange { $0.backupDir = v } }),
                                background: Zen.raised)
                Button {
                    if let url = DataIOPanels.folder(title: L10n.t("backups.folderLabel")) {
                        store.applySettingsChange {
                            $0.backupDir = url.path
                            $0.autoBackup = true
                        }
                    }
                } label: {
                    HStack(spacing: 6) { ZIcon("folder", size: 14); Text(L10n.t("settings.backups.browse")) }
                }
                .buttonStyle(DataIORaisedButtonStyle(height: 36))
                if !settings.backupDir.isEmpty {
                    Button { DataIOPanels.reveal(settings.backupDir) } label: { ZIcon("arrow.up.right.square", size: 14) }
                        .buttonStyle(DataIORaisedButtonStyle(height: 36, padding: 10, mutedText: true))
                        .help(L10n.t("sidebar.revealBackupMac"))
                }
            }
        }
        let keep = VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("backups.keepSnapshotsLabel")).font(.zen(12)).foregroundStyle(Zen.ink2)
            TextField("", text: Binding(
                get: { maxBackupsText.isEmpty ? String(settings.maxBackups > 0 ? settings.maxBackups : 20) : maxBackupsText },
                set: { v in
                    maxBackupsText = v
                    let n = Int(String(v.prefix { $0.isNumber || $0 == "-" })) ?? 0
                    store.applySettingsChange { $0.maxBackups = n != 0 ? n : 20 }
                }))
                .textFieldStyle(.plain)
                .font(.zen(12)).monospacedDigit()
                .foregroundStyle(Zen.ink)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
                .onSubmit { maxBackupsText = "" }
                .help("5 – 100")
        }
        let auto = DataIOCheckbox(isOn: Binding(get: { store.state.settings.autoBackup },
                                                set: { v in store.applySettingsChange { $0.autoBackup = v } })) {
            Text(L10n.t("settings.backups.autoBackup")).font(.zen(12)).foregroundStyle(Zen.ink)
        }
        .frame(height: 36)

        return VStack(spacing: 0) {
            Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1).padding(.bottom, 8)
            if wide {
                GeometryReader { geo in
                    let unit = (geo.size.width - 16 * 11) / 12
                    HStack(alignment: .bottom, spacing: 16) {
                        folder.frame(width: unit * 7 + 16 * 6)
                        keep.frame(width: unit * 3 + 16 * 2)
                        auto.frame(width: unit * 2 + 16, alignment: .leading)
                    }
                }
                .frame(height: 58)
            } else {
                VStack(alignment: .leading, spacing: 16) { folder; keep; auto }
            }
        }
    }

    private func snapshotList(settings: AppSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1).padding(.bottom, 4)
            HStack {
                Text(L10n.tf("backups.snapshotsListTitle", ["count": center.backups.count]).uppercased())
                    .font(.zen(11, .semibold)).tracking(0.6).foregroundStyle(Zen.ink3)
                Spacer()
                HStack(spacing: 10) {
                    Button { showRestoreCreds.toggle() } label: {
                        Text(showRestoreCreds ? "Hide backup unlock options" : "Foreign / older backup credentials…")
                            .font(.zen(11)).foregroundStyle(Zen.ink2)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let url = DataIOPanels.open(extensions: ["db", "sqlite", "json"]) {
                            store.restoreBackup(
                                at: url.path,
                                passphrase: restorePassphrase.isEmpty ? nil : restorePassphrase,
                                keyfileURL: restoreKeyfileURL
                            )
                            center.refresh(store)
                        }
                    } label: {
                        HStack(spacing: 4) { ZIcon("arrow.counterclockwise", size: 12); Text(L10n.t("backups.restoreFromFile")) }
                            .font(.zen(12)).foregroundStyle(Zen.indigo)
                    }
                    .buttonStyle(.plain)
                    ZenMiniButton(icon: "arrow.clockwise", size: 14) { center.refresh(store) }
                }
            }

            if showRestoreCreds {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Leave empty when restoring backups encrypted with this vault's active key. Enter credentials only for backups using another password or Key File.")
                        .font(.zen(11)).foregroundStyle(Zen.ink2)
                    DataIOTextField(placeholder: "Backup passphrase (optional)", text: $restorePassphrase, secure: true,
                                    height: 30, background: Zen.surface, trailingPadding: 10)
                    KeyFileSelectorView(keyfileURL: $restoreKeyfileURL, allowGenerate: false, compact: true)
                }
                .padding(10)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }

            if center.backups.isEmpty {
                Text(settings.backupDirIsForeign
                     ? L10n.t("sidebar.foreignBackupMac")
                     : settings.backupDir.isEmpty
                     ? L10n.t("backups.emptyNoDir")
                     : L10n.t("backups.emptyDir"))
                    .font(.zen(12)).foregroundStyle(Zen.ink3)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(center.backups.enumerated()), id: \.element.id) { idx, b in
                            if idx > 0 { Rectangle().fill(Zen.line.opacity(0.5)).frame(height: 1) }
                            BackupRow(entry: b) {
                                store.restoreBackup(
                                    at: b.url.path,
                                    passphrase: restorePassphrase.isEmpty ? nil : restorePassphrase,
                                    keyfileURL: restoreKeyfileURL
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: 192)
                .fixedSize(horizontal: false, vertical: center.backups.count <= 4)
                .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }
        }
    }

    // MARK: 2. Import Data & external exports

    private struct ExportCard: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let button: String
        var emphasized = false
        let action: () -> Void
    }

    private var exportsSection: some View {
        let cards: [ExportCard] = [
            ExportCard(id: "import", icon: "square.and.arrow.up", tint: Zen.accent, title: L10n.t("backups.importCardTitle"),
                       detail: L10n.t("backups.importCardDesc"),
                       button: L10n.t("backups.importCardBtn"), emphasized: true) { store.openImport() },
            ExportCard(id: "xlsx", icon: "tablecells", tint: Zen.positive, title: L10n.t("backups.excelCardTitle"),
                       detail: L10n.t("backups.excelCardDesc"),
                       button: L10n.t("backups.excelCardBtn")) { store.exportExcel() },
            ExportCard(id: "budgetcsv", icon: "arrow.down.doc", tint: Zen.indigo, title: L10n.t("backups.budgetCsvCardTitle"),
                       detail: L10n.t("backups.budgetCsvCardDesc"),
                       button: L10n.t("backups.budgetCsvCardBtn")) { store.exportBudgetCSV() },
            ExportCard(id: "txcsv", icon: "arrow.down.doc", tint: Zen.accent, title: L10n.t("backups.txCsvCardTitle"),
                       detail: L10n.t("backups.txCsvCardDesc"),
                       button: L10n.t("backups.txCsvCardBtn")) { store.exportTransactionsCSV() },
        ]
        let columns = viewport >= 1024 ? 3 : (viewport >= 640 ? 2 : 1)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("backups.exportsSectionTitle")).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                switch columns {
                case 3:
                    GridRow { cell(cards[0]); cell(cards[1]); cell(cards[2]) }
                    GridRow { cell(cards[3]); sqliteCard.gridCellColumns(2) }
                case 2:
                    GridRow { cell(cards[0]); cell(cards[1]) }
                    GridRow { cell(cards[2]); cell(cards[3]) }
                    GridRow { sqliteCard.gridCellColumns(2) }
                default:
                    ForEach(cards) { c in GridRow { cell(c) } }
                    GridRow { sqliteCard }
                }
            }
        }
    }

    private func cell(_ c: ExportCard) -> some View {
        exportCard(c).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportCard(_ c: ExportCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ZIcon(c.icon, size: 16).foregroundStyle(c.tint)
                    Text(c.title).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                }
                Text(c.detail).font(.zen(12)).foregroundStyle(Zen.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if c.emphasized {
                Button(action: c.action) { Text(c.button).frame(maxWidth: .infinity) }
                    .buttonStyle(DataIOInkButtonStyle())
            } else {
                Button(action: c.action) { Text(c.button).frame(maxWidth: .infinity) }
                    .buttonStyle(DataIORaisedButtonStyle(weight: .medium))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(c.emphasized ? Zen.ink.opacity(0.8) : Zen.line,
                                                                  lineWidth: c.emphasized ? 2 : 1))
    }

    private var sqliteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ZIcon("externaldrive", size: 16).foregroundStyle(Zen.ink2)
                    Text(L10n.t("backups.sqliteCardTitle")).font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                }
                (Text(L10n.t("backups.sqliteCardDescPrefix"))
                 + dataIOCode("koban.db")
                 + Text(L10n.t("backups.sqliteCardDescSuffix")))
                    .font(.zen(12)).foregroundStyle(Zen.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(L10n.t("backups.sqliteCardBtn")) {
                let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
                if let url = DataIOPanels.save(defaultName: "koban-encrypted-\(stamp).db", extensions: ["db"]) {
                    store.exportDatabaseCopy(to: url)
                }
            }
            .buttonStyle(DataIORaisedButtonStyle(padding: 16, weight: .medium))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: Snapshot hooks (debug builds)

    private func handleDebugAction(_ name: String?) {
        guard let name else { return }
        switch name {
        case "dataio-import":
            store.openImport()
        case "dataio-import-budget", "dataio-import-transactions":
            let state = store.state
            let ws = state.settings.activeWorkspace
            let mk = state.activeMonthKey
            let isBudget = name == "dataio-import-budget"
            let data = isBudget ? LedgerExports.monthlyBudgetCSV(state, monthKey: mk, workspace: ws)
                                : LedgerExports.transactionsCSV(state, workspace: ws)
            let fileName = isBudget ? LedgerExports.budgetCSVFileName(workspace: ws, monthKey: mk)
                                    : LedgerExports.transactionsCSVFileName(workspace: ws, year: state.settings.activeYear)
            if let wb = try? SpreadsheetReader.read(data: data, fileName: fileName) {
                // Re-import into the other workspace so the preview shows new categories as well.
                let target: LedgerMode = isBudget ? (store.importDefaultMode == .home ? .freelancer : .home) : store.importDefaultMode
                store.presentImportModal(initialPreview: store.buildImportPreview(
                    kind: isBudget ? .budgetSheet : .transactions, workbook: wb, fileName: fileName, targetMode: target))
            }
        case "dataio-import-backup":
            store.restoreBackup(at: store.databaseURL.path)
        default: break
        }
    }
}

/// One row of the snapshot list.
private struct BackupRow: View {
    let entry: BackupEntry
    let onRestore: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1).truncationMode(.middle)
                    Text(entry.formatVersion == 2 ? "v2 Argon2id" : "v1 Legacy")
                        .font(.zen(10, .medium))
                        .foregroundStyle(entry.formatVersion == 2 ? Zen.positive : Zen.warning)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((entry.formatVersion == 2 ? Zen.positive : Zen.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                Text("\(DataIOStorage.formatBytes(entry.size)) · \(DataIOStorage.formatTime(entry.modified)) · AES-256-GCM")
                    .font(.zen(10)).monospacedDigit().foregroundStyle(Zen.ink3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(L10n.t("backups.revealBtn")) { DataIOPanels.reveal(entry.url.path) }
                    .buttonStyle(DataIORaisedButtonStyle(height: 22, padding: 8, fontSize: 11, mutedText: true,
                                                         background: Zen.surface, radius: 4))
                Button(L10n.t("backups.restoreBtn"), action: onRestore)
                    .buttonStyle(DataIOInkButtonStyle(height: 22, padding: 8, fontSize: 11, weight: .regular, radius: 4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Zen.raised.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
    }
}
