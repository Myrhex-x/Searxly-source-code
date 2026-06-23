//
//  OnboardingFlow.swift
//  Searxly
//

import AppKit
import os
import SwiftUI
import LocalAuthentication

struct OnboardingFlow: View {
    @Binding var hasCompletedOnboarding: Bool
    @Binding var searxInstances: [SearXNGInstance]
    @Binding var currentInstanceID: UUID

    var glassEnabled: Bool = true

    @State private var currentStep = 0
    @State private var stepDirection = 1
    @State private var setup = OnboardingSetupController()

    @State private var selectedEncryptionChoice: Bool?
    @State private var usedSecureMacPreset = false
    @State private var usedMaximumPrivacyPreset = false
    @State private var recoveryCodeInOnboarding: String?
    @State private var encryptionSetupError: String?
    @State private var showRecoveryCopied = false
    @State private var showRecoveryDownloaded = false
    @State private var recoveryDownloadError: String?
    @State private var isSavingRecoveryFile = false

    @State private var appLockEnabledInThisSession = false
    @State private var isPerformingAppLockAuth = false
    @State private var appLockSetupError: String?
    @State private var appLockAuthContext: LAContext?

    @State private var isStartingLocalSearch = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var existingInstanceURLs: [String] {
        searxInstances.map(\.url)
    }

    var body: some View {
        ZStack {
            HomeAmbientBackground(glassEnabled: glassEnabled, homeStarsEnabled: true)

            GeometryReader { geo in
                let isCompact = geo.size.width < 680

                VStack(spacing: 0) {
                    stepContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(currentStep)
                        .transition(stepTransition)
                }
                .padding(.horizontal, isCompact ? 16 : 28)
                .padding(.vertical, isCompact ? 12 : 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 620, minHeight: 560)
        .onboardingGlassEnabled(glassEnabled)
        .onChange(of: setup.isConnectionSuccessful) { _, success in
            if success {
                applyInstanceFromSetup()
            }
        }
        .onChange(of: currentStep) { _, step in
            syncStepState(for: step)
        }
        .onAppear {
            syncStepState(for: currentStep)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            welcomeShell
        case 1:
            localSearchShell
        case 2:
            securityShell
        case 3:
            readyShell
        default:
            welcomeShell
        }
    }

    private var welcomeShell: some View {
        OnboardingShell(step: 0, showProgress: false, useGlassCard: false) {
            OnboardingWelcomeStep(glassEnabled: glassEnabled)
        } actionBar: {
            OnboardingActionBar(
                showBack: false,
                skipTitle: "Set up later",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Get started",
                primarySystemImage: "arrow.right",
                primaryAction: { advance(to: 1) }
            )
        }
    }

    private var localSearchShell: some View {
        OnboardingShell(
            step: 1,
            instruction: "Nothing starts until you tap Start local search. SearXNG is built in — nothing to install. First boot takes a few seconds.",
            scrollable: true,
            showProgress: true
        ) {
            OnboardingLocalSearchStep(setup: setup)
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Later",
                skipAction: dismissOnboardingEarly,
                primaryTitle: localSearchPrimaryTitle,
                primarySystemImage: setup.isConnectionSuccessful ? "arrow.right" : "sparkles",
                primaryDisabled: localSearchPrimaryDisabled,
                primaryLoading: isStartingLocalSearch,
                primaryAction: handleLocalSearchPrimary
            )
        }
    }

    private var securityShell: some View {
        OnboardingShell(
            step: 2,
            instruction: "Pick a privacy level below. App Lock is optional, but recommended for shared Macs.",
            scrollable: true,
            showProgress: true
        ) {
            OnboardingSecurityStep(
                selectedEncryptionChoice: $selectedEncryptionChoice,
                usedMaximumPrivacyPreset: $usedMaximumPrivacyPreset,
                usedSecureMacPreset: $usedSecureMacPreset,
                recoveryCodeInOnboarding: $recoveryCodeInOnboarding,
                encryptionSetupError: $encryptionSetupError,
                showRecoveryCopied: $showRecoveryCopied,
                showRecoveryDownloaded: $showRecoveryDownloaded,
                recoveryDownloadError: $recoveryDownloadError,
                isSavingRecoveryFile: $isSavingRecoveryFile,
                appLockEnabledInThisSession: $appLockEnabledInThisSession,
                isPerformingAppLockAuth: $isPerformingAppLockAuth,
                appLockSetupError: $appLockSetupError,
                onMaximumPrivacy: enableMaximumPrivacyDuringOnboarding,
                onSecureMac: enableSecureMacDuringOnboarding,
                onUseDefaults: acceptDefaultPrivacyDuringOnboarding,
                onEnableAppLock: enableAppLockDuringOnboarding
            )
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Later",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Continue",
                primarySystemImage: "arrow.right",
                primaryDisabled: selectedEncryptionChoice == nil && !usedMaximumPrivacyPreset,
                primaryAction: { advance(to: 3) }
            )
        }
    }

