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
        guard ProcessInfo.processInfo.environment["KOBAN_DB_PATH"] == nil else { return }
        UserDefaults.standard.set(code, forKey: storageKey)
    }

    /// Translated string for `key`, falling back to English, then to the key itself.
    static func t(_ key: String) -> String {
        let lang = state.language
        let raw = L10nTables.tables[lang]?[key] ?? L10nTables.lang_en[key] ?? key
        return adaptForMac(raw)
    }

    /// Same lookup for an explicit language (tests, previews).
    static func t(_ key: String, language: String) -> String {
        adaptForMac(L10nTables.tables[language]?[key] ?? L10nTables.lang_en[key] ?? key)
    }

    /// The Windows strings name Windows Hello and Ctrl shortcuts; on macOS the same features are
    /// Touch ID and ⌘. Brand names are kept untranslated in every locale, so a substring swap works.
    static func adaptForMac(_ s: String) -> String {
        guard s.contains("Windows Hello") || s.contains("Ctrl+") else { return s }
        var out = s
        for (from, to) in [(", Passkeys & Windows Hello", " & Touch ID"), ("Passkeys & Windows Hello", "Touch ID"), ("Passkey & Windows Hello", "Touch ID"),
                           ("Passkey / Windows Hello", "Touch ID"), ("Windows Hello", "Touch ID"),
                           ("Ctrl+", "⌘")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
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
