# Koban (小判) for macOS

Native macOS version of Koban, written in **Swift + SwiftUI** (macOS 14+).
It opens the **same encrypted `koban.db`** as the Windows (Tauri) build ([koban-windows](https://github.com/duck28/koban-windows)): identical SQLite schema, KDF and AES-256-GCM format. You can copy a vault between machines or keep it in a synced folder.

> **Status: feature-complete port.** Every Windows view, the setup wizard, import/export (.xlsx/.csv/.db), backups, DB location, WebDAV sync, login/lock (Touch ID instead of Windows Hello) and all 30 languages are ported. See [Porting status](#porting-roadmap) for the remaining differences.

## Requirements (on a Mac)

- **Command Line Tools only** (`xcode-select --install`): `make app` / `make install` build Koban.app with plain `swiftc` (`scripts/build-app.sh`).
- For the Xcode project and unit tests: Xcode 16 or newer (Swift 5.10+) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `make test` needs XCTest, which ships with Xcode, not the Command Line Tools.

## Getting started

```bash
cd koban-mac
make app         # release Koban.app -> build/app (no Xcode needed)
make install     # build and copy to /Applications
make app-debug   # debug build; enables the KOBAN_SNAPSHOT developer hooks
make test        # swift test: core unit tests, no Xcode project needed
make open        # generates Koban.xcodeproj from project.yml and opens it in Xcode
```

In Xcode, select the **Koban** scheme and press ⌘R. `make build` runs an unsigned debug build from the command line.

`Koban.xcodeproj`, `Info.plist` and `Koban.entitlements` are generated from `project.yml`. Edit `project.yml`, never the generated project.

## Layout

```
koban-mac/
├── project.yml                 XcodeGen spec → Koban.xcodeproj (app target, signing, Info.plist)
├── Makefile                    project / open / build / test
├── Koban/                      SwiftUI app (macOS only)
│   ├── App/                    KobanApp (scenes, menu commands), LedgerStore (state + persistence)
│   ├── Theme/                  Zen "Paper & Ink" color tokens, UI labels
│   ├── Views/                  Root/sidebar/toolbar, Monthly worksheet, unlock & welcome
│   └── Resources/AppIcon.icns  copied from src-tauri/icons
└── KobanKit/                   Swift package with the platform-independent core
    ├── Sources/KobanCore/
    │   ├── Models/             Codable mirror of src/types/index.ts
    │   ├── Calculations/       port of src/utils/calculations.ts
    │   ├── Vault/              SQLite + AES-256-GCM vault, paths, backups (port of src-tauri/src/lib.rs)
    │   └── Support/            de-CH number / currency formatting
    └── Tests/KobanCoreTests/   crypto vectors from the Rust code, vault round-trips, calculation parity
```

The app target compiles `KobanKit/Sources/KobanCore` directly into the same module, so core types don't need `public`. The package exists so the core can be built and tested on its own with `swift test`.

## Compatibility with the Windows build

| | Windows (Tauri) | macOS (Swift) |
|---|---|---|
| Default DB | `%LOCALAPPDATA%\Koban\koban.db` | `~/Library/Application Support/Koban/koban.db` |
| Custom location | `db_location.txt` pointer | same mechanism |
| Encryption | AES-256-GCM, salted SHA-256 ×10 000 KDF | byte-identical (CryptoKit), checked against vectors from the Rust code |
| Ledger JSON | `LedgerState` in `src/types/index.ts` | `LedgerModels.swift` (same keys) |
| Backups | `koban-latest.db` + daily/timestamped snapshots | same file names and pruning |

**Keep these in sync.** If you change the vault format or add fields to `LedgerState` on one side, update the other. The macOS build drops JSON fields it doesn't know about when it re-saves a vault.

## Porting roadmap

| Area | Windows source | macOS (`Koban/Features/…`) |
|---|---|---|
| Models, calculations, templates/catalogs | `types/`, `utils/calculations.ts`, `data/templates.ts` | ✅ (`KobanCore`; catalogs generated from templates.ts) |
| Encrypted vault, passphrase, DB location, backups | `src-tauri/src/lib.rs` | ✅ (legacy plaintext-table migration not ported) |
| Shell: top bar, sidebar, theme/palettes, density, high contrast | `TopBar.tsx`, `Sidebar.tsx`, `App.css` | ✅ |
| Monthly worksheet | `MonthlyWorksheetView.tsx` | ✅ |
| Transactions, Recurring | `TransactionsView.tsx`, `RecurringView.tsx` | ✅ `Transactions/` |
| Accounts & net worth, Savings goals | `AccountsNetWorthView.tsx`, `SavingsGoalsView.tsx` | ✅ `Accounts/` |
| Yearly planner | `YearlyBudgetPlannerView.tsx` | ✅ `YearlyPlanner/` |
| Reports, Categories studio | `ReportsChartsView.tsx`, `CategoriesStudioView.tsx` | ✅ `Reports/` |
| Backups & exports, Import, XLSX/CSV, DB location, WebDAV | `BackupsExportView.tsx`, `ImportDataModal.tsx`, `utils/exportImport.ts`, `lib.rs` | ✅ `DataIO/` (own XLSX reader/writer; legacy binary `.xls` not readable) |
| Settings, login/lock, languages | `SettingsView.tsx`, `AuthLockScreen.tsx`, `utils/auth.ts`, `i18n/` | ✅ `Settings/` (Touch ID + Keychain replace Windows Hello; WebAuthn passkeys from Windows are kept but unusable on macOS) |
| Setup wizard | `OnboardingModal.tsx` | ✅ `Onboarding/` |

## Not verified yet

This scaffold was written on Windows, where there is no Swift toolchain, so it has **not been compiled or run yet**. On the first build on a Mac:

1. `make test`: the crypto tests confirm the Mac and Windows builds read each other's vaults.
2. `make open`, then run. Fix any compiler errors (SDK/API drift).
3. Open a `koban.db` copied from the Windows app via **Open Existing koban.db…** and check that the worksheet totals match.

## Releases

Pushing a version tag builds a universal Koban.app (Apple silicon + Intel) on GitHub Actions and publishes a `.dmg`, a `.zip` and checksums as a GitHub Release ([`.github/workflows/release.yml`](.github/workflows/release.yml)):

```bash
git tag v1.2.0
git push origin v1.2.0
```

The app is ad-hoc signed, not notarized: on first launch, open System Settings → Privacy & Security → "Open Anyway". Signing with a Developer ID and notarization need an Apple Developer account.

The WebDAV sync format shared with the Windows build is specified in [docs/WEBDAV-SPEC.md](docs/WEBDAV-SPEC.md).
