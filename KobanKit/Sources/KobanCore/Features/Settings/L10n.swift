import Foundation
import Observation

/// Port of src/i18n/index.tsx. The dictionaries are generated from src/i18n/locales/*.ts into
/// L10nTables.swift (tools/gen-l10n.mjs) — do not hand-edit them.
///
///     Text(L10n.t("nav.monthly"))
///
/// `L10n.t` reads the observable `L10n.state.language`, so SwiftUI bodies that call it re-render
/// when the language changes. The language follows `AppSettings.language` (call
/// `L10n.setLanguage(_:)` after a ledger loads / the setting changes) and falls back to English
/// per key, exactly like `dict[key] ?? en[key]` on Windows.
enum L10n {
    struct Language: Hashable, Sendable, Identifiable {
        let code: String
        /// Name written in the language itself.
        let native: String
        /// English name.
        let english: String
        /// BCP-47 locale used for date formatting.
        let intl: String
        /// "Default", "Europe" or "Asia".
        let group: String
        var id: String { code }
    }

    @Observable
    final class State: @unchecked Sendable {
        fileprivate(set) var language: String
        init(language: String) { self.language = language }
    }

    /// LANGUAGES in index.tsx, same order.
    static let languages: [Language] = L10nTables.languages.map {
        Language(code: $0.code, native: $0.native, english: $0.english, intl: $0.intl, group: $0.group)
    }

    static let groups = ["Default", "Europe", "Asia"]

    static let state = State(language: detectInitialLanguage())

    /// localStorage key on Windows; UserDefaults key here (used before a ledger is loaded).
    static let storageKey = "koban_language_v1"

    static var language: String { state.language }

    static var current: Language {
        languages.first { $0.code == state.language } ?? languages[0]
    }

    /// Locale for date formatting (intlLocale on Windows).
    static var intlLocale: Locale { Locale(identifier: current.intl) }

    static func isSupported(_ code: String) -> Bool { L10nTables.tables[code] != nil }

    /// setLanguage in I18nProvider: ignores unknown codes, remembers the choice for the next launch.
    static func setLanguage(_ code: String?) {
        guard let code, isSupported(code) else { return }
        if state.language != code { state.language = code }
        // Dev runs against a scratch vault (KOBAN_DB_PATH) must not change the real app's preference.
        guard KobanPaths.developerDatabaseOverride == nil else { return }
        UserDefaults.standard.set(code, forKey: storageKey)
    }

    /// Translated string for `key`, falling back to English, then to the key itself.
    static func t(_ key: String) -> String {
        let lang = state.language
        let raw = L10nTables.tables[lang]?[key] ?? L10nTables.lang_en[key] ?? key
        return adaptForMac(raw, skipHelloSwap: key.hasSuffix("Mac"))
    }

    /// Same lookup for an explicit language (tests, previews).
    static func t(_ key: String, language: String) -> String {
        let raw = L10nTables.tables[language]?[key] ?? L10nTables.lang_en[key] ?? key
        return adaptForMac(raw, skipHelloSwap: key.hasSuffix("Mac"))
    }

    /// Formatted string replacing `{placeholder}` tokens.
    static func tf(_ key: String, _ args: [String: any CustomStringConvertible]) -> String {
        var out = t(key)
        for (k, v) in args {
            out = out.replacingOccurrences(of: "{\(k)}", with: "\(v)")
        }
        return out
    }

    private static func buildLowerEnIndex(prefix: String) -> [String: String] {
        var map: [String: String] = [:]
        for (key, val) in L10nTables.lang_en where key.hasPrefix(prefix) {
            let lower = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !lower.isEmpty, map[lower] == nil {
                map[lower] = key
            }
        }
        return map
    }

    private static let groupByLowerEn = buildLowerEnIndex(prefix: "catGroup.")
    private static let itemByLowerEn = buildLowerEnIndex(prefix: "catItem.")
    private static let accByLowerEn = buildLowerEnIndex(prefix: "defaultAcc.")
    private static let goalByLowerEn = buildLowerEnIndex(prefix: "defaultGoal.")

    private static func resolveCatalogLabel(prefix: String, byLowerEn: [String: String], name: String, id: String?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        if let id, !id.isEmpty {
            let byIdKey = prefix + id
            if let enDefault = L10nTables.lang_en[byIdKey] {
                return trimmed.lowercased() == enDefault.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    ? t(byIdKey)
                    : name
            }
        }
        if let key = byLowerEn[trimmed.lowercased()] {
            return t(key)
        }
        return name
    }

