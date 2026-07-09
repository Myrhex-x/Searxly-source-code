# Searxly iOS — App Store Compliance Checklist

A living reference for keeping the iOS app **shippable to the App Store**. Check this before adding
any feature that touches permissions, payments, data, or the web engine. Guideline numbers refer to the
[App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

Status legend: ✅ done / handled · ⚠️ action needed before submission · 🔒 hard rule (don't break)

---

## 1. Web engine — Guideline 2.5.6

- ✅ The browser uses **`WKWebView` only**. No custom/embedded browser engine, no JIT of our own.
- ✅ We do **not** download or execute native code. There is no bundled interpreter on iOS (the macOS
  app's bundled Python SearXNG is **not** part of the iOS target — search hits a remote instance).
- 🔒 Never add a bundled interpreter, `dlopen` of downloaded libraries, or a non-WebKit renderer.

## 2. Payments & crypto — Guidelines 3.1.1, 3.1.5(b), 3.1.3

- ✅ The iOS app ships with **no wallet, no crypto, no DEX, no `$SEARXLY` gating, no paid features.**
- 🔒 When paid features arrive (cloud AI, managed VPN), they **must** unlock via **StoreKit IAP** —
  never USDC / on-chain tokens. Crypto may not unlock app functionality (3.1.5(b)); digital services
  need IAP (3.1.1). This is the single biggest rejection risk for this product; keep it off iOS.
- ✅ Self-custody wallets are *permitted* on iOS — the violation is *coupling a wallet to unlock the
  app's own features*. We simply don't ship the wallet on iOS, which sidesteps the whole area.

## 3. Privacy manifest & data — Guideline 5.1.1, App Privacy

- ✅ `SearxlyiOS/PrivacyInfo.xcprivacy` present: `NSPrivacyTracking = false`, **no collected data types**,
  **no tracking domains**.
- ✅ Required-reason APIs declared: `UserDefaults` (CA92.1), `FileTimestamp` (C617.1).
- ✅ On-device, encrypted at rest (AES-GCM, data-protection Keychain key): history, bookmarks,
  **reading list**, **downloads index**, recent searches, tabs, per-site settings.
- ⚠️ **When you add a data-touching API, update the manifest.** Common additions and their reason codes:
  - Disk-space checks → `NSPrivacyAccessedAPICategoryDiskSpace` (E174.1 / 85F4.1)
  - `systemUptime` (e.g. mach_absolute timing) → `NSPrivacyAccessedAPICategorySystemBootTime` (35F9.1)
  - Active keyboard list → declare accordingly. If unsure, check Apple's required-reason list.
- ✅ App Privacy answers in App Store Connect: **"Data Not Collected."** Keep it that way — searches go
  to the user's configured instance and page loads go to the sites they visit; neither is "collection
  by the developer."

## 4. Permission usage strings — Guideline 5.1.1(i)

Every permission needs a purpose string in Info.plist (set via `INFOPLIST_KEY_*` in the pbxproj, since
the target uses a generated Info.plist).

- ✅ `NSFaceIDUsageDescription` — App Lock / locked private tabs.
- ✅ **Downloads need no permission** — files land in the app sandbox; the user exports via the share
  sheet / "Save to Files" (a document picker needs no entitlement).
- ⚠️ If you add these features, add the matching string **and** the manifest entry:
  - QR-code scanner in the address bar → `NSCameraUsageDescription`
  - Voice search → `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`
  - "Downloads to Photos" for images → `NSPhotoLibraryAddUsageDescription`
- 🔒 Don't request a permission you don't use — Apple rejects unused permission prompts.

## 5. Web content & age rating — Guidelines 1.2, 1.4, 5.6

- ✅ Unrestricted web access → the App Store **age rating must be 17+** (declare "Unrestricted Web
  Access" in App Store Connect). This is standard for browsers.
- ✅ Content controls exist: **SafeSearch** (off/moderate/strict), ad/tracker **shields**, HTTPS-Only,
  cookie-banner hiding, and the NSFW content-safety blocklist in the shared search pipeline.
- ✅ The news feed is topic headlines from the user's instance, opt-out, memory-only — no editorializing.

## 6. Export compliance / encryption — App Store Connect

- ⚠️ We use only **standard, exempt cryptography** (Apple's CryptoKit AES-GCM for at-rest data, TLS for
  network). Set **`ITSAppUsesNonExemptEncryption = NO`** in the iOS Info.plist so every TestFlight/App
  Store upload skips the "missing compliance" prompt. (Added via `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`.)

## 7. Backups & storage — App Store best practice

- ✅ Downloaded files live in `Application Support/Searxly/Downloads`, **excluded from iCloud backup**
  (`isExcludedFromBackup`) — re-downloadable content must not bloat backups (a common rejection).
- ✅ Caches (favicons, thumbnails) are prunable and bounded.

## 8. Tracking / ATT — Guideline 5.1.2

- ✅ No IDFA, no ad SDKs, no analytics, no cross-app tracking → **no ATT prompt needed.**
- 🔒 Never add a third-party analytics/ads SDK without revisiting the privacy manifest + ATT.

## 9. Optional / future entitlements

- **Default browser** (`com.apple.developer.web-browser`): needs a separate Apple approval request and a
  real Info.plist declaration. **Not required to ship** — request only when we want to be a selectable
  default browser.
- **New app extensions** (Share extension, Widgets, App Intents extension, Safari-style content blocker
  extension): each is a **new target** (pbxproj work) with its own bundle id, entitlements, and privacy
  manifest. App Intents currently ship **in-app** (no extension) to avoid this.

---

## Pre-submission quick pass

1. Age rating **17+**, "Unrestricted Web Access" declared.
2. `ITSAppUsesNonExemptEncryption = NO` present.
3. Privacy manifest matches the APIs actually used; App Privacy = "Data Not Collected."
4. Every Info.plist permission string corresponds to a real, used feature.
5. No crypto/wallet/paid-feature coupling anywhere in the iOS target.
6. Real device smoke test: search, browse, download a file, private tab, App Lock, news feed.
