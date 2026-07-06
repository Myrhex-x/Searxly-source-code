//
//  OfficialEntityDatabase.swift
//  Searxly
//
//  The authoritative, local, auditable "pre-known" Official Entity Database for the Searxly Agent
//  `open_website` resolution (SiteResolver + BrowserState).
//
//  This is the "huge improvement" data layer: a maintainable, open-source-style list of entities,
//  brands, projects, facilities, people/orgs, and special pages mapped to their canonical official
//  primary URLs.
//
//  Philosophy (per user request for "pre-known prompts like something open source"):
//  - Everything is 100% bundled + offline. No runtime network, no external APIs.
//  - Single source of truth. Easy for humans to audit, extend, and PR (big commented sections).
//  - Prioritizes high-signal, high-confidence official homepages and well-known project sites.
//  - Supports natural-language user phrasing via rich aliases + smart normalization in callers.
//  - "Terafab" (https://terafab.ai) and all related Memphis/xAI/Tesla chip facility phrasing is
//    first-class so "open elon musk's chip facility website" and "open terafab" etc. resolve
//    correctly instead of news sites like teslarati.com.
//
//  Seeding:
//  - Migrated + expanded from the previous inline trustedMap in SiteResolver.swift (v3.2).
//  - Cross-seeded from SuggestionProvider.staticSuggestions for consistency.
//  - Added deep coverage for the xAI / Tesla / SpaceX / Neuralink family, current real-world
//    facilities & projects (Terafab, Memphis Supercluster / Colossus, etc.), dev tools, AI labs,
//    Wikipedia/GitHub/X special handling seeds, and common "open the official ..." requests.
//  - All entries are conservative and high-confidence. No user data, no unverified sites.
//
//  Usage:
//  - SiteResolver calls into this for trustedURL(for:) fast path and to enrich scoring.
//  - BrowserState.openWebsite uses resolutionQuery(for:) for smarter SearXNG fallbacks.
//  - The DB also exports a legacy-style trustedMap() for easy migration and authorityHosts().
//
//  Extension guide (add here):
//  - Prefer root or very short-path official homepages.
//  - For projects/facilities without a dedicated domain, use the owning company's canonical
//    (or the specific announced site, e.g. terafab.ai).
//  - Always add multiple natural aliases: possessives, "elon musk's X", "official X site",
//    shorthand, previous names, "chip facility", "supercluster", etc.
//  - Set authorityHost for scoring boosts in SiteResolver (e.g. "terafab.ai", "x.ai").
//  - Add a short note explaining why this entry exists (especially for facilities like Terafab).
//
//  Version this file when the dataset changes significantly. Record in LOCAL_AI_IMPLEMENTATION_NOTES.md.
//
//  TEST CASES (exact phrases that must resolve correctly via map or high-authority scorer):
//  - "open elon musk's chip facility website"  → https://terafab.ai (primary)
//  - "open terafab"                            → https://terafab.ai
//  - "go to xAI Memphis supercluster"          → https://terafab.ai  (or https://x.ai)
//  - "visit the official Tesla Terafab site"   → https://terafab.ai  (or https://tesla.com)
//  - "open elon musk terafab chip fab"         → https://terafab.ai
//  - "take me to the xai memphis site"         → https://terafab.ai / https://x.ai
//  - "open the wikipedia page for elon musk"   → https://en.wikipedia.org/wiki/Elon_Musk (special handling)
//  - "open X", "go to twitter", "visit the platform formerly known as twitter" → https://x.com
//  - All previous common brands must continue to work perfectly.
//

import Foundation

public enum OfficialEntityDatabase {

    // MARK: - Version

    public static let entityDBVersion = "v1.0-2026-06-terafab-ai-official"

    // MARK: - Core Data Model

    public enum EntityKind: String, Sendable {
        case company
        case person
        case organization
        case product
        case place
        case website
    }

    public struct OfficialEntity: Sendable {
        /// Primary lookup key (normalized, lower, no fluff). Used for exact + fuzzy.
        public let canonicalKey: String
        /// The URL we should open for this entity (the "official website").
        public let primaryURL: String
        /// Many natural-language aliases that should map here (possessives, descriptive, shorthand).
        public let aliases: [String]
        /// Preferred host for authority/relevance boosting in the scorer (e.g. "x.ai", "terafab.ai").
        public let authorityHost: String?
        /// Offline Grokipedia slug hint for the SERP knowledge panel (e.g. "YouTube", "Elon_Musk").
        public let grokipediaSlug: String?
        /// Entity classification for knowledge-panel layout (company vs person, etc.).
        public let entityKind: EntityKind?
        /// Simple Icons slug for offline bundled brand logo (Resources/BrandIcons/*.svg).
        public let brandIconSlug: String?
        /// Wikidata QID for offline knowledge-panel copy (Resources/WikidataEntities/entities.json).
        public let wikidataQID: String?
        /// Bundled celebrity face slug (Resources/CelebrityFaces/*), CelebA/FIR-style offline portraits.
        public let celebrityFaceSlug: String?
        /// Short human-readable note for auditors / future maintainers.
        public let notes: String?

