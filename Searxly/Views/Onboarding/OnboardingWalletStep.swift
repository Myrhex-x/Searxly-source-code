//
//  OnboardingWalletStep.swift
//  Searxly
//

import SwiftUI

struct OnboardingWalletStep: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingFeatureSlide(
            eyebrow: "Self-custody wallet · Beta",
            title: "A wallet that's truly yours",
            subtitle: "A real Base wallet is built right in. Your seed phrase and private keys are created on this Mac and held in the Keychain — there's no custodian, no account, and nothing for anyone else to lose. It's optional, off until you turn it on.",
            pills: [
                OnboardingPill(icon: "key.horizontal.fill", text: "Keys on-device"),
                OnboardingPill(icon: "person.crop.circle.badge.xmark", text: "No account"),
                OnboardingPill(icon: "arrow.left.arrow.right", text: "Swap built in")
            ]
        ) {
            OnboardingWalletDemo()
        } extra: {
            betaNotice
        }
    }

    /// The wallet ships in beta — say so up front (brand-legal: amber is a genuine warning, not decor).
    private var betaNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("In beta — keep it small")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Self-custody means you alone hold the keys. Only keep small amounts here while the wallet matures, and write down your recovery phrase.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.top, 4)
    }
}