    private var readyShell: some View {
        OnboardingShell(step: 3, showProgress: false, useGlassCard: false) {
            OnboardingReadyStep(
                glassEnabled: glassEnabled,
                localSearchReady: setup.isConnectionSuccessful,
                privacyLabel: privacySummaryLabel,
                appLockEnabled: appLockEnabledInThisSession || AppLockManager.shared.isAppLockEnabled
            )
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                primaryTitle: "Start browsing",
                primarySystemImage: "arrow.right",
                primaryAction: finishOnboarding
            )
        }
    }

    private var localSearchPrimaryTitle: String {
        if isStartingLocalSearch {
            return "Setting up…"
        }
        if setup.isConnectionSuccessful {
            return "Continue"
        }
        return "Start local search"
    }

    private var localSearchPrimaryDisabled: Bool {
        if setup.isConnectionSuccessful { return false }
        if isStartingLocalSearch { return true }
        return false
    }

    private var privacySummaryLabel: String {
        if usedMaximumPrivacyPreset { return "Maximum Privacy enabled" }
        if usedSecureMacPreset { return "Secure this Mac enabled" }
        if selectedEncryptionChoice == false { return "Default privacy settings" }
        return PrivacyManager.shared.dataEncryptionEnabled ? "Encryption on" : "Default privacy settings"
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let offset = CGFloat(stepDirection) * 36
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: offset, y: 8)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(x: -offset * 0.6, y: -6)).combined(with: .scale(scale: 0.99))
        )
    }

    private func handleLocalSearchPrimary() {
        if setup.isConnectionSuccessful {
            applyInstanceFromSetup()
            advance(to: 2)
            return
        }
        setup.cancelAllTasks()
        isStartingLocalSearch = true
        Task { @MainActor in
            defer { isStartingLocalSearch = false }
            await setup.startLocalSearch()
            if setup.isConnectionSuccessful {
                applyInstanceFromSetup()
            }
        }
    }

    private func goBack() {
        isPerformingAppLockAuth = false
        appLockSetupError = nil
        advance(to: max(0, currentStep - 1))
    }

    private func advance(to step: Int) {
        stepDirection = step > currentStep ? 1 : -1
        if step == 1 {
            setup.resetForStepEntry()
        }
        var transaction = Transaction(animation: OnboardingStyle.stepSpring)
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            currentStep = step
        }
    }

    private func syncStepState(for step: Int) {
        switch step {
        case 1:
            if !setup.hasTriggeredAutoSetup {
                setup.scheduleSetupProbe(activeStep: step, existingInstanceURLs: existingInstanceURLs)
            }
        case 2:
            if PrivacyManager.shared.dataEncryptionEnabled, selectedEncryptionChoice == nil {
                selectedEncryptionChoice = true
                recoveryCodeInOnboarding = PrivacyManager.shared.exportEncryptionRecoveryCode()
            }
            appLockEnabledInThisSession = AppLockManager.shared.isAppLockEnabled
            appLockSetupError = nil
        default:
            break
        }
    }

    private func dismissOnboardingEarly() {
        if setup.isConnectionSuccessful {
            applyInstanceFromSetup()
        }
        finishOnboarding()
    }

    private func applyInstanceFromSetup() {
        setup.applyInstance(searxInstances: &searxInstances, currentInstanceID: &currentInstanceID)
    }

    private func finishOnboarding() {
        if setup.isConnectionSuccessful {
            applyInstanceFromSetup()
        }
        PrivacyManager.shared.setDefaultNewTabsToPrivate(true)
        hasCompletedOnboarding = true
    }

    // MARK: - Security actions

    private func enableMaximumPrivacyDuringOnboarding() {
        encryptionSetupError = nil
        showRecoveryCopied = false
        showRecoveryDownloaded = false
        usedMaximumPrivacyPreset = true
        usedSecureMacPreset = false

        PrivacyManager.shared.enableStrictPrivacyMode()
        selectedEncryptionChoice = true
        recoveryCodeInOnboarding = PrivacyManager.shared.exportEncryptionRecoveryCode()
    }

    private func acceptDefaultPrivacyDuringOnboarding() {
        withAnimation(OnboardingStyle.cardSpring) {
            usedMaximumPrivacyPreset = false
            usedSecureMacPreset = false
            selectedEncryptionChoice = false
            encryptionSetupError = nil
            showRecoveryCopied = false
            showRecoveryDownloaded = false

            if PrivacyManager.shared.dataEncryptionEnabled {
                recoveryCodeInOnboarding = PrivacyManager.shared.exportEncryptionRecoveryCode()
            } else {
                recoveryCodeInOnboarding = nil
            }
        }
    }

    private func enableSecureMacDuringOnboarding() {
        encryptionSetupError = nil
        showRecoveryCopied = false
        showRecoveryDownloaded = false
        usedSecureMacPreset = true
        usedMaximumPrivacyPreset = false

        let result = PrivacyManager.shared.enableSecureMacPreset(enableAppLock: false)
        guard result.encryptionEnabled else {
            selectedEncryptionChoice = nil
            recoveryCodeInOnboarding = nil
            usedSecureMacPreset = false
            encryptionSetupError = result.partialError ?? "Could not enable encryption. Searxly may not have Keychain access."
            return
        }

        selectedEncryptionChoice = true
        recoveryCodeInOnboarding = result.recoveryCode

        if recoveryCodeInOnboarding == nil {
            encryptionSetupError = "Encryption is on, but the recovery code could not be read. Try Settings → Privacy."
        }
    }

    private func enableAppLockDuringOnboarding() {
        appLockSetupError = nil
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            AppLockManager.shared.setAppLockEnabled(true)
            appLockEnabledInThisSession = true
            return
        }

        isPerformingAppLockAuth = true
        appLockAuthContext = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Enable App Lock for Searxly") { success, authError in
            Task { @MainActor in
                self.appLockAuthContext = nil
                self.isPerformingAppLockAuth = false
                if success {
                    AppLockManager.shared.setAppLockEnabled(true)
                    self.appLockEnabledInThisSession = true
                    self.appLockSetupError = nil
                } else {
                    self.appLockSetupError = "Authentication cancelled. You can try again or skip."
                    if let authError {
                        Log.app.error("Onboarding app lock auth failed: \(authError.localizedDescription)")
                    }
                }
            }
        }
    }
}