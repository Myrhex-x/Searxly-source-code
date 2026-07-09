//
//  LocalPackMapView.swift
//  Searxly
//
//  The map surface for the SERP local pack. An MKMapView (via NSViewRepresentable) showing Apple's native
//  map with numbered ink pins matching the list. The place DATA stays private (fetched via the gateway),
//  but the map picture is drawn by Apple — so the whole feature is opt-in and blocked in Maximum Privacy.
//

import SwiftUI
import MapKit

// MARK: - Annotation

final class NumberedPlaceAnnotation: NSObject, MKAnnotation {
    nonisolated let index: Int
    nonisolated let coordinate: CLLocationCoordinate2D
    nonisolated let title: String?

    nonisolated init(index: Int, coordinate: CLLocationCoordinate2D, title: String?) {
        self.index = index
        self.coordinate = coordinate
        self.title = title
    }
}

// MARK: - Map view

struct LocalPackMapView: NSViewRepresentable {
    let places: [LocalPlace]
    let center: LocalCoordinate?

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsZoomControls = true
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll     // keep it clean; our numbered pins are the content
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let annotations = places.prefix(12).enumerated().map { index, place in
            NumberedPlaceAnnotation(
                index: index + 1,
                coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
                title: place.name
            )
        }
        // Only rebuild when the set actually changed (updateNSView can fire for unrelated reasons).
        let existing = map.annotations.compactMap { ($0 as? NumberedPlaceAnnotation)?.id }
        guard existing != annotations.map(\.id) else { return }

        map.removeAnnotations(map.annotations)
        map.addAnnotations(annotations)

        if annotations.count == 1, let only = annotations.first {
            map.setRegion(
                MKCoordinateRegion(center: only.coordinate, latitudinalMeters: 1400, longitudinalMeters: 1400),
                animated: false
            )
        } else if !annotations.isEmpty {
            map.showAnnotations(annotations, animated: false)
        } else if let center {
            map.setRegion(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
                    latitudinalMeters: 3000, longitudinalMeters: 3000
                ),
                animated: false
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let place = annotation as? NumberedPlaceAnnotation else { return nil }
            let id = "numberedPlace"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.glyphText = "\(place.index)"
            view.markerTintColor = .labelColor                 // ink pin — monochrome, adaptive
            view.glyphTintColor = .windowBackgroundColor       // number contrasts against the pin
            view.displayPriority = .required
            view.animatesWhenAdded = false
            return view
        }
    }
}

private extension NumberedPlaceAnnotation {
    nonisolated var id: String { "\(index)|\(coordinate.latitude)|\(coordinate.longitude)" }
}
