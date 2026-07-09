//
//  WebPageFetcher.swift
//  Searxly
//
//  Lightweight, privacy-aware "read this page in full" helper for the cloud agent tools.
//  Used by the fetch_url and deep_research CloudTools so the model can go beyond the
//  short SearXNG snippets and reason over the real, readable text of a page.
//
//  Design notes:
//  - http(s) only, with an SSRF guard that blocks localhost / private / link-local hosts so the
//    model can never be steered into fetching the user's own SearXNG admin, router, or cloud
//    metadata endpoints.
//  - Best-effort HTML → plain text (drops <script>/<style>, unwraps tags, decodes a few entities)
//    without NSAttributedString (which is main-thread-bound and unsafe on untrusted markup).
//  - Output is capped and run through PageContentGuard.sanitize so prompt-injection markers in the
//    page can't hijack the model. Same defense the "Summarize Page" path already uses.
//

import Foundation

enum WebPageFetcher {

    struct FetchedPage: Sendable {
        let url: String
        let title: String
        let text: String
    }

    /// Fetch a single URL and return its readable text (capped). Returns nil on any failure
    /// (bad URL, blocked host, non-HTML, network error, empty body).
    static func fetchReadable(urlString: String, maxChars: Int = 6_000, timeout: TimeInterval = 12) async -> FetchedPage? {
        guard let url = sanitizedURL(from: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Searxly/1.0 (macOS; +https://github.com/searxly/Searxly)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        do {
            // Anonymous fetch (a public page URL) — rides Tor in Maximum Privacy, fail-closed otherwise.
            // The SSRF guard above still applies on both lanes (incl. keeping .onion off-limits).
            guard let lane = await TorLane.current() else { return nil }

            // Direct (non-Tor) lane: also reject a HOSTNAME that resolves to an internal address
            // (DNS-based SSRF, e.g. attacker.com → 127.0.0.1). This does a real DNS lookup, so it's
            // done ONLY off the Tor lane: over Tor the resolve happens at the exit (a local lookup would
            // leak the hostname from the real IP, defeating the mode) and private IPs aren't routable
            // through a Tor exit anyway. Run off the cooperative pool since getaddrinfo blocks.
            if !lane.viaTor {
                let host = url.host ?? ""
                let resolvesInternal = await Task.detached(priority: .utility) {
                    WebPageFetcher.hostHasBlockedAddress(host, allowDNS: true)
                }.value
                if resolvesInternal { return nil }
            }

            let (data, response) = try await lane.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // Only readable text formats. Skip PDFs, images, binaries, JSON dumps, etc.
            guard contentType.isEmpty
                    || contentType.contains("text/html")
                    || contentType.contains("application/xhtml")
                    || contentType.contains("text/plain") else { return nil }

            // Cap the raw bytes we decode so a giant page can't blow up memory or the prompt.
            let capped = data.prefix(1_500_000)
            guard let raw = String(data: capped, encoding: .utf8)
                    ?? String(data: capped, encoding: .isoLatin1) else { return nil }

            let title = extractTitle(from: raw) ?? (url.host ?? url.absoluteString)
            let stripped = htmlToPlainText(raw)
            let clean = PageContentGuard.sanitize(stripped, limit: maxChars)
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return FetchedPage(url: url.absoluteString, title: title, text: clean)
        } catch {
            return nil
        }
    }

    // MARK: - SSRF guard

    /// Returns a usable URL only for public http(s) destinations. Blocks schemes other than http/https
    /// and hosts that are loopback, private-range, link-local, or `.local`/`.onion` so the agent can't be
    /// tricked into hitting internal services.
    static func sanitizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }

