//
//  SearxlyAIAccess.swift
//  Searxly
//
//  Gates Searxly AI (the paid cloud tier): resolves the user's current tier from an active USDC pass
//  and/or qualifying $SEARXLY holdings, meters the per-day prompt allowance, and buys passes by paying
//  USDC to the shared treasury. Modeled on `ManagedVPNService`.
//
//  On-device backends (Apple Intelligence / local Ollama) are never metered — only the Searxly AI cloud
//  flows through here. See `SearxlyAIConfig` for the layer-1 caveat (the gateway is the authoritative gate).
//

import Foundation
import os
import Observation

@MainActor
@Observable
final class SearxlyAIAccess {
    static let shared = SearxlyAIAccess()

    /// Where we are in a purchase. UI binds to this for progress + errors.
    enum Phase: Equatable {
        case idle
        case paying        // signing + broadcasting the USDC payment
        case done
        case failed(String)

        var errorMessage: String? { if case let .failed(m) = self { return m }; return nil }
        var isBusy: Bool { self == .paying }
    }

    private(set) var phase: Phase = .idle
    private(set) var pass: SearxlyAIPass?
    private(set) var holderUntil: Date?
    private(set) var promptsUsedToday: Int = 0
    private var usageDayStart: Date = SearxlyAIAccess.localStartOfDay(Date())

    private static let log = Logger(subsystem: "com.myrhex.Searxly", category: "searxly-ai")
    private static let storeKey = "SearxlyAI.access.v1"

    private init() {
        load()
        rolloverIfNeeded()
        refreshHolderStatus()
    }

    // MARK: - Tier resolution

    var hasActivePass: Bool { pass?.isActive ?? false }
    var isHolder: Bool { if let until = holderUntil { return Date() < until }; return false }

    /// The effective tier right now: pass and holdings stack (both → `.payAndHold`).
    var tier: SearxlyAITier {
        switch (hasActivePass, isHolder) {
        case (true, true):  return .payAndHold
        case (false, true): return .holder
        case (true, false): return .pass
        default:            return .free
        }
    }

    var dailyLimit: Int { tier.dailyPromptLimit }

    // MARK: - Daily metering (per UTC day)

    /// Pure read — safe to call during a SwiftUI body. Call `refreshDailyWindow()` first (the send path
    /// and the UI's onAppear both do) so the UTC-day rollover has been applied.
    var promptsRemainingToday: Int { max(0, dailyLimit - promptsUsedToday) }

    var canSendPromptToday: Bool { promptsRemainingToday > 0 }

    /// Applies the UTC-day rollover (resets the counter on a new day). Call before reading the counters
    /// in UI or before a send — never from inside a SwiftUI body getter, since it mutates state.
    func refreshDailyWindow() { rolloverIfNeeded() }

    /// Counts Searxly AI cloud prompt usage against today's allowance. `count` lets heavier actions
    /// (e.g. a whole-page summarize) cost more than one. Call when a cloud turn is sent.
    func recordPromptUse(count: Int = 1) {
        rolloverIfNeeded()
        promptsUsedToday += max(1, count)
        save()
    }

    private func rolloverIfNeeded() {
        let today = SearxlyAIAccess.localStartOfDay(Date())
        if usageDayStart != today {
            usageDayStart = today
            promptsUsedToday = 0
            save()
        }
    }

    /// User-facing copy shown in chat when the daily allowance is exhausted. Brand-safe — never names the
    /// underlying model or provider (see AIRules.backendHonestyCloud).
    var limitReachedMessage: String {
        let passPrice = SearxlyAIPlan.monthly.priceUSDC
        switch tier {
        case .free:
            return "You’ve used your \(dailyLimit) free Searxly AI prompts for today. Get \(SearxlyAIConfig.passDailyPrompts)/day with a \(passPrice) USDC monthly pass, or \(SearxlyAIConfig.holderDailyPrompts)/day by holding $SEARXLY. Your free prompts reset tomorrow."
        case .pass:
            return "You’ve reached today’s \(dailyLimit)-prompt limit. Hold $SEARXLY to raise it to \(SearxlyAIConfig.holderDailyPrompts)/day (\(SearxlyAIConfig.payAndHoldDailyPrompts)/day with both). Resets tomorrow."
        case .holder, .payAndHold:
            return "You’ve reached today’s \(dailyLimit)-prompt fair-use limit. It resets tomorrow."
        }
    }

    /// Shown when a cloud turn is attempted without a verified wallet. Stresses it's FREE + anti-abuse only.
    var walletRequiredMessage: String {
        "Connect your Searxly wallet to use Searxly AI. It's completely free — no payment, and no funds ever move. It's just a one-tap signature so each person has a single identity and the free prompts can't be abused. Set it up in Settings → Searxly Agent → Verify wallet."
    }

    // MARK: - Holder check ($SEARXLY)

