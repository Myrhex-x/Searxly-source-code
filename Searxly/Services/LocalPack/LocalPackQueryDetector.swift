//
//  LocalPackQueryDetector.swift
//  Searxly
//
//  Detects local place intent for the SERP local pack — a category or brand plus a place, e.g.
//  "pharmacie perpignan", "mcdonalds paris", "meilleur restaurant lyon". A bare place-strong trigger with
//  no city ("mcdonalds", "restaurant", "restaurant near me") resolves against the device location. Brands
//  and most categories may sit anywhere in the query; a set of ambiguous common words ("bank", "gym",
//  "bar", …) only fire when they lead, and never do the location ("near me") path, so they don't hijack
//  queries like "world bank" or nag on a bare "gym".
//

import Foundation

struct LocalPackQuery: Equatable {
    let category: String         // gateway enum, e.g. "pharmacy"
    let categoryLabel: String    // display label, e.g. "Pharmacies" / "McDonald’s"
    let area: String?            // the place/city text ("perpignan"); nil when using the device location
    let name: String?            // optional brand name filter for Overpass, e.g. "mcdonald"
    let useCurrentLocation: Bool // true for city-less queries ("mcdonalds", "restaurant near me")
}

enum LocalPackQueryDetector {

    // MARK: - Lexicons

    private struct Category {
        let triggers: [[String]]      // token sequences (accent-folded, lowercased)
        let enumValue: String
        let label: String
        var strictLeading = false     // only fire when it leads; never uses the location path
    }

    private struct Brand {
        let triggers: [[String]]
        let category: String          // must be a key in the gateway PLACE_CATEGORIES allowlist
        let label: String
        let name: String              // Overpass name~ filter (lowercased, punctuation-free)
    }

    private static let categories: [Category] = [
        Category(triggers: [["pharmacie"], ["pharmacies"], ["pharmacy"], ["drugstore"]], enumValue: "pharmacy", label: "Pharmacies"),
        Category(triggers: [["hopital"], ["hospital"], ["urgences"]], enumValue: "hospital", label: "Hospitals"),
        Category(triggers: [["medecin"], ["docteur"], ["doctor"]], enumValue: "doctor", label: "Doctors"),
        Category(triggers: [["dentiste"], ["dentist"]], enumValue: "dentist", label: "Dentists"),
        Category(triggers: [["veterinaire"], ["veterinarian"]], enumValue: "veterinary", label: "Vets"),
        Category(triggers: [["restaurant"], ["restaurants"], ["resto"]], enumValue: "restaurant", label: "Restaurants"),
        Category(triggers: [["fast", "food"], ["fastfood"]], enumValue: "fast_food", label: "Fast food"),
        Category(triggers: [["cafe"], ["coffee", "shop"], ["coffee"]], enumValue: "cafe", label: "Cafés"),
        Category(triggers: [["boulangerie"], ["bakery"]], enumValue: "bakery", label: "Bakeries"),
        Category(triggers: [["supermarche"], ["supermarket"], ["grocery"]], enumValue: "supermarket", label: "Supermarkets"),
        Category(triggers: [["superette"], ["convenience"]], enumValue: "convenience", label: "Convenience stores"),
        Category(triggers: [["coiffeur"], ["coiffeurs"], ["hairdresser"], ["barber"]], enumValue: "hairdresser", label: "Hair salons"),
        Category(triggers: [["fleuriste"], ["florist"]], enumValue: "florist", label: "Florists"),
        Category(triggers: [["librairie"], ["bookshop"], ["bookstore"]], enumValue: "books", label: "Bookshops"),
        Category(triggers: [["hotel"], ["hotels"]], enumValue: "hotel", label: "Hotels"),
        // Ambiguous common words — only when they lead the query, and never the location ("near me") path.
        Category(triggers: [["bar"], ["bars"], ["pub"], ["pubs"]], enumValue: "bar", label: "Bars", strictLeading: true),
        Category(triggers: [["banque"], ["bank"]], enumValue: "bank", label: "Banks", strictLeading: true),
        Category(triggers: [["distributeur"], ["atm"]], enumValue: "atm", label: "ATMs", strictLeading: true),
        Category(triggers: [["essence"], ["carburant"], ["fuel"], ["gas", "station"], ["station", "service"]], enumValue: "fuel", label: "Fuel stations", strictLeading: true),
        Category(triggers: [["parking"]], enumValue: "parking", label: "Parking", strictLeading: true),
        Category(triggers: [["cinema"], ["cinemas"]], enumValue: "cinema", label: "Cinemas", strictLeading: true),
        Category(triggers: [["gym"], ["fitness"]], enumValue: "gym", label: "Gyms", strictLeading: true),
        Category(triggers: [["bibliotheque"], ["library"]], enumValue: "library", label: "Libraries", strictLeading: true),
        Category(triggers: [["police"], ["commissariat"]], enumValue: "police", label: "Police", strictLeading: true),
        Category(triggers: [["poste"], ["post", "office"]], enumValue: "post_office", label: "Post offices", strictLeading: true),
    ]

