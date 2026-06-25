//
//  SettingsBadge.swift
//  Searxly
//
//  Tiny reusable capsule badge for settings panes (Recommended, Protected, Active, On, etc.).
//  Created during settings UI rework to eliminate repeated manual .padding + .background + .clipShape patterns.
//  Consistent, minimal, uses subtle tinted backgrounds.
//

import SwiftUI

struct SettingsBadge: View {
    let text: String
    var tint: Color = .white

    private var accent: Color { SettingsTheme.resolve(tint) }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(accent.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(accent.opacity(0.28), lineWidth: 0.5))
            .foregroundStyle(accent)
    }
}
