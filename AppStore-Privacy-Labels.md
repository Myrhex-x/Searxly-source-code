# App Store Privacy Labels — Searxly (iOS)

*Internal working doc — fill this into App Store Connect ▸ your app ▸ App Privacy. Gitignore before publishing source if you'd rather keep it private. Not legal advice; it just maps the Privacy Policy to Apple's questionnaire. Keep it in sync with [privacy.html] / the in-app Legal text.*

## Bottom line

The iOS app has **no accounts, no analytics, no ads, no third-party SDKs, no tracking, and no IDFA**. Browsing history, bookmarks, and on-device AI never leave the device. The only thing that leaves the device for the app to function is your **search query**, sent to Searxly's own SearXNG instance (`search.searxly.app`) to return results — not stored, not linked to you, not used to track.

Under Apple's definition, "collect" means retaining data off-device beyond servicing the request. Because the search instance is run on a no-logs basis and doesn't retain or link queries, **"Data Not Collected" is defensible** — with one judgment call noted below.

> **Answer for "Data Used to Track You": No, across the board.** The app does no tracking, so there is **no App Tracking Transparency (ATT) prompt** and no `NSUserTrackingUsageDescription` needed.

## Recommended answers, by Apple data category

| Apple category | Collected? | If yes: Linked to identity? | Used for tracking? | Notes |
|---|---|---|---|---|
| Contact Info | **No** | — | — | No accounts, no email capture in-app. |
| Health & Fitness | **No** | — | — | — |
| Financial Info | **No** | — | — | The wallet is **macOS-only**; not in the iOS app. |
| Location | **No** | — | — | Local Pack is **macOS-only**; iOS requests no location. |
| Sensitive Info | **No** | — | — | — |
| Contacts | **No** | — | — | — |
| User Content | **No** | — | — | Bookmarks/history/reading list are local only. |
| Browsing History | **No** | — | — | Never transmitted off-device. |
| **Search History** | **Judgment call** — see below | No | No | Queries go to our instance to return results; not retained/linked. |
| Identifiers | **No** | — | — | No user ID, no device ID, no IDFA. |
| Purchases | **No** | — | — | Free app, no IAP. |
| Usage Data | **No** | — | — | No analytics/telemetry (verified in code). |
| Diagnostics | **No** | — | — | No crash-reporting SDK. |
| Other Data | **No** | — | — | — |

## The one judgment call: Search History

Two defensible options — pick based on how strictly you read Apple's rules:

- **Option A — "Data Not Collected" (recommended if confident the instance retains nothing).** Apple lets you exclude data that leaves the device only to service the request and isn't retained. Your policy states the instance keeps no query logs/profiles, so this holds. Cleanest label.
- **Option B — declare "Search History", *Not Linked to You*, *Not Used for Tracking*, purpose "App Functionality".** The conservative choice if you want to disclose that queries transit your server at all. Still a strong privacy label.

Do **not** pick anything that implies linking-to-identity or tracking — neither is true.

## Also do

- **Privacy Policy URL** in App Store Connect → `https://searxly.app/privacy` (now live and accurate).
- Keep this label set **matching the policy** on every release. If you ever add a data-touching feature to iOS (e.g. port the wallet or Local Pack), revisit this table.
- **macOS** ships as a notarized DMG (not the Mac App Store), so these labels aren't required there — but if you ever put macOS on the Mac App Store, it has the wallet/VPN/Local Pack and would need Financial Info + Location + a fuller review.