        // Named special-cases that aren't numeric literals (getaddrinfo/AI_NUMERICHOST won't resolve these).
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".onion") { return nil }

        // Reject any IP LITERAL that lands in a loopback/private/link-local/metadata range. Resolving via
        // getaddrinfo(AI_NUMERICHOST) is pure local parsing (NO DNS, no network, nothing leaked), so every
        // literal encoding normalizes to the exact address the OS would dial and gets classified the same
        // way: dotted-quad (127.0.0.1), decimal (2130706433), hex (0x7f000001), octal (017700000001),
        // short-form (127.1), IPv6 (::1, fd00::1) and IPv4-mapped IPv6 (::ffff:127.0.0.1) all collapse.
        // This closes the encoded-IP SSRF bypasses the old dotted-quad-only check missed. A hostname that
        // resolves to a private IP over DNS is handled separately on the direct lane in fetchReadable —
        // doing a DNS lookup here would leak it from the real IP in Maximum Privacy.
        if hostHasBlockedAddress(host, allowDNS: false) { return nil }

        return url
    }

    /// True if `host` resolves to (or is a literal for) a loopback/private/link-local/CGNAT/metadata
    /// address. With `allowDNS == false` the resolve is numeric-only (`AI_NUMERICHOST` → no DNS traffic):
    /// it classifies IP literals in every encoding but returns `false` for a real hostname (nothing to
    /// classify without a lookup). With `allowDNS == true` it performs a normal DNS resolution and
    /// classifies every returned address — used only on the direct lane to catch DNS-based SSRF.
    nonisolated static func hostHasBlockedAddress(_ host: String, allowDNS: Bool) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = allowDNS ? 0 : AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else { return false }
        defer { freeaddrinfo(res) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        while let cur = node {
            if let sa = cur.pointee.ai_addr {
                if cur.pointee.ai_family == AF_INET {
                    let blocked = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        isBlockedIPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                    }
                    if blocked { return true }
                } else if cur.pointee.ai_family == AF_INET6 {
                    var addr6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: &addr6) { Array($0.bindMemory(to: UInt8.self)) }
                    if isBlockedIPv6(bytes) { return true }
                }
            }
            node = cur.pointee.ai_next
        }
        return false
    }

    /// Classifies a host-order IPv4 address against the standard SSRF blocklist (RFC 1918 private,
    /// loopback, link-local incl. the 169.254.169.254 cloud-metadata endpoint, CGNAT, unspecified,
    /// benchmarking, multicast and reserved space).
    nonisolated static func isBlockedIPv4(_ addr: UInt32) -> Bool {
        func inRange(_ base: UInt32, _ prefix: UInt32) -> Bool {
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            return (addr & mask) == (base & mask)
        }
        return inRange(0x0000_0000, 8)    // 0.0.0.0/8      "this" network / unspecified
            || inRange(0x0A00_0000, 8)    // 10.0.0.0/8     private
            || inRange(0x6440_0000, 10)   // 100.64.0.0/10  CGNAT
            || inRange(0x7F00_0000, 8)    // 127.0.0.0/8    loopback
            || inRange(0xA9FE_0000, 16)   // 169.254.0.0/16 link-local + cloud metadata
            || inRange(0xAC10_0000, 12)   // 172.16.0.0/12  private
            || inRange(0xC000_0000, 24)   // 192.0.0.0/24   IETF protocol assignments
            || inRange(0xC0A8_0000, 16)   // 192.168.0.0/16 private
            || inRange(0xC612_0000, 15)   // 198.18.0.0/15  benchmarking
            || inRange(0xE000_0000, 4)    // 224.0.0.0/4    multicast
            || inRange(0xF000_0000, 4)    // 240.0.0.0/4    reserved / broadcast
    }

    /// Classifies a 16-byte IPv6 address: unspecified `::`, loopback `::1`, ULA `fc00::/7`, link-local
    /// `fe80::/10`, multicast `ff00::/8`, and IPv4-mapped `::ffff:a.b.c.d` (the embedded v4 is classified
    /// with the IPv4 rules, so `::ffff:127.0.0.1` is blocked too).
    nonisolated static func isBlockedIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) { return true }                                   // ::            unspecified
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }             // ::1           loopback
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {       // ::ffff:0:0/96 IPv4-mapped
            let v4 = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 8) | UInt32(b[15])
            return isBlockedIPv4(v4)
        }
        if (b[0] & 0xFE) == 0xFC { return true }                                       // fc00::/7      unique-local
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                       // fe80::/10     link-local
        if b[0] == 0xFF { return true }                                                // ff00::/8      multicast
        return false
    }

    // MARK: - HTML → text

    private static func extractTitle(from html: String) -> String? {
        guard let match = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = String(html[match])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : String(decoded.prefix(160))
    }

    /// Crude but robust readable-text extraction. Removes non-content blocks, unwraps remaining tags,
    /// decodes common entities, and collapses whitespace.
    static func htmlToPlainText(_ html: String) -> String {
        var s = html
        // Drop blocks whose contents are never readable prose.
        for tag in ["script", "style", "noscript", "template", "svg", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>",
                                       with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Turn block-level boundaries into newlines so paragraphs don't run together.
        s = s.replacingOccurrences(of: "</(p|div|section|article|li|h[1-6]|br|tr)>",
                                   with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        // Strip all remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        // Collapse runs of spaces/tabs and excessive blank lines.
        s = s.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n[ \\n]+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
                   "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                   "&ldquo;": "“", "&rdquo;": "”"]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}
