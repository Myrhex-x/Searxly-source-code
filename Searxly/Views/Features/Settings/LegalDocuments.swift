//
//  LegalDocuments.swift
//  Searxly
//
//  The canonical Privacy Policy and Terms of Service, shown in-app (Settings ▸ Legal) and mirrored
//  word-for-word on searxly.app (privacy.html / terms.html). Kept in-app so a privacy browser never
//  needs a network request to let you read its own policy.
//
//  Plain-language, and platform/edition-aware: sections tagged "(macOS)" describe features the iOS
//  build doesn't have; iPhone/iPad search is explicitly called out because it uses a hosted instance.
//
//  Every factual claim here is checked against the code (network egress, storage, defaults). If you
//  change app behavior that touches the network or stores data, update this text.
//
//  IMPORTANT: this text is duplicated in three places on purpose (no shared module across the macOS
//  and iOS targets, and the site is a separate repo). If you change it here, also update:
//    • SearxlyiOS/Settings/SettingsView.swift  (LegalText)
//    • searxly-website-redesign: app/privacy/page.tsx, app/terms/page.tsx, app/eula/page.tsx
//      (the Next.js site that has served searxly.app since 2026-07-13 — NOT the old static
//       Searxly-website repo, which is only kept as a rollback)
//
//  NB the section numbers differ between the two: the site's Privacy has an extra "Support website"
//  section, so Editions is §13 here and §14 there. Don't blind-copy — match by heading, not number.
//

import SwiftUI

enum LegalDocuments {
    /// Shown in the pane and mirrored in the site's "Last updated" line — bump when the text changes.
    static let lastUpdated = "July 2026"

    static let privacyURL = URL(string: "https://searxly.app/privacy")!
    static let termsURL   = URL(string: "https://searxly.app/terms")!

    // MARK: - Privacy Policy

