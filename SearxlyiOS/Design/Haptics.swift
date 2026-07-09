//
//  Haptics.swift
//  SearxlyiOS
//
//  One-line haptic taps for gesture feedback (tab switches, closes, pull-to-search).
//  Kept tiny on purpose — fluidity comes from *restrained* haptics, not buzzing everything.
//

import UIKit

enum Haptics {
    /// Light tick — crossing a gesture threshold (tab switch, pull-to-search).
    static func tick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Slightly firmer — something happened (tab closed).
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Completion notification — a task finished cleanly (a download landed).
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