        public init(
            canonicalKey: String,
            primaryURL: String,
            aliases: [String] = [],
            authorityHost: String? = nil,
            grokipediaSlug: String? = nil,
            entityKind: EntityKind? = nil,
            brandIconSlug: String? = nil,
            wikidataQID: String? = nil,
            celebrityFaceSlug: String? = nil,
            notes: String? = nil
        ) {
            self.canonicalKey = canonicalKey
            self.primaryURL = primaryURL
            self.aliases = aliases
            self.authorityHost = authorityHost
            self.grokipediaSlug = grokipediaSlug
            self.entityKind = entityKind
            self.brandIconSlug = brandIconSlug
            self.wikidataQID = wikidataQID
            self.celebrityFaceSlug = celebrityFaceSlug
            self.notes = notes
        }
    }

    // MARK: - The Master Curated List (the "open source pre-known list")

    /// This is deliberately large and richly aliased so the vast majority of real user
    /// "open <natural language description>" commands hit the fast trusted path with zero
    /// search and guaranteed correct results.
    public static let all: [OfficialEntity] = [
        // =====================================================================
        // xAI + Grok + Terafab / Memphis ecosystem (highest priority for current bugs)
        // =====================================================================
        OfficialEntity(
            canonicalKey: "xai",
            primaryURL: "https://x.ai",
            aliases: [
                "x.ai", "xai", "x ai", "xai official", "the xai site",
                "grok", "grok xai", "grok official",
                "xai memphis", "memphis", "memphis supercluster", "colossus",
                "xai supercluster", "xai cluster", "xai memphis supercluster",
                "xai chip", "xai chip facility", "xai fab",
                "elon xai", "elon musk xai"
            ],
            authorityHost: "x.ai",
            grokipediaSlug: "XAI_(company)",
            entityKind: .company,
            brandIconSlug: "xai",
            notes: "Core xAI company site + the Memphis Supercluster / Colossus (major AI training cluster). Key entry for many descriptive phrases."
        ),
        OfficialEntity(
            canonicalKey: "terafab",
            primaryURL: "https://terafab.ai",
            aliases: [
                "terafab", "tera fab", "terafab ai", "terafab official",
                "elon musk chip facility", "elon musk's chip facility", "elon chip facility",
                "musk chip facility", "chip facility", "the chip facility",
                "tesla terafab", "tesla chip fab", "tesla fab",
                "xai terafab", "xai chip fab", "xai fab",
                "memphis fab", "memphis chip", "memphis terafab",
                "elon musk terafab", "musk terafab", "terafab project",
                "official terafab", "terafab website", "terafab site"
            ],
            authorityHost: "terafab.ai",
            entityKind: .organization,
            notes: "OFFICIAL Terafab site per user correction. This is the primary target for 'elon musk's chip facility website', 'open terafab', 'xai memphis supercluster' etc. The joint Tesla/xAI/SpaceX AI chip fabrication initiative (Memphis-area Terafab)."
        ),
        OfficialEntity(
            canonicalKey: "grokipedia",
            primaryURL: "https://grokipedia.com",
            aliases: ["grokipedia", "grok ipedia", "grokipedia official"],
            authorityHost: "grokipedia.com",
            notes: "Grokipedia (Searxly-related knowledge site)."
        ),

        // =====================================================================
        // Tesla + related (strong overlap with Terafab context)
        // =====================================================================
        OfficialEntity(
            canonicalKey: "tesla",
            primaryURL: "https://tesla.com",
            aliases: [
                "tesla", "tesla official", "the tesla site", "tesla motors",
                "tesla car", "tesla website", "elon tesla", "musk tesla",
                "tesla terafab", "tesla chip", "tesla fab"
            ],
            authorityHost: "tesla.com",
            grokipediaSlug: "Tesla_Inc",
            entityKind: .company,
            brandIconSlug: "tesla",
            notes: "Tesla main site. Terafab is also heavily associated with Tesla (chips for FSD/Optimus/Dojo)."
        ),
        OfficialEntity(
            canonicalKey: "tesla developer",
            primaryURL: "https://developer.tesla.com",
            aliases: ["tesla developer", "tesla dev", "tesla api"],
            authorityHost: "developer.tesla.com",
            notes: "Tesla developer / API portal."
        ),

        // =====================================================================
        // SpaceX + Neuralink + broader Musk ecosystem
        // =====================================================================
        OfficialEntity(
            canonicalKey: "spacex",
            primaryURL: "https://spacex.com",
            aliases: ["spacex", "space x", "space-x", "elon spacex", "musk spacex"],
            authorityHost: "spacex.com",
            grokipediaSlug: "SpaceX",
            entityKind: .company,
            notes: "SpaceX official site."
        ),
        OfficialEntity(
            canonicalKey: "neuralink",
            primaryURL: "https://neuralink.com",
            aliases: ["neuralink", "neural link", "elon neuralink", "musk neuralink"],
            authorityHost: "neuralink.com",
            grokipediaSlug: "Neuralink",
            entityKind: .company,
            notes: "Neuralink official site."
        ),
        OfficialEntity(
            canonicalKey: "starlink",
            primaryURL: "https://www.starlink.com",
            aliases: ["starlink", "star link"],
            authorityHost: "www.starlink.com",
            grokipediaSlug: "Starlink",
            entityKind: .product,
            notes: "Starlink (SpaceX satellite internet)."
        ),

        // =====================================================================
        // X (the platform) — historically one of the hardest cases (news articles vs real site)
        // =====================================================================
        OfficialEntity(
            canonicalKey: "x",
            primaryURL: "https://x.com",
            aliases: [
                "x", "x.com", "twitter", "x twitter", "twitter x", "x rebrand",
                "formerly twitter", "the platform formerly known as twitter",
                "x official", "twitter official"
            ],
            authorityHost: "x.com",
            grokipediaSlug: "Twitter",
            entityKind: .website,
            notes: "X (formerly Twitter). Grokipedia article: grokipedia.com/page/Twitter."
        ),

        // =====================================================================
        // Wikipedia + reference (special handling for "the wikipedia page for ...")
        // =====================================================================
        OfficialEntity(
            canonicalKey: "wikipedia",
            primaryURL: "https://wikipedia.org",
            aliases: [
                "wikipedia", "wiki", "the wikipedia site", "wikipedia official",
                "wikipedia page", "wikipedia for"
            ],
            authorityHost: "wikipedia.org",
            notes: "Base Wikipedia. Callers can construct https://en.wikipedia.org/wiki/Topic for 'wikipedia page for Foo'."
        ),
        OfficialEntity(
            canonicalKey: "wikimedia",
            primaryURL: "https://wikimedia.org",
            aliases: ["wikimedia"],
            authorityHost: "wikimedia.org",
            notes: "Wikimedia foundation."
        ),

        // =====================================================================
        // Major well-known brands & services (from original map + staticSuggestions)
        // =====================================================================
        OfficialEntity(
            canonicalKey: "youtube",
            primaryURL: "https://youtube.com",
            aliases: ["youtube", "yt", "youtube official"],
            authorityHost: "youtube.com",
            grokipediaSlug: "YouTube",
            entityKind: .company,
            wikidataQID: "Q866"
        ),
        OfficialEntity(
            canonicalKey: "elon musk",
            primaryURL: "https://x.com/elonmusk",
            aliases: ["elon musk", "elon", "musk"],
            authorityHost: "x.com",
            grokipediaSlug: "Elon_Musk",
            entityKind: .person,
            wikidataQID: "Q317521",
            celebrityFaceSlug: "elon-musk",
            notes: "Public figure — knowledge panel uses Grokipedia; X profile as optional official link."
        ),

        // =====================================================================
        // Notable people — knowledge panel (Grokipedia + Wikidata + bundled faces)
        // =====================================================================
        OfficialEntity(
            canonicalKey: "bernard arnault",
            primaryURL: "https://www.lvmh.com",
            aliases: ["bernard arnault", "arnault", "bernard jean etienne arnault"],
            authorityHost: "lvmh.com",
            grokipediaSlug: "Bernard_Arnault",
            entityKind: .person,
            wikidataQID: "Q32055",
            celebrityFaceSlug: "bernard-arnault",
            notes: "LVMH chairman and CEO — world's leading luxury goods executive."
        ),
        OfficialEntity(
            canonicalKey: "jeff bezos",
            primaryURL: "https://www.aboutamazon.com",
            aliases: ["jeff bezos", "bezos", "jeffrey bezos"],
            authorityHost: "aboutamazon.com",
            grokipediaSlug: "Jeff_Bezos",
            entityKind: .person,
            wikidataQID: "Q312556",
            celebrityFaceSlug: "jeff-bezos"
        ),
        OfficialEntity(
            canonicalKey: "bill gates",
            primaryURL: "https://www.gatesfoundation.org",
            aliases: ["bill gates", "gates", "william henry gates"],
            authorityHost: "gatesfoundation.org",
            grokipediaSlug: "Bill_Gates",
            entityKind: .person,
            wikidataQID: "Q5284",
            celebrityFaceSlug: "bill-gates"
        ),
        OfficialEntity(
            canonicalKey: "mark zuckerberg",
            primaryURL: "https://about.meta.com",
            aliases: ["mark zuckerberg", "zuckerberg", "zuck"],
            authorityHost: "about.meta.com",
            grokipediaSlug: "Mark_Zuckerberg",
            entityKind: .person,
            wikidataQID: "Q36215",
            celebrityFaceSlug: "mark-zuckerberg"
        ),
        OfficialEntity(
            canonicalKey: "warren buffett",
            primaryURL: "https://www.berkshirehathaway.com",
            aliases: ["warren buffett", "buffett", "warren buffet"],
            authorityHost: "berkshirehathaway.com",
            grokipediaSlug: "Warren_Buffett",
            entityKind: .person,
            wikidataQID: "Q47213",
            celebrityFaceSlug: "warren-buffett"
        ),
        OfficialEntity(
            canonicalKey: "steve jobs",
            primaryURL: "https://www.apple.com",
            aliases: ["steve jobs", "jobs"],
            authorityHost: "apple.com",
            grokipediaSlug: "Steve_Jobs",
            entityKind: .person,
            wikidataQID: "Q19837",
            celebrityFaceSlug: "steve-jobs"
        ),
        OfficialEntity(
            canonicalKey: "tim cook",
            primaryURL: "https://www.apple.com",
            aliases: ["tim cook", "timothy cook"],
            authorityHost: "apple.com",
            grokipediaSlug: "Tim_Cook",
            entityKind: .person,
            wikidataQID: "Q265852",
            celebrityFaceSlug: "tim-cook"
        ),
        OfficialEntity(
            canonicalKey: "jensen huang",
            primaryURL: "https://www.nvidia.com",
            aliases: ["jensen huang", "huang"],
            authorityHost: "nvidia.com",
            grokipediaSlug: "Jensen_Huang",
            entityKind: .person,
            wikidataQID: "Q556445",
            celebrityFaceSlug: "jensen-huang"
        ),
        OfficialEntity(
            canonicalKey: "sam altman",
            primaryURL: "https://openai.com",
            aliases: ["sam altman", "altman"],
            authorityHost: "openai.com",
            grokipediaSlug: "Sam_Altman",
            entityKind: .person,
            wikidataQID: "Q27645609",
            celebrityFaceSlug: "sam-altman"
        ),
        OfficialEntity(
            canonicalKey: "satya nadella",
            primaryURL: "https://www.microsoft.com",
            aliases: ["satya nadella", "nadella"],
            authorityHost: "microsoft.com",
            grokipediaSlug: "Satya_Nadella",
            entityKind: .person,
            wikidataQID: "Q7426870",
            celebrityFaceSlug: "satya-nadella"
        ),
        OfficialEntity(
            canonicalKey: "larry page",
            primaryURL: "https://about.google",
            aliases: ["larry page", "lawrence page"],
            authorityHost: "about.google",
            grokipediaSlug: "Larry_Page",
            entityKind: .person,
            wikidataQID: "Q167545",
            celebrityFaceSlug: "larry-page"
        ),
        OfficialEntity(
            canonicalKey: "sergey brin",
            primaryURL: "https://about.google",
            aliases: ["sergey brin", "brin"],
            authorityHost: "about.google",
            grokipediaSlug: "Sergey_Brin",
            entityKind: .person,
            wikidataQID: "Q92764",
            celebrityFaceSlug: "sergey-brin"
        ),
        OfficialEntity(
            canonicalKey: "donald trump",
            primaryURL: "https://www.donaldjtrump.com",
            aliases: ["donald trump", "trump", "president trump"],
            authorityHost: "donaldjtrump.com",
            grokipediaSlug: "Donald_Trump",
            entityKind: .person,
            wikidataQID: "Q22686",
            celebrityFaceSlug: "donald-trump"
        ),
        OfficialEntity(
            canonicalKey: "barack obama",
            primaryURL: "https://www.barackobama.com",
            aliases: ["barack obama", "obama", "president obama"],
            authorityHost: "barackobama.com",
            grokipediaSlug: "Barack_Obama",
            entityKind: .person,
            wikidataQID: "Q76",
            celebrityFaceSlug: "barack-obama"
        ),
        OfficialEntity(
            canonicalKey: "taylor swift",
            primaryURL: "https://www.taylorswift.com",
            aliases: ["taylor swift", "swift"],
            authorityHost: "taylorswift.com",
            grokipediaSlug: "Taylor_Swift",
            entityKind: .person,
            wikidataQID: "Q26876",
            celebrityFaceSlug: "taylor-swift"
        ),
        OfficialEntity(
            canonicalKey: "beyonce",
            primaryURL: "https://www.beyonce.com",
            aliases: ["beyonce", "beyoncé", "beyonce knowles"],
            authorityHost: "beyonce.com",
            grokipediaSlug: "Beyoncé",
            entityKind: .person,
            wikidataQID: "Q36153",
            celebrityFaceSlug: "beyonce"
        ),
        OfficialEntity(
            canonicalKey: "lionel messi",
            primaryURL: "https://www.messi.com",
            aliases: ["lionel messi", "messi", "leo messi"],
            authorityHost: "messi.com",
            grokipediaSlug: "Lionel_Messi",
            entityKind: .person,
            wikidataQID: "Q615",
            celebrityFaceSlug: "lionel-messi"
        ),
        OfficialEntity(
            canonicalKey: "cristiano ronaldo",
            primaryURL: "https://www.cristianoronaldo.com",
            aliases: ["cristiano ronaldo", "ronaldo", "cr7"],
            authorityHost: "cristianoronaldo.com",
            grokipediaSlug: "Cristiano_Ronaldo",
            entityKind: .person,
            wikidataQID: "Q11571",
            celebrityFaceSlug: "cristiano-ronaldo"
        ),
        OfficialEntity(
            canonicalKey: "francois pinault",
            primaryURL: "https://www.kering.com",
            aliases: ["francois pinault", "françois pinault", "pinault"],
            authorityHost: "kering.com",
            grokipediaSlug: "François_Pinault",
            entityKind: .person,
            wikidataQID: "Q666587",
            celebrityFaceSlug: "francois-pinault"
        ),
        OfficialEntity(
            canonicalKey: "oprah winfrey",
            primaryURL: "https://www.oprah.com",
            aliases: ["oprah winfrey", "oprah"],
            authorityHost: "oprah.com",
            grokipediaSlug: "Oprah_Winfrey",
            entityKind: .person,
            wikidataQID: "Q43303",
            celebrityFaceSlug: "oprah-winfrey"
        ),

        OfficialEntity(canonicalKey: "youtube music", primaryURL: "https://music.youtube.com", aliases: ["youtube music", "yt music"], authorityHost: "music.youtube.com"),
        OfficialEntity(canonicalKey: "github", primaryURL: "https://github.com", aliases: ["github", "git hub"], authorityHost: "github.com"),
        OfficialEntity(
            canonicalKey: "google",
            primaryURL: "https://google.com",
            aliases: ["google", "google search"],
            authorityHost: "google.com",
            grokipediaSlug: "Google",
            entityKind: .company
        ),
        OfficialEntity(canonicalKey: "gmail", primaryURL: "https://gmail.com", aliases: ["gmail", "google mail"], authorityHost: "gmail.com"),
        OfficialEntity(canonicalKey: "google maps", primaryURL: "https://maps.google.com", aliases: ["google maps", "maps"], authorityHost: "maps.google.com"),
        OfficialEntity(canonicalKey: "reddit", primaryURL: "https://reddit.com", aliases: ["reddit"], authorityHost: "reddit.com"),
        OfficialEntity(canonicalKey: "netflix", primaryURL: "https://netflix.com", aliases: ["netflix"], authorityHost: "netflix.com"),
        OfficialEntity(canonicalKey: "nytimes", primaryURL: "https://nytimes.com", aliases: ["nytimes", "new york times", "nyt"], authorityHost: "nytimes.com"),
        OfficialEntity(canonicalKey: "amazon", primaryURL: "https://amazon.com", aliases: ["amazon", "amazon shopping"], authorityHost: "amazon.com"),
        OfficialEntity(
            canonicalKey: "apple",
            primaryURL: "https://apple.com",
            aliases: ["apple", "apple official", "the apple site"],
            authorityHost: "apple.com",
            grokipediaSlug: "Apple_Inc",
            entityKind: .company
        ),
        OfficialEntity(canonicalKey: "apple developer", primaryURL: "https://developer.apple.com", aliases: ["apple developer", "apple dev", "apple developer portal"], authorityHost: "developer.apple.com"),
        OfficialEntity(canonicalKey: "twitch", primaryURL: "https://twitch.tv", aliases: ["twitch"], authorityHost: "twitch.tv"),
        OfficialEntity(canonicalKey: "discord", primaryURL: "https://discord.com", aliases: ["discord"], authorityHost: "discord.com"),
        OfficialEntity(canonicalKey: "duckduckgo", primaryURL: "https://duckduckgo.com", aliases: ["duckduckgo", "ddg", "duck duck go"], authorityHost: "duckduckgo.com"),
        OfficialEntity(canonicalKey: "facebook", primaryURL: "https://facebook.com", aliases: ["facebook", "fb"], authorityHost: "facebook.com"),
        OfficialEntity(canonicalKey: "figma", primaryURL: "https://figma.com", aliases: ["figma"], authorityHost: "figma.com"),
        OfficialEntity(canonicalKey: "spotify", primaryURL: "https://spotify.com", aliases: ["spotify"], authorityHost: "spotify.com"),
        OfficialEntity(canonicalKey: "stackoverflow", primaryURL: "https://stackoverflow.com", aliases: ["stackoverflow", "stack overflow", "so"], authorityHost: "stackoverflow.com"),
        OfficialEntity(canonicalKey: "steam", primaryURL: "https://store.steampowered.com", aliases: ["steam", "steam store"], authorityHost: "store.steampowered.com"),
        OfficialEntity(canonicalKey: "microsoft", primaryURL: "https://microsoft.com", aliases: ["microsoft", "ms"], authorityHost: "microsoft.com"),
        OfficialEntity(canonicalKey: "medium", primaryURL: "https://medium.com", aliases: ["medium"], authorityHost: "medium.com"),
        OfficialEntity(canonicalKey: "linkedin", primaryURL: "https://linkedin.com", aliases: ["linkedin", "linked in"], authorityHost: "linkedin.com"),
        OfficialEntity(canonicalKey: "chatgpt", primaryURL: "https://chat.openai.com", aliases: ["chatgpt", "chat gpt", "openai chat"], authorityHost: "chat.openai.com"),
        OfficialEntity(canonicalKey: "openai", primaryURL: "https://openai.com", aliases: ["openai", "open ai"], authorityHost: "openai.com"),
        OfficialEntity(canonicalKey: "anthropic", primaryURL: "https://anthropic.com", aliases: ["anthropic", "claude"], authorityHost: "anthropic.com"),
        OfficialEntity(canonicalKey: "cloudflare", primaryURL: "https://cloudflare.com", aliases: ["cloudflare"], authorityHost: "cloudflare.com"),
        OfficialEntity(canonicalKey: "hacker news", primaryURL: "https://news.ycombinator.com", aliases: ["hacker news", "hn", "ycombinator"], authorityHost: "news.ycombinator.com"),
        OfficialEntity(canonicalKey: "gitlab", primaryURL: "https://gitlab.com", aliases: ["gitlab"], authorityHost: "gitlab.com"),
        OfficialEntity(canonicalKey: "docker hub", primaryURL: "https://hub.docker.com", aliases: ["docker hub", "dockerhub"], authorityHost: "hub.docker.com"),
        OfficialEntity(canonicalKey: "mdn", primaryURL: "https://developer.mozilla.org", aliases: ["mdn", "mozilla developer network", "developer mozilla"], authorityHost: "developer.mozilla.org"),
        OfficialEntity(canonicalKey: "arxiv", primaryURL: "https://arxiv.org", aliases: ["arxiv"], authorityHost: "arxiv.org"),
        OfficialEntity(canonicalKey: "bbc", primaryURL: "https://bbc.com", aliases: ["bbc", "bbc news"], authorityHost: "bbc.com"),
        OfficialEntity(canonicalKey: "guardian", primaryURL: "https://theguardian.com", aliases: ["guardian", "the guardian"], authorityHost: "theguardian.com"),
        OfficialEntity(canonicalKey: "reuters", primaryURL: "https://reuters.com", aliases: ["reuters"], authorityHost: "reuters.com"),
        OfficialEntity(canonicalKey: "wolfram", primaryURL: "https://wolframalpha.com", aliases: ["wolfram", "wolfram alpha"], authorityHost: "wolframalpha.com"),
        OfficialEntity(canonicalKey: "instagram", primaryURL: "https://instagram.com", aliases: ["instagram", "ig"], authorityHost: "instagram.com"),
        OfficialEntity(canonicalKey: "tiktok", primaryURL: "https://tiktok.com", aliases: ["tiktok"], authorityHost: "tiktok.com"),
        OfficialEntity(canonicalKey: "whatsapp", primaryURL: "https://web.whatsapp.com", aliases: ["whatsapp", "wa"], authorityHost: "web.whatsapp.com"),
        OfficialEntity(canonicalKey: "zoom", primaryURL: "https://zoom.us", aliases: ["zoom"], authorityHost: "zoom.us"),
        OfficialEntity(canonicalKey: "dropbox", primaryURL: "https://dropbox.com", aliases: ["dropbox"], authorityHost: "dropbox.com"),
        OfficialEntity(canonicalKey: "notion", primaryURL: "https://notion.so", aliases: ["notion"], authorityHost: "notion.so"),
        OfficialEntity(canonicalKey: "linear", primaryURL: "https://linear.app", aliases: ["linear"], authorityHost: "linear.app"),
        OfficialEntity(canonicalKey: "vercel", primaryURL: "https://vercel.com", aliases: ["vercel"], authorityHost: "vercel.com"),
        OfficialEntity(canonicalKey: "stripe", primaryURL: "https://stripe.com", aliases: ["stripe"], authorityHost: "stripe.com"),

        // =====================================================================
        // Additional high-value / common "open the official" entities
        // (expanded for the "huge" coverage goal)
        // =====================================================================
        OfficialEntity(canonicalKey: "github.com", primaryURL: "https://github.com", aliases: ["github.com"]),
        OfficialEntity(canonicalKey: "apple.com", primaryURL: "https://apple.com", aliases: ["apple.com"]),
        OfficialEntity(canonicalKey: "x.com", primaryURL: "https://x.com", aliases: ["x.com"]),
        OfficialEntity(canonicalKey: "developer.apple.com", primaryURL: "https://developer.apple.com", aliases: ["developer.apple.com"]),

        // AI / dev tools that users frequently want the "official site" for
        OfficialEntity(canonicalKey: "huggingface", primaryURL: "https://huggingface.co", aliases: ["huggingface", "hugging face", "hf"], authorityHost: "huggingface.co"),
        OfficialEntity(canonicalKey: "replicate", primaryURL: "https://replicate.com", aliases: ["replicate"], authorityHost: "replicate.com"),
        OfficialEntity(canonicalKey: "perplexity", primaryURL: "https://www.perplexity.ai", aliases: ["perplexity", "perplexity ai"], authorityHost: "www.perplexity.ai"),
        OfficialEntity(canonicalKey: "midjourney", primaryURL: "https://midjourney.com", aliases: ["midjourney", "mj"], authorityHost: "midjourney.com"),
        OfficialEntity(canonicalKey: "cursor", primaryURL: "https://cursor.com", aliases: ["cursor", "cursor ai"], authorityHost: "cursor.com"),
        OfficialEntity(canonicalKey: "v0", primaryURL: "https://v0.dev", aliases: ["v0", "v0 dev", "vercel v0"], authorityHost: "v0.dev"),

        // Common privacy / alternative services
        OfficialEntity(canonicalKey: "protonmail", primaryURL: "https://proton.me/mail", aliases: ["protonmail", "proton mail"], authorityHost: "proton.me"),
        OfficialEntity(canonicalKey: "brave", primaryURL: "https://brave.com", aliases: ["brave", "brave browser"], authorityHost: "brave.com"),
        OfficialEntity(canonicalKey: "signal", primaryURL: "https://signal.org", aliases: ["signal", "signal messenger"], authorityHost: "signal.org"),

        // =====================================================================
        // Special "constructable" seeds (Wikipedia, GitHub, X profiles, etc.)
        // The actual slug construction logic lives in SiteResolver / BrowserState.
        // =====================================================================
        OfficialEntity(
            canonicalKey: "wikipedia special",
            primaryURL: "https://en.wikipedia.org",
            aliases: ["wikipedia page for", "the wikipedia page for", "wiki for"],
            notes: "Signal for special-case 'open the wikipedia page for <topic>' handling (construct /wiki/Slug)."
        ),
    ]