    static let privacyPolicy = """
    > The short version: we collect almost nothing, and we tell you exactly what the few exceptions are. This is plain language, not boilerplate — if it ever conflicts with how Searxly actually behaves, the product's behavior is the source of truth and we'll fix the wording.

    ## 1. Our approach
    Searxly is private by architecture, not by promise. There are no accounts, no analytics SDKs, and no telemetry in the app. We don't build an ad profile of you, and we have no business model that depends on your data. Most of what the app does happens entirely on your own device, where we never see it. Where a feature does touch the network, this policy names it and says what it reveals.

    ## 2. What stays on your device
    The following is stored on your device and is never sent to a Searxly server:
    - **Browsing history & bookmarks** — kept locally. You can turn history off, and turn on encryption-at-rest (CryptoKit + your device keychain) for stored data.
    - **Passwords** — the password vault (Searxly Maximum, macOS) is local and encrypted; entries are never synced to us.
    - **Wallet keys** — on macOS, wallet keys are generated from a standard recovery phrase and encrypted on your device. They never leave it; we cannot access your funds, see your phrase, or sign on your behalf.
    - **Search on macOS** — your searches run through a search engine on your own Mac (see section 3).
    - **Agentic Tools (macOS)** — the local tool server your own AI can connect to runs entirely on your Mac, and is off by default (see section 4).

    ## 3. Search & address-bar suggestions
    How search reaches the web depends on your platform:
    - **On macOS**, Searxly runs a SearXNG search engine locally on your Mac. Your query is aggregated on-device, and the engine fetches results from upstream sources directly from your machine (or through Tor in Searxly Maximum). We do not receive, store, or log your searches.
    - **On iPhone & iPad**, the search engine can't run on the device, so the app searches through our hosted instance at search.searxly.app. Your query and IP reach that server the same way any request reaches any website. We run SearXNG, which is built not to keep search logs or user profiles — we don't associate queries with your identity, build ad profiles from them, or sell them. The server keeps only minimal, short-lived operational data (as any server does) to run the service and prevent abuse.
    - **Address-bar suggestions** — as you type, search-query completions are fetched from your configured search instance: on macOS that's your local engine, so they never leave your Mac; if you set a remote instance (or on iPhone & iPad, where "Online Suggestions" is off by default), they're sent there. There's no third-party autocomplete, and website/history suggestions are always computed locally.

    ## 4. On-device AI & Agentic Tools
    Searxly's own AI features run on your device, not in a Searxly cloud:
    - **On iPhone & iPad**, optional AI features — a short AI Overview above results, page summaries, and "ask about this page" — run entirely on-device using Apple Intelligence. Nothing is sent to any server, which is why they also work in private tabs. (Page translation likewise uses Apple's on-device translation.)
    - **On macOS**, Searxly has no built-in AI assistant. Instead it exposes its private browsing as tools your own local AI can call over the Model Context Protocol, through a small server that is off until you turn it on, bound to loopback, and protected by a token. Tool calls run locally — private search routes only through your own engine, and page reads or browser actions happen on your device — and every call is written to an activity log you can read. If you connect a cloud model yourself, whatever your client sends to that provider is between you and them; Searxly still runs the tools locally and sends nothing itself.

    ## 5. Safe-browsing warning
    Searxly can warn you before a known-malicious or deceptive site. The check runs against a blocklist bundled inside the app, entirely on your device — deliberately not Google Safe Browsing, which would send every address you visit to a third party. Nothing about the sites you visit leaves your device. It's on by default, and you can turn it off.

    ## 6. VPN (macOS)
    Searxly's base edition includes an optional managed VPN. When you turn it on, your internet traffic is routed through our VPN server before it reaches the sites you visit — so that server necessarily carries your traffic in transit. We operate it on a no-logs basis: we don't keep records of the sites you visit through the VPN. The server processes only the minimal connection data needed to run the service and prevent abuse. Access can be gated by a pass — connecting proves a signature from your wallet and an on-chain check, which our gateway sees and uses only to verify access, not to profile you.

    You can also pay for a pass by card. Card payments run on Stripe's hosted checkout — Searxly never sees or stores your card number. Stripe processes the payment details and the email you give it for a receipt as an independent controller under its own privacy policy; we receive only confirmation that a payment succeeded, so we can activate your pass. Paying in crypto involves no card and no payment processor, and is the more private option.

    ## 7. Wallet & on-chain features (macOS)
    If you use the built-in wallet, your keys stay on your device (see section 2). To function, it reads public information and uses a few third parties:
    - **Blockchain nodes (Base RPC)** — to read balances and broadcast transactions you approve, through public Base RPC providers. Like any on-chain request, they see the request and your IP.
    - **Transaction history** — fetched from a public block-explorer API (Etherscan); it sees the address you're viewing and your IP.
    - **Price feeds** (CoinGecko, GeckoTerminal, DexScreener) — for coin prices, charts, and coin logos. These are looked up by public contract address only.
    - **Optional name resolution** — if you turn on ENS / Basenames, `.eth` and Base names are resolved through a public Ethereum/Base RPC.
    - **Swaps** — swaps require your own 0x API key, and the request goes straight from your Mac to 0x. No Searxly server sits in the swap: we never see your address, the pair, or the amount, and we never relay or route the trade. The transaction 0x returns is signed on your device by you.
    We never custody your funds, act as a broker or exchange, or sign on your behalf. On-chain swaps carry a small fee, described in our Terms.

    ## 8. Feedback you send us (macOS)
    If you use in-app Feedback, or submit a knowledge-panel correction, the message you write is delivered to our team channel (through a webhook to Discord, which processes it as our messaging tool). We receive only what you choose to type, plus any minimal context you include. It's entirely optional, and only ever sent when you press send.

    ## 9. App updates (macOS)
    Searxly checks for updates by requesting our update feed from searxly.app. That request reveals your IP and current version to the host, like any web request. Updates are cryptographically signed and verified before they install. In Searxly Maximum the update check is fetched over Tor (and can use an .onion feed), so even the version check doesn't reveal your IP.

    ## 10. Normal browsing requests
    Searxly is a web browser, so when you open a page or load a result's favicon, thumbnail, or a knowledge-card source (e.g. Grokipedia or Wikipedia), your device contacts those third-party sites directly — exactly as any browser does. Those servers see a normal request and your IP. Built-in ad & tracker blocking reduces this; we don't sit in the middle of it or log it.

    ## 11. This website
    The searxly.app site is static and ships no tracking scripts and no advertising cookies. Your web host may keep standard server access logs (e.g. IP, user-agent) for security and operations, as is normal for any website.

    ## 12. Editions & Searxly Maximum licences
    Searxly Maximum is a paid edition, built to run locally: it has no managed VPN, no wallet, no Local Pack, and no feedback webhook. Its search runs locally and can route through Tor, and its bundled Tor runtime is signature-verified at every launch.

    **Activating your licence is the one and only time Maximum contacts us.** When you enter your licence key, the app sends us that key together with a **one-way fingerprint of your Mac's hardware ID** — a salted hash, so we never receive the ID itself — and we tie your licence to that one machine. That request does not include your name, your email, or anything about your browsing, and **the app never contacts us again afterwards**: every later check happens on your Mac, offline, with no network at all.

    We store that fingerprint against your licence, plus a receipt of when your key was issued and emailed. We keep both for as long as your licence is valid — and because Maximum licences never expire, that means indefinitely. We need them to move your licence to a new Mac, to send you your key again if you lose it, and to prove we delivered what you paid for. The lawful basis is performance of our contract with you (Article 6(1)(b) GDPR).

    We treat that fingerprint as personal data: it is **pseudonymous, not anonymous**, because we can link it to your purchase and therefore to the email address Stripe holds for you. You can ask for a copy of it, or ask us to erase it — though erasing it means we can no longer move your licence to another Mac or re-send your key.

    ## 14. What we never do
    We don't sell, rent, or share your data with advertisers or data brokers — ever. We don't run analytics or telemetry, and we don't build a profile of you.

    ## 15. Data retention
    On-device data lives on your device for as long as you keep it, and clears when you delete it, run a panic-wipe, or enable strict privacy mode. There are no server-side accounts. The limited server touch-points above (our search instance, the VPN/gateway, Local Pack, and feedback you send) keep only minimal, short-lived operational data as described.

    **One thing we keep indefinitely:** if you buy Searxly Maximum, the activation record and delivery receipt for your licence (see section 13). A Maximum licence never expires, so those records have to outlive any fixed retention window — without them we could not move your licence to a new Mac, re-send your key, or show that we delivered it. They contain no name, no address, and no browsing data: only your licence, a one-way fingerprint of the Mac it runs on, and the timestamps.

    ## 16. Your controls & rights
    - Turn history off, or encrypt stored data at rest.
    - Keep Agentic Tools off entirely, or local-only, and require confirmation for any tool that touches the network.
    - Use panic-wipe or strict privacy mode to clear local data instantly.
    Because we hold almost nothing about you, you control your own data directly on your device. For the limited server touch-points, you can contact us to ask what we hold or request deletion. If you're in the EU/EEA or the UK, you keep your local data-protection rights, including access and erasure.

    ## 17. Children
    Searxly is not directed to children, and any crypto activity is intended for adults. Age and legal requirements for crypto vary by region — please don't route around them.

    ## 18. Who we are & contact
    Searxly is an independent project operated by its developer. For questions, security reports, or data requests, reach us through the channels below. These are the only official channels; anything else claiming to be Searxly isn't:
    - Support — [support.searxly.app](https://support.searxly.app), or email [support@searxly.app](mailto:support@searxly.app)
    - Email (privacy & data requests only) — [privacy@searxly.app](mailto:privacy@searxly.app)
    - X — [@Searxly](https://x.com/Searxly)
    - Telegram channel — [t.me/searxlyapp](https://t.me/searxlyapp)
    - Telegram community — [t.me/searxlycom](https://t.me/searxlycom)
    - Discord — [discord.gg/YNNgTkNAXD](https://discord.gg/YNNgTkNAXD)
    - Source code — [github.com/searxly/Searxly-source-code](https://github.com/searxly/Searxly-source-code)

    ## 19. Changes
    If this policy changes, we'll update the date above and post material changes on our official channels. We'll keep it short and honest.
    """