    static func groupName(_ name: String, id: String? = nil) -> String {
        resolveCatalogLabel(prefix: "catGroup.", byLowerEn: groupByLowerEn, name: name, id: id)
    }

    static func groupName(_ g: CategoryGroup) -> String {
        groupName(g.name, id: g.id)
    }

    static func groupName(_ g: CatalogGroupDef) -> String {
        groupName(g.name, id: g.id)
    }

    static func categoryName(_ name: String, id: String? = nil) -> String {
        resolveCatalogLabel(prefix: "catItem.", byLowerEn: itemByLowerEn, name: name, id: id)
    }

    static func categoryName(_ c: CategoryItem) -> String {
        categoryName(c.name, id: c.id)
    }

    static func categoryName(_ opt: CatalogCategoryOption) -> String {
        categoryName(opt.name, id: opt.id)
    }

    static func accountName(_ name: String, id: String? = nil) -> String {
        resolveCatalogLabel(prefix: "defaultAcc.", byLowerEn: accByLowerEn, name: name, id: id)
    }

    static func accountName(_ a: FinancialAccount) -> String {
        accountName(a.name, id: a.id)
    }

    static func goalName(_ name: String, id: String? = nil) -> String {
        resolveCatalogLabel(prefix: "defaultGoal.", byLowerEn: goalByLowerEn, name: name, id: id)
    }

    static func goalName(_ g: SavingsGoal) -> String {
        goalName(g.name, id: g.id)
    }

    static func accountTypeLabel(_ type: AccountType) -> String {
        let key = "accType.\(type.rawValue)"
        return L10nTables.lang_en[key] != nil ? t(key) : KobanTemplates.accountType(type).label
    }

    static func accountTypeShort(_ type: AccountType) -> String {
        let key = "accTypeShort.\(type.rawValue)"
        return L10nTables.lang_en[key] != nil ? t(key) : KobanTemplates.accountType(type).shortLabel
    }

    static func accountClassLabel(_ cls: AccountLiquidityClass) -> String {
        let key = "accClass.\(cls.rawValue)"
        return L10nTables.lang_en[key] != nil ? t(key) : KobanTemplates.accountClass(cls).label
    }

    static func accountClassOpt(_ cls: AccountLiquidityClass) -> String {
        let key = "accClassOpt.\(cls.rawValue)"
        return L10nTables.lang_en[key] != nil ? t(key) : accountClassLabel(cls)
    }

    static func monthName(_ month: Int, short: Bool = false) -> String {
        let df = DateFormatter()
        df.locale = intlLocale
        let syms = (short ? df.shortStandaloneMonthSymbols : df.standaloneMonthSymbols) ?? []
        let idx = month - 1
        guard idx >= 0 && idx < syms.count else { return "" }
        return syms[idx]
    }

    /// The Windows strings name Windows Hello and Ctrl shortcuts; on macOS the same features are
    /// Touch ID and ⌘. Brand names are kept untranslated in every locale, so a substring swap works.
    static func adaptForMac(_ s: String, skipHelloSwap: Bool = false) -> String {
        guard s.contains("Windows Hello") || s.contains("Ctrl+") else { return s }
        var out = s
        if !skipHelloSwap && !s.contains("Touch ID") {
            for (from, to) in [(", Passkeys & Windows Hello", " & Touch ID"), ("Passkeys & Windows Hello", "Touch ID"), ("Passkey & Windows Hello", "Touch ID"),
                               ("Windows Hello / Passkey", "Touch ID / Passkey"), ("Passkey / Windows Hello", "Touch ID"), ("Windows Hello", "Touch ID")] {
                out = out.replacingOccurrences(of: from, with: to)
            }
        }
        out = out.replacingOccurrences(of: "Ctrl+", with: "⌘")
        return out
    }

    /// detectInitialLanguage(): saved choice, then the system language, then English.
    static func detectInitialLanguage() -> String {
        if let saved = UserDefaults.standard.string(forKey: storageKey), isSupported(saved) { return saved }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return resolve(systemLanguage: preferred)
    }

    /// Maps a BCP-47 tag (e.g. "de-CH", "zh-Hant-TW", "nn") to a supported code.
    static func resolve(systemLanguage nav: String) -> String {
        if isSupported(nav) { return nav }
        if nav.range(of: "^zh[-_](TW|HK|MO|Hant)", options: [.regularExpression, .caseInsensitive]) != nil {
            return "zh-TW"
        }
        let base = nav.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? "en"
        if base == "no" || base == "nn" { return "nb" }
        return isSupported(base) ? base : "en"
    }
}