    // MARK: - Derived Lookups (fast runtime structures)

    /// Fast exact lookup by canonical key or any alias (after normalization in caller).
    private static let lookupTable: [String: OfficialEntity] = {
        var table: [String: OfficialEntity] = [:]
        for entity in all {
            table[entity.canonicalKey] = entity
            for alias in entity.aliases {
                let norm = alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if table[norm] == nil {
                    table[norm] = entity
                }
            }
        }
        return table
    }()

    /// All known aliases + canonicals (useful for fuzzy scoring in SiteResolver).
    public static let allKnownPhrases: Set<String> = {
        var set = Set<String>()
        for entity in all {
            set.insert(entity.canonicalKey)
            for a in entity.aliases {
                set.insert(a.lowercased())
            }
        }
        return set
    }()

    // MARK: - Public API (consumed by SiteResolver + BrowserState)

    /// Returns the OfficialEntity for an already-normalized key/alias, if any.
    public static func entity(for normalized: String) -> OfficialEntity? {
        let key = normalized.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lookupTable[key]
    }

    /// Legacy-compatible map for the previous trustedMap style.
    /// New code should prefer entity(for:) or direct lookup.
    public static func trustedMap() -> [String: String] {
        var map: [String: String] = [:]
        for entity in all {
            map[entity.canonicalKey] = entity.primaryURL
            for alias in entity.aliases {
                let norm = alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if map[norm] == nil {
                    map[norm] = entity.primaryURL
                }
            }
        }
        return map
    }

