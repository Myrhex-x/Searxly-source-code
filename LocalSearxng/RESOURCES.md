# Local SearXNG Resources (Bundled with Searxly)

This folder is the **single source of truth** for the files that Searxly bundles into the app and copies to `~/searxng-local/` on first automatic (or manual) setup of the user's private local SearXNG instance.

SearXNG runs as a **bundled native Python process** — no Docker, no downloads. The signed Python runtime ships inside the app at `Resources/searxng-runtime/`, and the unsandboxed `SearxlyHelper` XPC service spawns and supervises it (`python -m searx.webapp`) on behalf of the sandboxed main app.

## Contents
- `searxng/settings.yml.example` — safe template (placeholder secret). At runtime Searxly generates a strong random `secret_key` and writes a real `settings.yml`.
- `searxng/limiter.toml` — permissive limiter for local private use.
- `custom/` — the premium xAI/SpaceX-inspired Searxly theme (templates + static CSS). Kept for reference; the native instance serves SearXNG's complete built-in simple theme, and Searxly renders its own native SwiftUI SERP from the JSON API.

## How bundling works
1. In Xcode: the `LocalSearxng` folder must be added to the **Searxly** target via **Add Files → Create folder references** (not "Create groups").
2. After changes: **Product > Clean Build Folder** (⇧⌘K) then build.
3. At runtime `LocalSearxngManager` uses defensive `Bundle.main` lookups (it searches flat, under `LocalSearxng/`, under `local-searxng/`, etc.) so it works reliably regardless of how the folder reference landed inside the .app bundle.

The high-level `provisionIfNeeded()` / `ensureReadyAndRunning()` (and the old `ensureProjectFolderExists`) do the copy + secret injection + theme deployment into the user's `~/searxng-local`.

## For developers
- Keep this folder minimal. Stray files (including old .txt docs) will be bundled and copied to every user's machine.
- The committed `settings.yml.example` must never contain a real secret.
- The manager now guarantees a real secret is written for new setups.
- Do **not** set `ui.static_path` / `ui.templates_path` in the template. Those were legacy bind-mount paths (`/etc/searxng/custom/...`); pointing them at a missing or partial directory makes the native SearXNG reject the config (`Invalid settings.yml`) and never boot.

## How it just works (user education)
After downloading Searxly, the user taps **Start local search** in onboarding (or Settings → Instances). The bundled runtime boots in a few seconds — nothing to install. There is no Docker requirement, no daemon, and no CLI to configure.

An optional "Manual / advanced" disclosure is also surfaced in onboarding and Settings → Instances for power users who want folder-only creation or a custom local URL.
