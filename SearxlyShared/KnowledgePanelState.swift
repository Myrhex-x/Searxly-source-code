//
//  KnowledgePanelState.swift
//  Searxly
//
//  Models for the SERP right-column knowledge panel (Grokipedia-only).
//

import Foundation

enum KnowledgePanelDisplayState: Equatable {
    case hidden
    case loading(query: String)
    case ready(KnowledgePanelContent)
}

struct KnowledgePanelContent: Equatable {
    let query: String
    let kind: KnowledgePanelKind
}

enum KnowledgePanelKind: Equatable {
    case entity(EntityPanelData)
}

struct EntityPanelData: Equatable {
    let title: String
    let aboutParagraphs: [String]
    let entityKind: OfficialEntityDatabase.EntityKind?
    let officialSiteURL: String?
    let officialSiteLabel: String?
    let grokipediaURL: String?
    /// Ordered banner image candidates (tried in order on load failure). Sourced from Grokipedia's own
    /// article image when available, otherwise from a SearXNG image search as a fallback.
    let bannerImageCandidates: [URL]
    /// HTTP referer to send when loading the banner (Grokipedia for its own images; the source page URL
    /// for SearXNG-resolved images, matching how the SERP image grid loads hotlink-protected thumbnails).
    let bannerImageReferer: String?
    let facts: [KnowledgeFact]
}

struct KnowledgeFact: Equatable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
}