    /// Common chains → their OSM category + a name filter, so "mcdonalds paris" finds McDonald's (not all
    /// fast food). Brand names are unambiguous, so they match anywhere and are eligible for the location path.
    private static let brands: [Brand] = [
        Brand(triggers: [["mcdonalds"], ["mcdonald"], ["mcdo"], ["macdo"]], category: "fast_food", label: "McDonald’s", name: "mcdonald"),
        Brand(triggers: [["burger", "king"]], category: "fast_food", label: "Burger King", name: "burger king"),
        Brand(triggers: [["kfc"]], category: "fast_food", label: "KFC", name: "kfc"),
        Brand(triggers: [["subway"]], category: "fast_food", label: "Subway", name: "subway"),
        Brand(triggers: [["dominos"], ["domino"]], category: "fast_food", label: "Domino’s", name: "domino"),
        Brand(triggers: [["starbucks"]], category: "cafe", label: "Starbucks", name: "starbucks"),
        Brand(triggers: [["carrefour"]], category: "supermarket", label: "Carrefour", name: "carrefour"),
        Brand(triggers: [["auchan"]], category: "supermarket", label: "Auchan", name: "auchan"),
        Brand(triggers: [["lidl"]], category: "supermarket", label: "Lidl", name: "lidl"),
        Brand(triggers: [["aldi"]], category: "supermarket", label: "Aldi", name: "aldi"),
        Brand(triggers: [["leclerc"]], category: "supermarket", label: "Leclerc", name: "leclerc"),
        Brand(triggers: [["monoprix"]], category: "supermarket", label: "Monoprix", name: "monoprix"),
        Brand(triggers: [["franprix"]], category: "supermarket", label: "Franprix", name: "franprix"),
        Brand(triggers: [["intermarche"]], category: "supermarket", label: "Intermarché", name: "intermarche"),
    ]

    /// Connectives dropped between the trigger and the place ("à", "de", "in", "near", …).
    private static let stopwords: Set<String> = [
        "a", "au", "aux", "de", "du", "des", "d", "en", "dans", "sur",
        "pres", "proche", "near", "in", "at", "the", "la", "le", "les", "l",
        "autour", "around", "of", "to"
    ]

    /// "near me" style words — leftover that is only these means a location ("near me") search.
    private static let nearMe: Set<String> = ["moi", "me", "ici", "here", "myself", "us"]

    // MARK: - Detection

    static func detect(_ rawQuery: String) -> LocalPackQuery? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeURL(trimmed) else { return nil }

        let folded = trimmed
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard (1...7).contains(tokens.count) else { return nil }

        // Brand first (more specific), then generic category.
        if let (brand, range) = matchBrand(in: tokens) {
            return build(category: brand.category, label: brand.label, name: brand.name,
                         nearMeOK: true, tokens: tokens, range: range)
        }
        if let (category, range) = matchCategory(in: tokens) {
            return build(category: category.enumValue, label: category.label, name: nil,
                         nearMeOK: !category.strictLeading, tokens: tokens, range: range)
        }
        return nil
    }

    /// Builds a query from a matched trigger. If an explicit place trails (or precedes) the trigger, it's a
    /// city query; if nothing meaningful is left (or only "near me" words), it's a city-less query that
    /// uses the device location — but only for triggers eligible for that (`nearMeOK`).
    private static func build(category: String, label: String, name: String?, nearMeOK: Bool,
                              tokens: [String], range: Range<Int>) -> LocalPackQuery? {
        let after = tokens[range.upperBound...].filter { !stopwords.contains($0) }
        let before = tokens[..<range.lowerBound].filter { !stopwords.contains($0) }
        let picked = Array(after.isEmpty ? before : after)
        let cityless = picked.isEmpty || picked.allSatisfy { nearMe.contains($0) }

        if !cityless {
            let area = picked.joined(separator: " ")
            guard area.count >= 2 else { return nil }
            return LocalPackQuery(category: category, categoryLabel: label, area: area, name: name, useCurrentLocation: false)
        }
        guard nearMeOK else { return nil }
        return LocalPackQuery(category: category, categoryLabel: label, area: nil, name: name, useCurrentLocation: true)
    }

    // MARK: - Matching

    private static func matchBrand(in tokens: [String]) -> (Brand, Range<Int>)? {
        var best: (Brand, Range<Int>)?
        for brand in brands {
            guard let range = locate(brand.triggers, in: tokens) else { continue }
            if best == nil || range.lowerBound < best!.1.lowerBound { best = (brand, range) }
        }
        return best
    }

    private static func matchCategory(in tokens: [String]) -> (Category, Range<Int>)? {
        var best: (Category, Range<Int>)?
        for category in categories {
            guard let range = locate(category.triggers, in: tokens) else { continue }
            if category.strictLeading && range.lowerBound != 0 { continue }
            if best == nil || range.lowerBound < best!.1.lowerBound { best = (category, range) }
        }
        return best
    }

    /// Earliest (then longest) position where any trigger phrase matches as a whole-token subsequence.
    private static func locate(_ triggers: [[String]], in tokens: [String]) -> Range<Int>? {
        var best: Range<Int>?
        for start in tokens.indices {
            for phrase in triggers where start + phrase.count <= tokens.count {
                guard Array(tokens[start..<start + phrase.count]) == phrase else { continue }
                let range = start..<(start + phrase.count)
                if best == nil || range.lowerBound < best!.lowerBound
                    || (range.lowerBound == best!.lowerBound && range.count > best!.count) {
                    best = range
                }
            }
        }
        return best
    }

    private static func looksLikeURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.contains(".") && !lower.contains(" ") { return true }
        return false
    }
}
