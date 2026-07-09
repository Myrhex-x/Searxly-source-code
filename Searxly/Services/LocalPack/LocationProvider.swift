//
//  LocationProvider.swift
//  Searxly
//
//  One-shot, coarse device location for city-less local-pack queries ("mcdonalds", "restaurant near me").
//  Only ever called after the user opts into the local pack. Returns a single rounded coordinate and
//  nothing else — no tracking, no continuous updates. nil whenever location is denied or unavailable.
//

import Foundation
import CoreLocation

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // city-scale search — coarse is plenty
    }

    /// Ensures authorization, then resolves to a single coordinate (nil if denied / unavailable). Safe to
    /// call repeatedly; a second call while one is in flight just returns nil.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        guard continuation == nil else { return nil }

        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        default:
            return await withCheckedContinuation { cont in
                self.continuation = cont
                switch manager.authorizationStatus {
                case .authorizedAlways:
                    manager.requestLocation()
                case .notDetermined:
                    manager.requestWhenInUseAuthorization()   // resolves via didChangeAuthorization
                default:
                    finish(nil)
                }
            }
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    private func handleAuthorizationChange() {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break   // still .notDetermined — wait for the user's choice
        }
    }

    // MARK: - CLLocationManagerDelegate (delivered off the MainActor; hop back on)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.handleAuthorizationChange() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let lat = locations.last?.coordinate.latitude
        let lon = locations.last?.coordinate.longitude
        Task { @MainActor in
            if let lat, let lon { self.finish(CLLocationCoordinate2D(latitude: lat, longitude: lon)) }
            else { self.finish(nil) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