    /// Set of hosts that are considered high-authority "official" destinations.
    /// Used by SiteResolver.bestSafeCandidate for strong relevance boosts.
    public static func authorityHosts() -> Set<String> {
        var hosts = Set<String>()
        for entity in all {
            if let h = entity.authorityHost {
                hosts.insert(h.lowercased())
            }
            // Also derive from primaryURL
            if let u = URL(string: entity.primaryURL), let host = u.host?.lowercased() {
                hosts.insert(host)
            }
        }
        // Always include a few evergreen high-value ones even if not in every entity
        hosts.formUnion([
            "x.ai", "terafab.ai", "tesla.com", "spacex.com", "neuralink.com",
            "x.com", "github.com", "apple.com", "wikipedia.org"
        ])
        return hosts
    }

    /// Returns a curated, high-quality search query string for fallthrough resolution
    /// when no trusted map hit exists. Callers (BrowserState) use this instead of
    /// just "<description> official site".
    public static func resolutionQuery(for description: String) -> String {
        let lower = description.lowercased()

        // Terafab / Memphis / chip facility family → very specific high-signal query
        if lower.contains("terafab") ||
           lower.contains("chip facility") ||
           (lower.contains("memphis") && (lower.contains("super") || lower.contains("cluster") || lower.contains("fab") || lower.contains("chip"))) ||
           (lower.contains("xai") && (lower.contains("chip") || lower.contains("fab") || lower.contains("memphis"))) {
            return "xAI Terafab OR Memphis Supercluster OR Colossus official site"
        }

        // Wikipedia special phrasing
        if lower.contains("wikipedia") && (lower.contains("page") || lower.contains("for ")) {
            // The actual slug construction is done in SiteResolver / callers.
            // Here we just produce a clean query that works well in SearXNG.
            return description.replacingOccurrences(of: "the wikipedia page for ", with: "", options: .caseInsensitive)
                              .replacingOccurrences(of: "wikipedia page for ", with: "", options: .caseInsensitive)
                              .replacingOccurrences(of: "wikipedia for ", with: "", options: .caseInsensitive)
                              .trimmingCharacters(in: .whitespacesAndNewlines) + " site:wikipedia.org"
        }

        // X / Twitter special (already heavily handled in normalizers, but keep query clean)
        if lower == "x" || lower.contains("twitter") || lower.contains("rebrand") {
            return "x.com official site"
        }

        // Default high-quality "official" phrasing
        let base = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "official site" }
        return "\(base) official site"
    }

    /// Simple local fuzzy: does the query share strong token overlap or is a close prefix/contains
    /// with any known entity key or alias. Used as a secondary fast path before search.
    public static func fuzzyMatchURL(for normalizedQuery: String) -> String? {
        let q = normalizedQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        let qTokens = Set(q.split(separator: " ").map(String.init).filter { $0.count > 1 })

        var bestURL: String?
        var bestScore = 0

        for entity in all {
            let candidates = [entity.canonicalKey] + entity.aliases
            for cand in candidates {
                let c = cand.lowercased()
                let cTokens = Set(c.split(separator: " ").map(String.init).filter { $0.count > 1 })

                let overlap = qTokens.intersection(cTokens).count
                var score = overlap * 12

                if c.contains(q) || q.contains(c) { score += 8 }
                if c.hasPrefix(q) || q.hasPrefix(c) { score += 10 }

                // Strong boost for Terafab family (the motivating case)
                if (q.contains("terafab") || q.contains("chip facility") || q.contains("memphis") || q.contains("supercluster")) &&
                   (c.contains("terafab") || entity.authorityHost == "terafab.ai" || entity.canonicalKey == "terafab") {
                    score += 30
                }

                // X brand protection
                if qTokens.contains("x") && (c == "x" || c.contains("x.com")) {
                    score += 25
                }

                if score > bestScore && score >= 12 {
                    bestScore = score
                    bestURL = entity.primaryURL
                }
            }
        }
        return bestURL
    }
}
