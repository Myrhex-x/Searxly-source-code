//
//  LocalPlacesResolver.swift
//  Searxly
//
//  Resolves a LocalPackQuery to OpenStreetMap places via the Searxly gateway (/places), which geocodes
//  the city and runs the Overpass POI query server-side — so the OSM servers only ever see the gateway,
//  never the user. Returns nil (no pack) when the gateway is unconfigured, the request fails, or no
//  places come back.
//

import Foundation
import CoreLocation

struct LocalCoordinate: Decodable, Equatable {
    let lat: Double
    let lon: Double
}

struct LocalPlace: Decodable, Equatable, Identifiable {
    let name: String
    let lat: Double
    let lon: Double
    let category: String?
    let address: String?
    let hours: String?
    let phone: String?
    let website: String?
    let osmUrl: String?

    var id: String { osmUrl ?? "\(name)|\(lat)|\(lon)" }
}

/// The resolved local-pack payload handed to the view.
struct LocalPackData: Equatable {
    let query: String          // the original user query (SERP header context)
    let categoryLabel: String  // e.g. "Pharmacies"
    let area: String           // display area (gateway's resolved name, else the typed city)
    let center: LocalCoordinate?
    let places: [LocalPlace]
}

enum LocalPackDisplayState: Equatable {
    case hidden
    /// A place query was detected but the feature is off — offer to enable it (opt-in prompt).
    case prompt(LocalPackQuery)
    case loading
    case ready(LocalPackData)
}

enum LocalPlacesResolver {

    private struct PlacesResponse: Decodable {
        let area: String?
        let center: LocalCoordinate?
        let places: [LocalPlace]
    }

    static func resolve(query userQuery: String, detected: LocalPackQuery) async -> LocalPackData? {
        guard SearxlyGateway.isConfigured else { return nil }

        // Resolve WHERE to search: an explicit city, or the device's (coarse, rounded) location.
        let scope: [URLQueryItem]
        if detected.useCurrentLocation {
            guard let coord = await LocationProvider.shared.currentCoordinate() else { return nil }
            let lat = (coord.latitude * 1000).rounded() / 1000     // ~110 m — coarse on purpose
            let lon = (coord.longitude * 1000).rounded() / 1000
            scope = [URLQueryItem(name: "lat", value: String(lat)), URLQueryItem(name: "lon", value: String(lon))]
        } else if let area = detected.area {
            scope = [URLQueryItem(name: "area", value: area)]
        } else {
            return nil
        }

        guard let url = placesURL(category: detected.category, name: detected.name, scope: scope) else { return nil }

        let response: PlacesResponse
        if let hit = cachedResponse(for: url) {
            response = hit
        } else {
            guard let fetched = await fetch(url) else { return nil }
            storeResponse(fetched, for: url)
            response = fetched
        }

        guard !response.places.isEmpty else { return nil }
        return LocalPackData(
            query: userQuery,
            categoryLabel: detected.categoryLabel,
            area: response.area ?? detected.area ?? "Nearby",
            center: response.center,
            places: response.places
        )
    }

    private static func placesURL(category: String, name: String?, scope: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: SearxlyGateway.placesBase) else { return nil }
        var items = [URLQueryItem(name: "cat", value: category)] + scope
        if let name, !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: name))   // brand filter (e.g. mcdonald)
        }
        comps.queryItems = items
        return comps.url
    }

    private static func fetch(_ url: URL) async -> PlacesResponse? {
        var request = URLRequest(url: url)
        request.setValue(SearxlyGateway.bearer, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(PlacesResponse.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Client cache
    // The gateway already caches; this just avoids a refetch when the user toggles categories/tabs and
    // comes back to the same query within the TTL. Empty responses are cached too (no-pack is stable).

    private struct Entry { let response: PlacesResponse; let at: Date }
    private static var cache: [String: Entry] = [:]
    private static let cacheLock = NSLock()
    private static let ttl: TimeInterval = 10 * 60

    private static func cachedResponse(for url: URL) -> PlacesResponse? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let entry = cache[url.absoluteString] else { return nil }
        if Date().timeIntervalSince(entry.at) > ttl {
            cache.removeValue(forKey: url.absoluteString)
            return nil
        }
        return entry.response
    }

    private static func storeResponse(_ response: PlacesResponse, for url: URL) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache.count > 64, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[url.absoluteString] = Entry(response: response, at: Date())
    }
}
