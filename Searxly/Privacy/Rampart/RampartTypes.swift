//
//  RampartTypes.swift
//  Searxly
//
//  Native Swift port of National Design Studio's "Rampart" PII redactor
//  (CC BY 4.0 — github.com/nationaldesignstudio/rampart). Shared value types.
//
//  Rampart strips personally identifiable information from user-typed text *before*
//  it leaves the Mac, then restores it in the model's reply. In Searxly this guards
//  exactly one surface: prompts sent to the Searxly AI *cloud* backend. On-device
//  providers (Apple Intelligence, local Ollama) never egress and are not touched.
//
//  Parity note: offsets are UTF-16 code-unit indices to mirror the upstream
//  TypeScript implementation (JS string offsets) byte-for-byte, which keeps the
//  port verifiable against the reference and lets `NSRegularExpression` ranges map
//  in directly.
//

import Foundation

/// Every entity class the heuristics and the NER model can emit — the exact union
/// from Rampart's `types.ts`. The raw value is used verbatim inside placeholders
/// (`.email` → `[EMAIL_1]`) and as the model's `id2label` base name.
nonisolated enum RampartEntity: String, CaseIterable {
    // Structured — heuristic-detectable, premasked before the model runs.
    case ssn         = "SSN"
    case creditCard  = "CREDIT_CARD"
    case ipAddress   = "IP_ADDRESS"
    // Contextual — NER model fine set.
    case givenName       = "GIVEN_NAME"
    case surname         = "SURNAME"
    case email           = "EMAIL"
    case phone           = "PHONE"
    case url             = "URL"
    case taxId           = "TAX_ID"
    case bankAccount     = "BANK_ACCOUNT"
    case routingNumber   = "ROUTING_NUMBER"
    case governmentId    = "GOVERNMENT_ID"
    case passport        = "PASSPORT"
    case driversLicense  = "DRIVERS_LICENSE"
    // Address components — NER.
    case buildingNumber   = "BUILDING_NUMBER"
    case streetName       = "STREET_NAME"
    case secondaryAddress = "SECONDARY_ADDRESS"
    case city             = "CITY"
    case state            = "STATE"
    case zipCode          = "ZIP_CODE"

    /// Default-deny keep-set: broad geography is classified but intentionally retained
    /// (the model can reason about *where* without learning the precise street line).
    static let defaultKeep: Set<String> = [
        RampartEntity.city.rawValue, RampartEntity.state.rawValue, RampartEntity.zipCode.rawValue,
    ]
}

/// Which layer produced a span. Heuristics are validator-backed (score 1) and win
/// merge tie-breaks against the model.
nonisolated enum RampartSource: Equatable {
    case heuristic
    case ner
}

/// A detected entity span over the *original* text, in UTF-16 offsets.
nonisolated struct RampartDetection: Equatable {
    /// Inclusive start offset (UTF-16) into the raw input.
    let start: Int
    /// Exclusive end offset (UTF-16) into the raw input.
    let end: Int
    /// Entity type, e.g. "EMAIL" / "GIVEN_NAME" — becomes the placeholder prefix.
    let label: String
    /// Detector confidence in [0, 1]. Heuristics report 1.
    let score: Float
    /// Layer that produced this span.
    let source: RampartSource
    /// The raw substring covered, kept for placeholder rehydration.
    let text: String

    var length: Int { end - start }
}
