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

    @State private var selectedLevel: OnboardingPrivacyLevel?
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

    /// Drives the "launch into the app" flourish on the final step.
    @State private var isLaunching = false

    /// SearXNG is bundled and provisions itself, so there's no manual "set up local search" step
    /// anymore. We kick provisioning + first boot off in the background as soon as onboarding appears
    /// so the private instance is ready (or nearly so) by the time the user reaches the Ready step.
    @State private var didKickOffLocalSearch = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HomeAmbientBackground(glassEnabled: glassEnabled, homeStarsEnabled: true)

            // Extra cinematic flourish on the opening + closing screens.
            if currentStep == 0 || currentStep == OnboardingStyle.stepCount - 1 {
                OnboardingShootingStars()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

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
        // Launch flourish: the whole onboarding dips, then zooms out + blurs + fades,
        // revealing the app, while a bloom + shockwave flash from the center.
        .keyframeAnimator(initialValue: OnboardingLaunchPose(), trigger: isLaunching) { view, pose in
            view
                .scaleEffect(pose.scale)
                .blur(radius: pose.blur)
                .opacity(pose.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.97, duration: 0.16)
                SpringKeyframe(1.18, duration: 0.52)
            }
            KeyframeTrack(\.opacity) {
                CubicKeyframe(1.0, duration: 0.20)
                CubicKeyframe(0.0, duration: 0.46)
            }
            KeyframeTrack(\.blur) {
                CubicKeyframe(0.0, duration: 0.22)
                CubicKeyframe(7.0, duration: 0.44)
            }
        }
        .overlay {
            if isLaunching && !reduceMotion {
                OnboardingLaunchBurst()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 620, minHeight: 580)
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
            startLocalSearchInBackground()
        }
    }

    /// Provisions + starts the bundled SearXNG once, off the main flow. Idempotent and silent:
    /// failures surface later via the Ready step status (and Settings → Instances troubleshooting),
    /// never as a blocking onboarding step.
    private func startLocalSearchInBackground() {
        guard !didKickOffLocalSearch else { return }
        didKickOffLocalSearch = true
        Task { @MainActor in
            await setup.startLocalSearch()
            if setup.isConnectionSuccessful {
                applyInstanceFromSetup()
            }
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
            encryptionShell
        case 3:
            walletShell
        case 4:
            vpnShell
        case 5:
            securityShell
        case 6:
            readyShell
        default:
            welcomeShell
        }
    }

    private var welcomeShell: some View {
        OnboardingShell(step: 0, showProgress: false, useGlassCard: false, maxContentWidth: OnboardingStyle.centeredContentWidth) {
            OnboardingWelcomeStep(glassEnabled: glassEnabled)
        } actionBar: {
            OnboardingActionBar(
                showBack: false,
                skipTitle: "Skip intro",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Take the tour",
                primarySystemImage: "arrow.right",
                primaryAction: { advance(to: 1) }
            )
        }
    }

    private var localSearchShell: some View {
        OnboardingShell(step: 1, scrollable: false, showProgress: true, useGlassCard: false) {
            OnboardingLocalSearchStep()
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Skip intro",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Next",
                primarySystemImage: "arrow.right",
                primaryAction: { advance(to: 2) }
            )
        }
    }

    private var encryptionShell: some View {
        OnboardingShell(step: 2, scrollable: false, showProgress: true, useGlassCard: false) {
            OnboardingEncryptionStep()
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Skip intro",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Next",
                primarySystemImage: "arrow.right",
                primaryAction: { advance(to: 3) }
            )
        }
    }

    private var walletShell: some View {
        OnboardingShell(step: 3, scrollable: false, showProgress: true, useGlassCard: false) {
            OnboardingWalletStep()
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Skip intro",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Next",
                primarySystemImage: "arrow.right",
                primaryAction: { advance(to: 4) }
            )
        }
    }

    private var vpnShell: some View {
        OnboardingShell(step: 4, scrollable: false, showProgress: true, useGlassCard: false) {
            OnboardingVPNStep()
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Skip intro",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Next",
                primarySystemImage: "arrow.right",
                primaryAction: { advance(to: 5) }
            )
        }
    }

    private var securityShell: some View {
        OnboardingShell(
            step: 5,
            instruction: "Pick a protection level below. App Lock is optional, but recommended for shared Macs.",
            scrollable: true,
            showProgress: true,
            useGlassCard: false,
            maxContentWidth: OnboardingStyle.centeredContentWidth
        ) {
            OnboardingSecurityStep(
                selectedLevel: $selectedLevel,
                recoveryCode: $recoveryCodeInOnboarding,
                encryptionSetupError: $encryptionSetupError,
                showRecoveryCopied: $showRecoveryCopied,
                showRecoveryDownloaded: $showRecoveryDownloaded,
                recoveryDownloadError: $recoveryDownloadError,
                isSavingRecoveryFile: $isSavingRecoveryFile,
                appLockEnabled: $appLockEnabledInThisSession,
                isPerformingAppLockAuth: $isPerformingAppLockAuth,
                appLockSetupError: $appLockSetupError,
                onSelectLevel: applyPrivacyLevel,
                onToggleAppLock: toggleAppLock
            )
        } actionBar: {
            OnboardingActionBar(
                showBack: true,
                backAction: goBack,
                skipTitle: "Later",
                skipAction: dismissOnboardingEarly,
                primaryTitle: "Continue",
                primarySystemImage: "arrow.right",
                primaryDisabled: selectedLevel == nil,
                primaryAction: { advance(to: 6) }
            )
        }
    }

    private var readyShell: some View {
        OnboardingShell(step: 6, showProgress: false, useGlassCard: false, maxContentWidth: OnboardingStyle.centeredContentWidth) {
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
                primaryAction: launchIntoApp
            )
        }
    }

    private var privacySummaryLabel: String {
        switch selectedLevel {
        case .maximum:   return "Maximum protection enabled"
        case .encrypted: return "Encrypted on this Mac"
        case .standard:  return "Standard privacy enabled"
        case nil:
            return PrivacyManager.shared.dataEncryptionEnabled ? "Encryption on" : "Default privacy settings"
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let offset = CGFloat(stepDirection) * 36
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: offset, y: 8)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(x: -offset * 0.6, y: -6)).combined(with: .scale(scale: 0.99))
        )
    }

    private func goBack() {
        isPerformingAppLockAuth = false
        appLockSetupError = nil
        advance(to: max(0, currentStep - 1))
    }

    private func advance(to step: Int) {
        stepDirection = step > currentStep ? 1 : -1
        var transaction = Transaction(animation: OnboardingStyle.stepSpring)
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            currentStep = step
        }
    }

    private func syncStepState(for step: Int) {
        switch step {
        case 5:
            // Security/privacy step. Reflect any already-applied state.
            if PrivacyManager.shared.dataEncryptionEnabled, selectedLevel == nil {
                selectedLevel = .encrypted
                recoveryCodeInOnboarding = PrivacyManager.shared.exportEncryptionRecoveryCode()
            }
            appLockEnabledInThisSession = AppLockManager.shared.isAppLockEnabled
            appLockSetupError = nil
        default:
            break
        }
    }

    private func dismissOnboardingEarly() {
        completeOnboarding()
    }

    private func applyInstanceFromSetup() {
        setup.applyInstance(searxInstances: &searxInstances, currentInstanceID: &currentInstanceID)
    }

    /// Immediate completion (used when skipping). No flourish.
    private func completeOnboarding() {
        if setup.isConnectionSuccessful {
            applyInstanceFromSetup()
        }
        PrivacyManager.shared.setDefaultNewTabsToPrivate(true)
        hasCompletedOnboarding = true
    }

    /// Final "Start browsing": plays the launch flourish, then hands off to the app.
    private func launchIntoApp() {
        guard !isLaunching else { return }
        if setup.isConnectionSuccessful {
            applyInstanceFromSetup()
        }
        PrivacyManager.shared.setDefaultNewTabsToPrivate(true)

        guard !reduceMotion else {
            hasCompletedOnboarding = true
            return
        }

        // Toggling the keyframe trigger plays the launch transform; hand off to the app
        // as it finishes fading.
        isLaunching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            hasCompletedOnboarding = true
        }
    }

    // MARK: - Security actions

    /// Applies a privacy tier. Each tier is a superset of the previous one, so the
    /// underlying PrivacyManager calls stack accordingly.
    private func applyPrivacyLevel(_ level: OnboardingPrivacyLevel) {
        encryptionSetupError = nil
        showRecoveryCopied = false
        showRecoveryDownloaded = false

        // Session privacy (Standard and up): private tabs + no history.
        PrivacyManager.shared.setDefaultNewTabsToPrivate(true)
        PrivacyManager.shared.setHistoryEnabled(false)

        // Maximum additionally clears existing web data and disables Local AI.
        if level == .maximum {
            PrivacyManager.shared.enableStrictPrivacyMode()
        }

        // Encrypted and Maximum add at-rest encryption + a recovery code.
        if level.includesEncryption {
            let result = PrivacyManager.shared.enableSecureMacPreset(enableAppLock: false)
            guard result.encryptionEnabled else {
                selectedLevel = nil
                recoveryCodeInOnboarding = nil
                encryptionSetupError = result.partialError
                    ?? "Could not enable encryption. Searxly may not have Keychain access."
                return
            }
            recoveryCodeInOnboarding = result.recoveryCode
            if recoveryCodeInOnboarding == nil {
                encryptionSetupError = "Encryption is on, but the recovery code could not be read. Try Settings → Privacy."
            }
        } else {
            recoveryCodeInOnboarding = nil
        }

        selectedLevel = level
    }

    /// Real on/off App Lock toggle. Turning on authenticates first; turning off is immediate.
    private func toggleAppLock(_ desired: Bool) {
        appLockSetupError = nil
        guard desired != appLockEnabledInThisSession else { return }

        guard desired else {
            AppLockManager.shared.setAppLockEnabled(false)
            appLockEnabledInThisSession = false
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics/password available — enable without a prompt.
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
                    self.appLockSetupError = "Authentication cancelled. App Lock is still off."
                    if let authError {
                        Log.app.error("Onboarding app lock auth failed: \(authError.localizedDescription)")
                    }
                }
            }
        }
    }
}