    // MARK: - Terms of Service

    static let termsOfService = """
    > The short version: Searxly is a free tool we give you as-is. There are no accounts, your keys and your data are yours, and nothing here is financial advice. By downloading, installing, or using Searxly (the "app") or this website, you agree to these terms. If you don't agree, please don't use it.

    ## 1. What Searxly is
    Searxly is a private browser. On macOS it runs a search engine locally on your Mac and adds optional privacy tooling and an optional self-custody wallet; on iPhone & iPad it's a private-search browser that searches through our hosted instance. It's built to be private by architecture: no accounts, no telemetry, and most of what it does happens on your own device. How data is handled is described in our Privacy Policy, which forms part of these terms.

    ## 2. Your licence to use it
    The Searxly browser is provided free of charge for personal use, and we grant you a personal, non-exclusive, non-transferable licence to install and run it on your own devices. Searxly Maximum is a separate, paid edition sold under section 7, and its licence covers one Mac. In either case you may not resell it, remove or alter its notices, or misrepresent it as your own. Portions of Searxly are open source and governed by their own licences — for example the SearXNG search engine, provided under the GNU AGPL v3.0, whose source and our changes to it we publish and offer to you.

    ## 3. No accounts
    Using the browser and search requires no account, sign-up, or identification, and that is true of Searxly Maximum too — a licence key is not an account, and we never ask you to log in. Some optional extras (the paid Maximum edition, or the VPN) have their own additional terms in the sections below, which we make clear at the point you choose to use them. Maximum does check your licence key with us once, when you first activate it (section 7); after that it runs entirely offline.

    ## 4. The self-custody wallet (macOS)
    If you use the built-in wallet, it is fully self-custodial. This has real consequences you must understand and accept:
    - Your keys and recovery phrase are generated and stored on your device. We never receive, hold, or have any way to recover them.
    - If you lose your recovery phrase or device, or send funds to the wrong address, we can't reverse it or restore access. You are solely responsible for backing up your phrase and securing your device.
    - We don't custody funds, act as a broker or exchange, or ever take control of your assets or sign transactions on your behalf.
    - On-chain transactions are irreversible and may incur network fees outside our control.

    ## 5. Fees for on-chain features (macOS)
    In-app token swaps carry a small protocol fee — currently 0.65% — which is routed to the project treasury. It's collected on-chain as part of the swap (through the 0x settlement contract), with no separate transaction: the fee is a parameter on the quote your own 0x key fetches, so we collect it without ever handling, routing, or intermediating your trade. Blockchain network (gas) fees are separate and outside our control. The fee is shown in the swap screen before you confirm, and may change over time.

    ## 6. VPN (macOS)
    The optional managed VPN is provided as-is, with no uptime or service-level guarantee. Access may be gated by a pass or a promotional grant. You must use it lawfully. We operate it on a no-logs basis, but no VPN can guarantee anonymity, and we may refuse, suspend, or decline to renew access to prevent abuse or to comply with the law.

    **Buying a pass.** A VPN pass is a one-off, time-boxed purchase — there is no subscription and nothing auto-renews; you choose to buy again to extend. You can pay by card (processed by Stripe on its hosted checkout — Searxly never sees your card details) or in USDC from the in-app wallet. The price is shown before you confirm.

    **Right of withdrawal & refunds.** A VPN pass is digital content and services that we begin supplying immediately. By buying a pass you expressly ask us to start it straight away and you acknowledge that, once it is active, you lose the 14-day right of withdrawal that would otherwise apply to a distance sale (Article L.221-28 of the French Consumer Code).

    **When we do refund: a pass that doesn't work.** That's the one case. If a pass you paid for never activates, or can't connect because of a fault on our side, open a ticket at [support.searxly.app](https://support.searxly.app) and tell us what happened — what you saw, and roughly when. We'll check it against our delivery records (we keep a receipt of exactly when your access certificate was issued) and either re-issue your pass or refund you. A pass that was delivered and working isn't refundable.

    **Paying in crypto is final.** Crypto payments settle on a public blockchain: they are irreversible, and we cannot reverse, cancel, or charge one back. You are responsible for sending the correct asset (USDC) on the correct network (Base) to the address the app shows you. **If you send to a wrong address, on the wrong network, or the wrong amount, those funds never reach us — we don't receive them, we can't recover them, and there is nothing for us to refund.** Check carefully before you confirm. And once a crypto-paid pass has been delivered it is not refundable, since you asked for it to start immediately.

    **Consumer mediation.** If you are a consumer and a complaint you raised with us directly isn't resolved within a reasonable time, you may refer the dispute, free of charge, to the consumer mediator we are registered with (Article L.612-1 of the French Consumer Code): CM2C — Centre de la Médiation de la Consommation de Conciliateurs de Justice. File online at https://www.cm2c.net/declarer-un-litige.php, or by post to CM2C, 49 rue de Ponthieu, 75008 Paris (tel. 01 89 47 00 14 · litiges@cm2c.net). Mediation is only available after you've first sent us a written complaint that went unresolved, and within one year of that complaint.

    ## 7. Searxly Maximum (macOS)
    Searxly Maximum is a paid edition of the browser. It is a **one-time purchase — there is no subscription** and nothing auto-renews. The price is shown before you confirm, and you pay **by card** (processed by Stripe on its hosted checkout — Searxly never sees your card details). Maximum is not sold for crypto.

    **What you get.** A licence key, emailed to you as soon as your payment goes through. It **never expires**. It activates Maximum on **one Mac**: when you enter your key, the app ties the licence to that machine. Reinstalling macOS on the same Mac is fine — the same key still works, as many times as you need. Moving to a *different* Mac needs us to move the licence for you: open a ticket at support.searxly.app and we'll do it.

    **Activation.** Entering your key is the one moment Maximum contacts us: the app sends your key and a one-way fingerprint of your Mac's hardware ID, so we can tie the licence to it. It sends nothing about you or your browsing, and never contacts us again afterwards. See our Privacy Policy for exactly what we store and for how long.

    **Your key is yours.** The licence is personal to you. You may not resell, publish, or share your key, or use it on more Macs than you bought it for.

    **Right of withdrawal & refunds.** A licence key is digital content that we supply immediately. By buying Maximum you **expressly ask us to send your key straight away** and you acknowledge that, **once it has been sent, you lose the 14-day right of withdrawal** that would otherwise apply to a distance sale (Article L.221-28 of the French Consumer Code). You confirm both of these with a tick box before you pay.

    **When we do refund: a licence that doesn't work.** That's the one case. If you paid and never received your key, or it won't activate because of a fault on our side, open a ticket at support.searxly.app and tell us what happened — what you saw, and roughly when. We'll check it against our delivery records (we keep a receipt of exactly when your key was issued and emailed) and either re-send it or refund you. A licence that was delivered and activates isn't refundable.

    **Consumer mediation.** If you are a consumer and a complaint you raised with us directly isn't resolved within a reasonable time, you may refer the dispute, free of charge, to the consumer mediator we are registered with (Article L.612-1 of the French Consumer Code): **CM2C** — Centre de la Médiation de la Consommation de Conciliateurs de Justice. File online at cm2c.net/declarer-un-litige.php, or by post to CM2C, 49 rue de Ponthieu, 75008 Paris (tel. 01 89 47 00 14 · litiges@cm2c.net). Mediation is only available after you've first sent us a written complaint that went unresolved, and within one year of that complaint.

    ## 8. Nothing here is financial advice
    Searxly, this website, and any prices, charts, or coin information shown are provided for information only and are not financial, investment, legal, or tax advice. Searxly does not issue, promote, or endorse any token. Crypto assets are volatile and can lose value. Do your own research, and only use funds you can afford to lose. The availability and legality of crypto features vary by region — it's your responsibility to comply with the laws that apply to you.

    ## 9. Acceptable use
    Searxly is a general-purpose browser and you're responsible for how you use it. Don't use it to break the law, infringe others' rights, attack or disrupt services, or circumvent security you're not authorised to bypass. You are responsible for the sites you visit and the content you access.

    ## 10. Third-party services & content
    As a browser, Searxly connects you to third-party websites, search sources, price feeds, blockchain nodes, and other services. We don't control those, aren't responsible for their content or availability, and their own terms and privacy practices apply when you use them. Any third-party trademarks are the property of their respective owners and are used for identification only.

    ## 11. As-is, no warranty
    Searxly is provided "as is" and "as available", without warranties of any kind, whether express or implied, including fitness for a particular purpose, merchantability, or non-infringement. We work hard to make it private and reliable, but we don't guarantee it will be uninterrupted, error-free, or that it will meet your specific needs. Privacy and security tools reduce risk; no tool can make you perfectly anonymous or secure.

    ## 12. Limitation of liability
    To the maximum extent permitted by law, Searxly and its contributors are not liable for any indirect, incidental, or consequential damages, or for lost profits, lost data, or lost crypto assets, arising from your use of (or inability to use) the app or website. Because the app is free and self-custodial, you accept that you use it at your own risk.

    ## 13. Changes to the app or these terms
    We may update, change, or discontinue features at any time, and we may update these terms. When we make material changes, we'll update the date above and post notice on our official channels. Continuing to use Searxly after a change means you accept the updated terms.

    ## 14. Governing law
    These terms are governed by the laws of France, without regard to conflict-of-laws rules. If you're a consumer in the EU/EEA or the UK, you keep the mandatory protections of the law of your home country, and nothing here limits rights that can't be limited by law.

    ## 15. Contact & official channels
    Questions about these terms? Reach us here. These are the only official channels; anything else claiming to be Searxly isn't:
    - Support (anything about the app, your pass, or a problem) — [support.searxly.app](https://support.searxly.app), or email [support@searxly.app](mailto:support@searxly.app)
    - Privacy & data requests only — [privacy@searxly.app](mailto:privacy@searxly.app)
    - X — [@Searxly](https://x.com/Searxly)
    - Telegram channel — [t.me/searxlyapp](https://t.me/searxlyapp)
    - Telegram community — [t.me/searxlycom](https://t.me/searxlycom)
    - Discord — [discord.gg/YNNgTkNAXD](https://discord.gg/YNNgTkNAXD)
    - Source code — [github.com/searxly/Searxly-source-code](https://github.com/searxly/Searxly-source-code)
    """

