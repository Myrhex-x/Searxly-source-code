//
//  LocalSearxngManager+Health
//  Searxly
//
//  Readiness + liveness probes for the native local SearXNG process.
//

import Foundation

extension LocalSearxngManager {

    /// True if the bundled SearXNG process (tracked by the helper's pidfile) is alive.
    /// Note: "alive" ≠ "serving" — use `isLocalWebReady()` for the definitive serving signal.
    func isSearxngProcessRunning() async -> Bool {
        await HelperClient.shared.proxy()?.isSearxngRunningAsync() ?? false
    }

    /// Does the SearXNG web server actually respond? This is the definitive readiness signal —
    /// the process can be alive while the Python app is still booting (10-30s on first start),
    /// during which searches would fail.
    func isLocalWebReady() async -> Bool {
        for base in localWebProbeURLs {
            guard let url = URL(string: base) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 4.0   // forgiving during slow first boot / Python startup
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...599).contains(http.statusCode) {
                    // Any HTTP response means the server is up and listening.
                    return true
                }
            } catch {
                // timeout, refused, TLS error, etc. → not ready yet
                continue
            }
        }
        return false
    }
}
