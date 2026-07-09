//
//  LocalPackView.swift
//  Searxly
//
//  The Google-style "local pack" that sits at the top of web results for place queries (e.g.
//  "pharmacie perpignan"): a numbered list of OpenStreetMap places beside a live map. All data + tiles
//  arrive via the Searxly gateway, so nothing here touches Apple or exposes the user. Monochrome to match
//  the brand — green is reserved for the "Open" status only.
//

import SwiftUI

struct LocalPackView: View {
    let data: LocalPackData
    let glassEnabled: Bool
    let onOpenURL: (String) -> Void

    /// Google-style compact pack: the few nearest places lead; the rest live behind "View all".
    private var displayed: [LocalPlace] { Array(data.places.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.15).padding(.top, 10)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    listColumn
                    mapColumn(width: 236, height: 236)
                }
                VStack(alignment: .leading, spacing: 14) {
                    mapColumn(width: nil, height: 170)
                    listColumn
                }
            }
            .padding(.top, 12)
            footer
        }
        .padding(14)
        .frame(maxWidth: SERPDesign.maxListWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .searxlyFloatingPanel()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(Localization.string("local_pack_places", defaultValue: "Places"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
            Text("· \(data.query)")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, place in
                if index > 0 {
                    Divider().opacity(0.12)
                }
                row(index: index + 1, place: place)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(index: Int, place: LocalPlace) -> some View {
        Button {
            if let osmUrl = place.osmUrl { onOpenURL(osmUrl) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                numberBadge(index)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    statusLine(place)
                    if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 3)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusLine(_ place: LocalPlace) -> some View {
        switch OpeningHoursEvaluator.evaluate(place.hours ?? "") {
        case .open(let closesAt):
            metaRow {
                Text(Localization.string("local_pack_open", defaultValue: "Open"))
                    .foregroundStyle(SERPDesign.accentGreen)
                if let closesAt {
                    Text("· " + String(format: Localization.string("local_pack_closes", defaultValue: "closes %@"), closesAt))
                        .foregroundStyle(.secondary)
                }
            }
        case .closed(let opensAt):
            metaRow {
                Text(Localization.string("local_pack_closed", defaultValue: "Closed"))
                    .foregroundStyle(.secondary)
                if let opensAt {
                    Text("· " + String(format: Localization.string("local_pack_opens", defaultValue: "opens %@"), opensAt))
                        .foregroundStyle(.tertiary)
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    private func metaRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4, content: content)
            .font(.system(size: 12.5))
    }

    private func numberBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary))
    }

    // MARK: - Map

    @ViewBuilder
    private func mapColumn(width: CGFloat?, height: CGFloat) -> some View {
        LocalPackMapView(places: displayed, center: data.center)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : width)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(Localization.string("local_pack_attribution", defaultValue: "Results from OpenStreetMap"))
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
            Spacer(minLength: 4)
            if let mapURL = openStreetMapURL {
                Button {
                    onOpenURL(mapURL)
                } label: {
                    HStack(spacing: 5) {
                        Text(
                            data.places.count > displayed.count
                                ? String(format: Localization.string("local_pack_view_all", defaultValue: "View all %d on the map"), data.places.count)
                                : Localization.string("local_pack_open_map", defaultValue: "Open in OpenStreetMap")
                        )
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
    }

    /// A public OSM map link centered on the resolved area (opens in a tab on tap).
    private var openStreetMapURL: String? {
        guard let center = data.center else { return nil }
        return String(format: "https://www.openstreetmap.org/#map=14/%.5f/%.5f", center.lat, center.lon)
    }
}