    /// Token amount required to qualify, derived from the live price (or the fixed fallback).
    var holderTokensRequired: Decimal {
        SearxlyAIConfig.holderTokensRequired(priceUSD: WalletManager.shared.searxlyPriceUSD)
    }

    /// The wallet's current $SEARXLY balance (0 until balances have been refreshed / wallet unlocked).
    var walletSearxlyBalance: Decimal {
        WalletManager.shared.tokens.first { $0.id == "SEARXLY" }?.balance ?? 0
    }

    /// Re-evaluates holder status from the wallet's current $SEARXLY balance vs the live threshold. If the
    /// balance qualifies, (re)grants a 30-day holder window. It NEVER revokes early — the window lapses on
    /// its own, so a temporary price dip (or an unloaded balance) can't kick an existing holder out.
    func refreshHolderStatus() {
        let balance = walletSearxlyBalance
        guard balance > 0 else { return }
        if balance >= holderTokensRequired {
            let newUntil = Date().addingTimeInterval(SearxlyAIConfig.holderWindowDays * 86_400)
            if (holderUntil ?? .distantPast) < newUntil {
                holderUntil = newUntil
                save()
                Self.log.log("Searxly AI: holder window granted (until \(newUntil, privacy: .public))")
            }
        }
    }

    // MARK: - Purchase (USDC → shared treasury)

    /// Pay for a pass with USDC from the in-app wallet, then grant a time-boxed pass. `pin` unlocks the
    /// wallet to sign the payment. The money goes to `SearxlyAIConfig.treasury` (the shared treasury).
    func purchase(plan: SearxlyAIPlan, pin: String) async {
        guard !phase.isBusy else { return }
        phase = .paying

        let paid = await WalletManager.shared.send(
            to: SearxlyAIConfig.treasury,
            amount: plan.priceUSDC,
            token: .usdc,
            pin: pin
        )
        guard paid, let txHash = WalletManager.shared.lastTxHash else {
            phase = .failed(WalletManager.shared.lastError ?? "USDC payment failed to broadcast.")
            return
        }

        let newPass = SearxlyAIPass(
            id: UUID().uuidString,
            planId: plan.id,
            txHash: txHash,
            activatedAt: Date(),
            expiresAt: Date().addingTimeInterval(Double(plan.days) * 86_400)
        )
        pass = newPass
        save()
        // Wire the gateway identity: record the pass tx + mint a signed session (we have the PIN here) so
        // the gateway can verify this wallet's tier on-chain on the next request.
        SearxlyAIIdentity.passTxHash = txHash
        _ = mintSession(pin: pin)
        phase = .done
        Self.log.log("Searxly AI: pass granted (plan \(plan.id, privacy: .public), tx \(txHash, privacy: .public), expires \(newPass.expiresAt, privacy: .public))")
    }

    /// Clears a stale failure so a retry starts clean (called when reopening the purchase sheet).
    func dismissError() { if case .failed = phase { phase = .idle } }

    // MARK: - Wallet verification (SIWE session for the gateway)

    /// True once the wallet has a non-expired signed session the gateway can verify.
    var isWalletVerified: Bool { SearxlyAIIdentity.hasValidSession }

    /// Signs a short-lived session with the wallet so the gateway can authoritatively check this wallet's
    /// tier (holder balance / pass) server-side. Needs the PIN to access the signing key. Holders who
    /// haven't bought a pass call this to prove their wallet; buyers get it for free at purchase.
    @discardableResult
    func mintSession(pin: String) -> Bool {
        guard let address = WalletManager.shared.activeAddress else { return false }
        let (message, expiresAt) = SearxlyAIIdentity.sessionMessage(address: address)
        guard let signature = WalletManager.shared.dappPersonalSign(message: message, pin: pin) else { return false }
        SearxlyAIIdentity.session = SearxlyAIIdentity.Session(
            address: address, message: message, signature: signature, expiresAt: expiresAt)
        Self.log.log("Searxly AI: wallet session minted for \(address, privacy: .public)")
        return true
    }

    // MARK: - Persistence (device-local; not sensitive — a public tx hash + expiry + a counter)

    private struct Stored: Codable {
        var pass: SearxlyAIPass?
        var holderUntil: Date?
        var usageDayStart: Date
        var promptsUsedToday: Int
    }

    private func save() {
        let stored = Stored(pass: pass, holderUntil: holderUntil,
                            usageDayStart: usageDayStart, promptsUsedToday: promptsUsedToday)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        pass = stored.pass
        holderUntil = stored.holderUntil
        usageDayStart = stored.usageDayStart
        promptsUsedToday = stored.promptsUsedToday
    }

    // MARK: - Helpers

    /// Start of the current LOCAL day (device timezone) — the displayed counter resets at the user's local
    /// midnight. The gateway enforces the same boundary authoritatively from ITS clock + the device's tz
    /// offset (locked per wallet), so changing the device clock can't grant free resets.
    private static func localStartOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}
