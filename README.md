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
    │   ├── Models/             Codable mirror of src/types/index.ts + LedgerMerge.swift
    │   ├── Calculations/       port of src/utils/calculations.ts
    │   ├── Vault/              SQLite + Vault v2 (Argon2id.swift, VaultCrypto.swift, KobanVault.swift, backups)
    │   └── Support/            de-CH number / currency formatting
    └── Tests/KobanCoreTests/   shared vectors (docs/vault-v2-test-vectors.json), vault v2/v1 round-trips, merge & calculation parity
```

The app target compiles `KobanKit/Sources/KobanCore` directly into the same module, so core types don't need `public`. The package exists so the core can be built and tested on its own with `swift test`.

## Compatibility with the Windows build

| | Windows (Tauri) | macOS (Swift) |
|---|---|---|
| Default DB | `%LOCALAPPDATA%\Koban\koban.db` | `~/Library/Application Support/Koban/koban.db` |
| Custom location | `db_location.txt` pointer | same mechanism |
| Encryption | Vault v2: 256-bit DEK, Argon2id (64 MiB, t=3, p=4) + optional Composite Key File + AES-256-GCM AAD | byte-identical (`Argon2id.swift` + `VaultCrypto.swift`), verified against `docs/vault-v2-test-vectors.json` |
| Ledger JSON | `LedgerState` in `src/types/index.ts` | `LedgerModels.swift` (same keys) |
| Backups | `koban-latest.db` + daily/timestamped snapshots | same file names and pruning |
| Cloud & WebDAV Sync | `DELETE` journal + `FULL` sync, atomic write-swap, SHA-256 drift check, DPAPI WebDAV creds, deterministic record merge | byte-compatible sync, Touch ID Keychain DEK + WebDAV Keychain creds, deterministic `LedgerMerge.merge` |

**Keep these in sync.** If you change the vault format or add fields to `LedgerState` on one side, update the other. The macOS build drops JSON fields it doesn't know about when it re-saves a vault.

## Porting roadmap

| Area | Windows source | macOS (`Koban/Features/…`) |
|---|---|---|
| Models, calculations, templates/catalogs | `types/`, `utils/calculations.ts`, `utils/ledgerMerge.ts`, `data/templates.ts` | ✅ (`KobanCore`; catalogs generated from templates.ts) |
| Vault v2 (DEK, Argon2id, Key File, Recovery Key, v1 migration), DB location, backups | `src-tauri/src/vault_crypto.rs`, `src-tauri/src/lib.rs` | ✅ (v1→v2 migration & legacy v1 backup upgrade included) |
| Shell: top bar, sidebar, theme/palettes, density, high contrast | `TopBar.tsx`, `Sidebar.tsx`, `App.css` | ✅ |
| Monthly worksheet | `MonthlyWorksheetView.tsx` | ✅ |
| Transactions, Recurring | `TransactionsView.tsx`, `RecurringView.tsx` | ✅ `Transactions/` |
| Accounts & net worth, Savings goals | `AccountsNetWorthView.tsx`, `SavingsGoalsView.tsx` | ✅ `Accounts/` |
| Yearly planner | `YearlyBudgetPlannerView.tsx` | ✅ `YearlyPlanner/` |
| Reports, Categories studio | `ReportsChartsView.tsx`, `CategoriesStudioView.tsx` | ✅ `Reports/` |
| Backups & exports, Import, XLSX/CSV, DB location, WebDAV | `BackupsExportView.tsx`, `ImportDataModal.tsx`, `utils/exportImport.ts`, `useWebDavSync.ts`, `lib.rs` | ✅ `DataIO/` (own XLSX reader/writer; WebDAV Keychain credentials & record-level merge; legacy binary `.xls` not readable) |
| Settings, login/lock, languages | `SettingsView.tsx`, `AuthLockScreen.tsx`, `utils/auth.ts`, `i18n/` | ✅ `Settings/` (device-local Touch ID Keychain DEK replaces Windows Hello TPM + DPAPI; Key File & Recovery Key work across both OSes) |
| Setup wizard | `OnboardingModal.tsx` | ✅ `Onboarding/` |

## Verification on macOS

`swift test` (`KobanKit`) and the universal `Koban.app` build (`scripts/build-app.sh`) run automatically on `macos-15` in GitHub Actions (`CI` and `Release`). When running interactively on a Mac:

1. `make test` (or `cd KobanKit && swift test`): verifies RFC 9106 Argon2id, `docs/vault-v2-test-vectors.json` cross-platform parity with Rust, Composite Key Files, Recovery Key, v1→v2 migration, external modification checks, and `LedgerMerge`.
2. `make open`, then build and run the app.
3. Open a Vault v2 `koban.db` created on Windows (with Master Password, optional `.key` file, or Recovery Key) via **Open Existing koban.db…** / WebDAV / cloud folder sync and confirm cross-platform unlock and merge work cleanly.

## Releases

Pushing a version tag builds a universal Koban.app (Apple silicon + Intel) on GitHub Actions and publishes a `.dmg`, a `.zip` and checksums as a GitHub Release ([`.github/workflows/release.yml`](.github/workflows/release.yml)):

```bash
git tag v1.2.0
git push origin v1.2.0
```

The app is ad-hoc signed, not notarized: on first launch, open System Settings → Privacy & Security → "Open Anyway". Signing with a Developer ID and notarization need an Apple Developer account.

The shared vault crypto specification, test vectors, and WebDAV sync format are in [docs/VAULT-V2-SPEC.md](docs/VAULT-V2-SPEC.md), [docs/vault-v2-test-vectors.json](docs/vault-v2-test-vectors.json), and [docs/WEBDAV-SPEC.md](docs/WEBDAV-SPEC.md).

## Security

Koban uses **Vault Format v2** (KeePassXC-style random 256-bit DEK, Argon2id 64 MiB KDF, required Master Password, optional Composite Key File `.key`, 160-bit Crockford Base32 Recovery Key, device-local Touch ID Keychain quick unlock, Keychain-protected WebDAV passwords, and sync-safe `DELETE`-journal SQLite + record-level merge). See [SECURITY.md](SECURITY.md) for the full threat model (including the ad-hoc Touch ID login-keychain caveat and legacy v1 backup guidance) and how to report vulnerabilities privately.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
