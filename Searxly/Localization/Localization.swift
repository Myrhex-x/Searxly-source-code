//
//  Localization.swift
//  Searxly
//
//  Loads strings from the best matching .lproj for the Mac's system language.
//  Falls back to English when no translation bundle exists.
//

import Foundation

enum Localization {
    /// Language used for UI strings (supported .lproj or English).
    static var currentLanguage: AppLanguage { AppLanguage.current }

    /// Language code sent to SearXNG — follows system even without a UI translation.
    static var searchLanguageCode: String { AppLanguage.systemSearchLanguageCode }

    /// Bundle for localized strings: the user's explicit in-app choice first, then the
    /// system preference list.
    static var bundle: Bundle {
        if let override = AppLanguage.override {
            let base = AppLanguage.baseCode(of: override)
            if let path = Bundle.main.path(forResource: base, ofType: "lproj"),
               let langBundle = Bundle(path: path) {
                return langBundle
            }
        }
        for localeID in Locale.preferredLanguages {
            let base = AppLanguage.baseCode(of: localeID)
            if let path = Bundle.main.path(forResource: base, ofType: "lproj"),
               let langBundle = Bundle(path: path) {
                return langBundle
            }
        }
        return .main
    }

    static func string(_ key: String, defaultValue: String? = nil) -> String {
        let value = bundle.localizedString(forKey: key, value: defaultValue, table: nil)
        if value == key, let fallback = defaultValue {
            return fallback
        }
        return value
    }

    /// One-time migrations for older language storage:
    ///  - drops the pre-2026 manual UI override key,
    ///  - folds the legacy search-only override into the unified app language,
    ///  - normalizes codes the local SearXNG runtime doesn't register (it strips or
    ///    rejects unregistered region locales — see `search.languages` in settings.yml).
    static func migrateLanguagePreferences() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "preferredAppLanguage")

        let legacyKey = "searchLanguageOverride"
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            if defaults.string(forKey: AppLanguage.overrideKey) == nil {
                AppLanguage.setOverride(normalizedLanguageChoice(legacy))
            }
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private static func normalizedLanguageChoice(_ code: String) -> String? {
        switch code {
        case "hi-IN": return "hi"
        case "uk-UA": return "uk"
        case "vi-VN": return "vi"
        case "no-NO", "he-IL": return nil   // not registered in search.languages — back to system
        default: return code
        }
    }
}

// MARK: - SwiftUI convenience

import SwiftUI

extension Text {
    init(localized key: String, defaultValue: String? = nil) {
        self.init(Localization.string(key, defaultValue: defaultValue))
    }
}

extension LocalizedStringKey {
    static func app(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}