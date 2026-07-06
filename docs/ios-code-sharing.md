# iOS ↔ macOS code sharing (Phase 1: the big step)

The iOS app (`SearxlyiOS` target) and the macOS app (`Searxly` target) share platform-agnostic logic
through a third source folder, **`SearxlyShared/`**, which is a `PBXFileSystemSynchronizedRootGroup`
listed in *both* targets' `fileSystemSynchronizedGroups`. Anything dropped into `SearxlyShared/`
compiles into both apps; nothing else needs wiring.

## Why this approach (vs. a giant exception list)

The alternative — add the whole `Searxly/` folder to the iOS target and exclude the macOS-only files —
is all-or-nothing and forces `#if os(macOS)` through otherwise-shared code. Moving genuinely-portable
files into `SearxlyShared/` instead is **incremental and compile-neutral for macOS**: a file relocated
within the same module compiles identically, so the shipping macOS app is unaffected (verified by a full
macOS build after each migration).

## The migration rule: move whole dependency closures

A file is only portable if its *entire* code dependency closure is portable. Before moving a file:

1. `grep '^import'` it — only `Foundation` / `os` / pure-Swift is a green light; `AppKit`, `SwiftUI`
   in logic files, `WebKit` for view wrappers are red/yellow.
2. Grep for coupling to macOS-only subsystems (`WalletManager`, `TorManager`, `PrivacyManager`,
   `PrivacyGate`, `HelperClient`, `LocalSearxngManager`, `AdBlockManager`, `BrowserState`, `DeveloperSettings`).
   **Check whether hits are real code or just comments** — comments are fine.
3. Resolve the types it references (`OfficialEntityDatabase.EntityKind`, etc.) and move that file too.
4. Move the closure into `SearxlyShared/`, then build **both** `SearxlyiOS` and `Searxly`.

Verify:
```bash
xcodebuild -scheme SearxlyiOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme Searxly    -destination 'platform=macOS'                 build CODE_SIGNING_ALLOWED=NO
```

## Migrated so far

- `OfficialEntityDatabase.swift` (curated official-entity → official-site DB; Foundation-only)
- `KnowledgePanelState.swift` (knowledge-panel models; depends only on `OfficialEntityDatabase`)
- `SearXNGModels.swift` + `SearxngClient.swift` (SERP data types + lean JSON client)
- **The whole SERP post-fetch pipeline (2026-07-02):** `SearchResultProcessor.swift`,
  `SearchResultRanker.swift`, `SERPSourcePolicy.swift`, `SearchMediaURLResolver.swift`,
  `SearchContentSafety.swift` + `SearchContentSafetyBlocklist.swift` (+ the bundled
  `ContentSafety/hagezi-nsfw-onlydomains.txt`, now a resource of BOTH targets), and
  `SearXNGSearchOptions` (into `SearXNGModels.swift`). The `bestEntity` blocker was resolved
  by extracting `EntityQueryMatcher.swift` (strict entity matching) into the shared folder;
  `KnowledgePanelService` now delegates to it, so the panel service itself stays macOS-only.
  iOS `BrowserModel.performSearch` runs `SearchResultProcessor.process` — full ranking parity.

## Next candidate slices (with the closure work each needs)

| Slice | Value on iOS | Blocker to resolve first |
|---|---|---|
| SearXNG JSON client (`SearXNGService.swift`) | Native results instead of the web UI | Real coupling to `BrowserState`, `DeveloperSettings`, `PrivacyGate` — extract a portable core (or protocol-ize those) |
| Result models (in `Models.swift`, 632 lines) | Shared SERP data types | Must split `Models.swift` — the result structs are portable but `BrowserTab`/`BrowserState` (SwiftUI/WebKit) are not |
| Knowledge panel resolver (`KnowledgePanelService` + Grokipedia/Wikipedia clients) | Knowledge cards on the iOS SERP | Needs `SearXNGImageResolver` + `GrokipediaArticleClient` + `WikipediaTitleResolver` closure survey (entity matching already shared via `EntityQueryMatcher`) |
| `SearchAutocompleteService` / suggestions | Search suggestions | TBD — survey imports/closure |

## Never share to iOS (macOS-only, keep out of `SearxlyShared/`)

Wallet/* · Tor/* · VPN/* · the privileged helper + `HelperClient`/XPC · `LocalSearxngManager` (bundled
Python) · Sparkle/`SoftwareUpdater` · all AppKit (`NS*`) views. iOS gets its own twins (e.g. the
`WKWebViewRepresentable` vs the macOS `NSViewRepresentable`).
