# Searxly iOS — TestFlight guide

## Current ship state (repo)

| Item | State |
|---|---|
| **Display name** | **Searxly** |
| **Bundle ID** | `com.myrhex.Searxly` |
| **Team** | your own Apple Team ID (`DEVELOPMENT_TEAM` is blank in the project) |
| **Version / build** | `0.9.2` (build **11** as of last upload — bump `CURRENT_PROJECT_VERSION` each ship) |
| **Minimum iOS** | **26.0** (Liquid Glass / modern SwiftUI) |
| **Privacy manifest** | `SearxlyiOS/PrivacyInfo.xcprivacy` — no tracking, required-reason APIs declared |
| **Export compliance** | `ITSAppUsesNonExemptEncryption = NO` |
| **App Store Connect app id** | `6789156323` |

Use **Xcode 26.x stable** (`/Applications/Xcode.app`) for archives. Xcode 27 beta SDKs are rejected by App Store Connect (“Unsupported SDK or Xcode version”). The project `objectVersion` is kept at **77** so Xcode 26 can open it.

---

## Archive & upload (CLI, already proven)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /path/to/Searxly

# 1) Bump CURRENT_PROJECT_VERSION for the SearxlyiOS Debug + Release configs in project.pbxproj

# 2) Archive
xcodebuild -project Searxly.xcodeproj \
  -scheme SearxlyiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/SearxlyiOS-0.9.2.xcarchive \
  -allowProvisioningUpdates \
  archive

# 3) Upload (build/ExportOptions-AppStore.plist → method app-store-connect, destination upload)
xcodebuild -exportArchive \
  -archivePath build/SearxlyiOS-0.9.2.xcarchive \
  -exportOptionsPlist build/ExportOptions-AppStore.plist \
  -exportPath build/Export-iOS-0.9.2 \
  -allowProvisioningUpdates
```

Or: Xcode ▸ scheme **SearxlyiOS** ▸ **Any iOS Device** ▸ **Product ▸ Archive** ▸ **Distribute App ▸ App Store Connect ▸ Upload**.

Processing takes ~5–15 minutes, then the build appears under TestFlight → Internal Testing.

---

## TestFlight notes

- **Internal testers** — no Apple review; need iOS 26+.
- **External testers** — Beta App Review + privacy policy URL (`https://searxly.app/privacy`) + contact email.
- Each upload needs a **new build number**.

---

## Optional next packaging

- Wire **widgets / Share extension** targets (see `SearxlyiOS-EXTENSIONS.md`).
- Auto-increment `CURRENT_PROJECT_VERSION` in CI or a pre-archive script.
- iOS 18 back-deploy only if you need a wider beta pool (gates Liquid Glass).
