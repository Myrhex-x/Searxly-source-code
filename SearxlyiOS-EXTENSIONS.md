# Searxly iOS — Extensions integration guide

Everything below is **written, typechecked against the iOS SDK, and wired on the app side.** The only
thing that can't be scripted is *creating the two extension targets* — the project uses
file-system-synchronized groups (open with **Xcode 26** stable for App Store builds; keep
`objectVersion` ≤ 77 for that). Creating a target in Xcode is a ~2-minute GUI step. Steps are exact.

**App / App Group ids:** main app bundle is `com.myrhex.Searxly`; App Group for widgets is
`group.com.myrhex.searxly` (must match `SharedPrivacyStats.appGroup`).

---

## Already done in the app (no action needed)

- **`searxly://` URL scheme** registered (`SearxlyiOS-Info.plist`, wired via `INFOPLIST_FILE`).
- **Deep-link routing** in `BrowserView.handleDeepLink`:
  - `searxly://search` → new tab, address bar focused
  - `searxly://private` → new private tab
  - `searxly://reopen` → reopen last closed tab
  - `searxly://open?url=<encoded>` → open that page
  - `http(s)://…` handed to the app → opens in a new tab (for the Share extension / default browser)
- **Widget data feed**: `ShieldSettings` mirrors the lifetime "trackers blocked" count into the App
  Group via `SharedPrivacyStats`; `RootView` calls `WidgetCenter.reloadAllTimelines()` on background.

---

## 1) Home Screen / Lock Screen widgets  (`SearxlyWidgets/SearxlyWidgets.swift`)

Two monochrome widgets: **Privacy** (lifetime trackers blocked) and **Quick Actions** (Search /
Private / Reopen deep-links).

**Create the target**
1. Xcode ▸ **File ▸ New ▸ Target… ▸ Widget Extension**. Product name: **`SearxlyWidgets`**.
   Uncheck *Include Live Activity* and *Include Configuration App Intent* (these are static widgets).
   Finish ▸ **Activate** the scheme when prompted.
2. Xcode generates a boilerplate `SearxlyWidgets.swift` + assets. **Delete the generated
   `SearxlyWidgets.swift`** (it has its own `@main`, which would collide).
3. Add the prepared file: drag **`SearxlyWidgets/SearxlyWidgets.swift`** into the new target (or, if it
   already appears, tick **Target Membership ▸ SearxlyWidgets** in the File Inspector).
4. Select **`SearxlyiOS/Services/SharedPrivacyStats.swift`** and tick **Target Membership ▸
   SearxlyWidgets** as well (the widget reads the shared count through it).

**Enable the shared count (App Group)** — do this for **both** targets:
5. Select the project ▸ target **SearxlyiOS** ▸ **Signing & Capabilities ▸ + Capability ▸ App Groups**;
   add **`group.com.myrhex.searxly`**.
6. Repeat for target **SearxlyWidgets** (same group id). Must match `SharedPrivacyStats.appGroup`.

Build & run **SearxlyWidgets** (or long-press the Home Screen ▸ add the *Searxly* widgets). The Privacy
widget shows 0 until you browse a bit with shields up; Quick Actions works immediately.

> Note: On a **real device** the App Group must also be enabled for your App ID in the Developer
> portal (Xcode's automatic signing does this when you add the capability). On the **simulator** it
> just works.

---

## 2) "Open in Searxly" Share extension  (`SearxlyShareExtension/ShareViewController.swift`)

Adds Searxly to the system share sheet; sharing a link/page opens it in a Searxly tab.

**Create the target**
1. Xcode ▸ **File ▸ New ▸ Target… ▸ Share Extension**. Product name: **`SearxlyShareExtension`**.
   Finish ▸ Activate.
2. Xcode generates `ShareViewController.swift` + **`MainInterface.storyboard`** + `Info.plist`.
   - **Delete the generated `ShareViewController.swift`** and add the prepared
     **`SearxlyShareExtension/ShareViewController.swift`** (Target Membership ▸ SearxlyShareExtension).
   - **Delete `MainInterface.storyboard`** (this extension has no UI).
3. Replace the target's generated `Info.plist` contents with
   **`SearxlyShareExtension/ShareExtension-Info.plist`** (it sets `NSExtensionPrincipalClass` instead of
   a storyboard, and the activation rule for web URLs / pages / text). Easiest: set the target's
   **Build Settings ▸ Info.plist File** to `SearxlyShareExtension/ShareExtension-Info.plist`, or paste
   the keys into the generated one.

Build & run **SearxlyShareExtension** and pick a host app (e.g. Safari) to launch it. Share any page →
"Open in Searxly" → it opens in the app via `searxly://open?url=…`.

---

## 3) Default browser  (Apple-approval gated)

The app already **handles** http/https opens (`handleDeepLink`). To become **selectable** as the iOS
default browser you need the managed entitlement **`com.apple.developer.web-browser`**:

1. Request it: <https://developer.apple.com/contact/request/default-browser/> (Apple reviews; the app
   must genuinely be a browser — Searxly qualifies).
2. Once granted, add `com.apple.developer.web-browser = YES` to the app's entitlements (Signing &
   Capabilities will offer it), and register http/https in `CFBundleURLTypes` if required by the form.
3. Users then pick Searxly under **Settings ▸ Apps ▸ Default Apps ▸ Browser App**.

Until Apple grants it, there is nothing more to build — the plumbing is in place.

---

## 4) Unit tests  (`SearxlyiOSTests/NavigationGuardTests.swift`)

Deterministic tests for the shields' pure URL logic (tracking-param stripping, De-AMP, scheme
classification) and the widget's shared-count bridge.

1. Xcode ▸ **File ▸ New ▸ Target… ▸ Unit Testing Bundle**. Product name **`SearxlyIOSTests`**;
   set **Target to be Tested = SearxlyiOS**. Finish.
2. Delete the generated boilerplate test file; add **`SearxlyiOSTests/NavigationGuardTests.swift`** to
   the new target (it uses `@testable import SearxlyiOS`).
3. **⌘U** to run. (The `SharedPrivacyStatsTests` round-trip needs the App Group from step 1 of the
   widget section to be present on the app target; the `NavigationGuardTests` have no dependencies.)

---

## Passwords / AutoFill

No work needed and **none wanted** (per product decision): iOS uses the **Apple Passwords app /
iCloud Keychain** to autofill web forms in `WKWebView` automatically. Nothing in the app disables text
interaction or autofill, so it already works. There is intentionally **no Searxly password vault on
iOS** (that stays macOS-only).