    // MARK: - Lightweight Markdown parsing

    enum Block: Identifiable {
        case lead(String)       // "> " intro line, rendered as a quiet lead paragraph
        case heading(String)    // "## " section header
        case paragraph(String)
        case bullet(String)     // "- " list item

        var id: String {
            switch self {
            case .lead(let s):      return "l:\(s)"
            case .heading(let s):   return "h:\(s)"
            case .paragraph(let s): return "p:\(s)"
            case .bullet(let s):    return "b:\(s)"
            }
        }
    }

    /// Split the document into blocks. Each non-empty line is one block; blank lines are separators.
    static func parse(_ markdown: String) -> [Block] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("> ")  { return .lead(String(line.dropFirst(2))) }
            if line.hasPrefix("- ")  { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    /// Renders inline `**bold**` and `[text](url)` while degrading gracefully to plain text.
    static func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}

// MARK: - macOS renderer

/// Renders a `LegalDocuments` Markdown string in the Settings reading column.
struct LegalMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(LegalDocuments.parse(markdown)) { block in
                switch block {
                case .lead(let text):
                    LegalDocuments.inline(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)

                case .heading(let text):
                    Text(text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                        .padding(.top, 8)

                case .paragraph(let text):
                    LegalDocuments.inline(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(SettingsTheme.textTertiary)
                        LegalDocuments.inline(text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .tint(SettingsTheme.textPrimary)   // links render in ink, not system blue
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Legal settings pane

/// Settings ▸ Legal — the Privacy Policy and Terms of Service, read entirely offline.
struct LegalSettingsView: View {
    enum Doc: String, CaseIterable, Identifiable {
        case privacy = "Privacy Policy"
        case terms   = "Terms of Service"
        var id: String { rawValue }
    }

    @State private var doc: Doc = .privacy

    private var markdown: String {
        doc == .privacy ? LegalDocuments.privacyPolicy : LegalDocuments.termsOfService
    }

    private var onlineURL: URL {
        doc == .privacy ? LegalDocuments.privacyURL : LegalDocuments.termsURL
    }

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Legal",
                subtitle: "How Searxly handles your data, and the terms for using it. This is the same text published at searxly.app — kept in the app so you never need a network request to read it."
            )

            Picker("Document", selection: $doc) {
                ForEach(Doc.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Last updated: \(LegalDocuments.lastUpdated)")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textTertiary)
                Spacer(minLength: 8)
                Link(destination: onlineURL) {
                    HStack(spacing: 4) {
                        Text("View online")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsTheme.textSecondary)
            }

            LegalMarkdownView(markdown: markdown)
                .id(doc)   // reset scroll/animation state when switching documents
        }
    }
}
