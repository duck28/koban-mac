import SwiftUI

/// Port of src/components/BackupsExportView.tsx — encrypted vault status, passphrase, backup
/// folder & snapshots, import / export cards, database location and WebDAV sync.
struct BackupsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var center = DataIOCenter.shared
    @State private var newPassphrase = ""
    @State private var maxBackupsText = ""
    @State private var viewport: CGFloat = 1360

    var body: some View {
        let settings = store.state.settings
        let info = center.dbInfo

        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encrypted Database, Backups & Data Import / Export")
                        .font(.zen(20)).tracking(-0.3).foregroundStyle(Zen.ink)
                    Text("All database records and automatic backups are encrypted at rest with authenticated AES-256-GCM.")
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
                    Text("AES-256-GCM Encrypted SQLite Vault").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                    DataIOPill(text: "\(info?.cipher ?? "AES-256-GCM") · \(info?.encryptedRecords ?? 0) Encrypted Records",
                               foreground: Zen.positive, background: Zen.positive.opacity(0.15))
                }
                (Text("Primary DB: ").foregroundColor(Zen.ink3)
                 + dataIOCode(info?.dbPath ?? "Loading…", color: Zen.ink2)
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
                    HStack(spacing: 6) { ZIcon("arrow.up.right.square", size: 14); Text("Locate Encrypted DB") }
                }
                .buttonStyle(DataIORaisedButtonStyle(mutedText: true))
                .help("Reveal the encrypted database in Finder")
            }
            Button {
                store.manualBackup()
                center.refresh(store)
            } label: {
                HStack(spacing: 6) { ZIcon("cylinder.split.1x2", size: 14); Text("Backup Now") }
            }
            .buttonStyle(DataIOInkButtonStyle(padding: 14))
        }
        .fixedSize()
    }

    private func passphraseRow(info: DbInfo?) -> some View {
        let custom = info?.hasCustomPassphrase ?? store.hasCustomPassphrase
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZIcon("lock", size: 16).foregroundStyle(Zen.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    (Text("Vault Encryption Key Mode: ").foregroundColor(Zen.ink)
                     + Text(custom ? "Custom Passphrase Active (salted SHA-256 KDF + AES-256-GCM)" : "Built-in Default Key (AES-256-GCM)")
                        .foregroundColor(Zen.positive))
                        .font(.zen(12, .medium))
                    Text(custom
                         ? "The ledger is stored as authenticated AES-256-GCM ciphertext, keyed by your passphrase."
                         : "The default key is built into the app: anyone with a copy of koban.db or a backup can decrypt it. Set a custom passphrase to protect your data.")
                        .font(.zen(11)).foregroundStyle(Zen.ink3)
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                DataIOTextField(placeholder: "Set or change custom passphrase (leave empty for default)…",
                                text: $newPassphrase, secure: true, height: 32, background: Zen.surface, trailingPadding: 10)
                    .frame(width: 256)
                    .onSubmit(applyPassphrase)
                Button(newPassphrase.trimmingCharacters(in: .whitespaces).isEmpty ? "Use Default Key" : "Set Passphrase",
                       action: applyPassphrase)
                    .buttonStyle(DataIORaisedButtonStyle())
            }
        }
        .padding(14)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func applyPassphrase() {
        let trimmed = newPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        store.applyVaultPassphrase(trimmed.isEmpty ? nil : trimmed)
        newPassphrase = ""
        center.refresh(store)
    }

    private func backupFolderRow(settings: AppSettings) -> some View {
        let wide = viewport >= 768
        let folder = VStack(alignment: .leading, spacing: 4) {
            Text("User-Chosen Automatic Backup Folder Path").font(.zen(12)).foregroundStyle(Zen.ink2)
            HStack(spacing: 8) {
                DataIOTextField(placeholder: "Choose a folder path for automatic encrypted SQLite (.db) backups…",
                                text: Binding(get: { store.state.settings.backupDir },
                                              set: { v in store.applySettingsChange { $0.backupDir = v } }),
                                background: Zen.raised)
                Button {
                    if let url = DataIOPanels.folder(title: "Select Automatic Backup Folder") {
                        store.applySettingsChange {
                            $0.backupDir = url.path
                            $0.autoBackup = true
                        }
                    }
                } label: {
                    HStack(spacing: 6) { ZIcon("folder", size: 14); Text("Browse…") }
                }
                .buttonStyle(DataIORaisedButtonStyle(height: 36))
                if !settings.backupDir.isEmpty {
                    Button { DataIOPanels.reveal(settings.backupDir) } label: { ZIcon("arrow.up.right.square", size: 14) }
                        .buttonStyle(DataIORaisedButtonStyle(height: 36, padding: 10, mutedText: true))
                        .help("Open Backup Folder in Finder")
                }
            }
        }
        let keep = VStack(alignment: .leading, spacing: 4) {
            Text("Rolling Snapshots to Keep").font(.zen(12)).foregroundStyle(Zen.ink2)
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
            Text("Auto-Backup").font(.zen(12)).foregroundStyle(Zen.ink)
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
                Text("ENCRYPTED SNAPSHOTS IN BACKUP FOLDER (\(center.backups.count))")
                    .font(.zen(11, .semibold)).tracking(0.6).foregroundStyle(Zen.ink3)
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        if let url = DataIOPanels.open(extensions: ["db", "sqlite", "json"]) {
                            store.restoreBackup(at: url.path)
                            center.refresh(store)
                        }
                    } label: {
                        HStack(spacing: 4) { ZIcon("arrow.counterclockwise", size: 12); Text("Restore from file…") }
                            .font(.zen(12)).foregroundStyle(Zen.indigo)
                    }
                    .buttonStyle(.plain)
                    ZenMiniButton(icon: "arrow.clockwise", size: 14, help: "Refresh backup list") { center.refresh(store) }
                }
            }

            if center.backups.isEmpty {
                Text(settings.backupDirIsForeign
                     ? "The backup folder is a path from another device (e.g. Windows). Choose a folder on this Mac above."
                     : settings.backupDir.isEmpty
                     ? "Select a backup folder above to enable automatic encrypted SQLite backups."
                     : "No backup files in this folder yet. Click \"Backup Now\" to create your first encrypted snapshot.")
                    .font(.zen(12)).foregroundStyle(Zen.ink3)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(center.backups.enumerated()), id: \.element.id) { idx, b in
                            if idx > 0 { Rectangle().fill(Zen.line.opacity(0.5)).frame(height: 1) }
                            BackupRow(entry: b) { store.restoreBackup(at: b.url.path) }
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
            ExportCard(id: "import", icon: "square.and.arrow.up", tint: Zen.accent, title: "Import Data (.xlsx, .csv, .db)",
                       detail: "Import a Monthly Budget sheet, bank/transaction CSV or Excel file, or restore an encrypted Koban SQLite database backup.",
                       button: "Open Import Data Wizard…", emphasized: true) { store.openImport() },
            ExportCard(id: "xlsx", icon: "tablecells", tint: Zen.positive, title: "Full Excel Workbook (.xlsx)",
                       detail: "Multi-sheet Excel file containing the 2-column Monthly Budget sheet, Category Breakdown, 12-Month Overview, and Transactions.",
                       button: "Export Excel Workbook (.xlsx)…") { store.exportExcel() },
            ExportCard(id: "budgetcsv", icon: "arrow.down.doc", tint: Zen.indigo, title: "Monthly Budget CSV (.csv)",
                       detail: "Exports the side-by-side 2-column Monthly Budget layout with UTF-8 BOM for direct opening in Microsoft Excel or Google Sheets.",
                       button: "Export Monthly Budget (.csv)…") { store.exportBudgetCSV() },
            ExportCard(id: "txcsv", icon: "arrow.down.doc", tint: Zen.accent, title: "Transactions & Tax CSV (.csv)",
                       detail: "Complete transaction log with Freelancer client names, invoice numbers, VAT rates, and tax-deductible expense amounts.",
                       button: "Export Transactions (.csv)…") { store.exportTransactionsCSV() },
        ]
        let columns = viewport >= 1024 ? 3 : (viewport >= 640 ? 2 : 1)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Import Data & External Excel (.xlsx) / CSV (.csv) Exports").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
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
                    Text("Export Encrypted SQLite Database (.db)").font(.zen(14, .medium)).foregroundStyle(Zen.ink)
                }
                (Text("Save a standalone copy of your AES-256-GCM encrypted SQLite database (")
                 + dataIOCode("koban.db")
                 + Text(") to any external drive or folder."))
                    .font(.zen(12)).foregroundStyle(Zen.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Export Encrypted SQLite (.db)…") {
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
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1).truncationMode(.middle)
                Text("\(DataIOStorage.formatBytes(entry.size)) · \(DataIOStorage.formatTime(entry.modified)) · AES-256-GCM")
                    .font(.zen(10)).monospacedDigit().foregroundStyle(Zen.ink3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Reveal") { DataIOPanels.reveal(entry.url.path) }
                    .buttonStyle(DataIORaisedButtonStyle(height: 22, padding: 8, fontSize: 11, mutedText: true,
                                                         background: Zen.surface, radius: 4))
                Button("Restore", action: onRestore)
                    .buttonStyle(DataIOInkButtonStyle(height: 22, padding: 8, fontSize: 11, weight: .regular, radius: 4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Zen.raised.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
    }
}
