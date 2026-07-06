//
//  AppearanceSettings.swift
//  SearxlyiOS
//
//  App-interface text sizing (Settings ▸ Appearance): one multiplier applied to Searxly's own
//  reading surfaces — search results, knowledge cards, suggestions. Web PAGE text size is a
//  separate, per-site control (the lock menu), and system Form/List chrome already follows
//  Dynamic Type on its own.
//

import Foundation
import Observation

enum AppTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    @MainActor var label: String {
        switch self {
        case .small: L("Small")
        case .standard: L("Default")
        case .large: L("Large")
        case .extraLarge: L("Extra Large")
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.88
        case .standard: 1.0
        case .large: 1.14
        case .extraLarge: 1.3
        }
    }
}

@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    var textSize: AppTextSize {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: "searxly.ios.appearance.textSize") }
    }

    /// The multiplier views apply to their font sizes. Reading it inside a view body subscribes
    /// the view, so changing the setting re-renders live.
    var textScale: CGFloat { textSize.scale }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "searxly.ios.appearance.textSize") ?? ""
        textSize = AppTextSize(rawValue: raw) ?? .standard
    }
}
