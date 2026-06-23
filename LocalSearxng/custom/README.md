# Searxly Premium Web Theme

Stark monochrome (black/grey/white), extreme minimalism, massive negative space.

Inspired by the official xAI website, Grok interface, and SpaceX’s futuristic restraint.

## Structure
- `templates/simple/` — Jinja overrides (base, index, search, results, result_templates)
- `static/themes/simple/searxly.css` — the complete design system + presentation layer

## Key Design Choices (2026)
- No colored accents whatsoever (pure monochrome as directed)
- Result titles: large (20.5px), bold, commanding with refined hover lift
- URLs: tiny, muted, refined sans (not mono), zero pills/favicons/tags
- Generous but calibrated 52px vertical rhythm between results (luxurious without sparsity)
- Contextual search bar: heroic + tall on home, refined + compact on results
- Beautiful soft-white focus ring + glow on the search bar
- Slim elegant 48px top nav
- Image results: clean minimalist grid with subtle depth on hover
- Home wordmark with premium tracking + quiet tagline

Recent tweaks focused on rhythm, typography precision, contextual search bar sizing, image grid refinement, and overall "expensive calm" feel.

## Updating on SearXNG Upgrades
1. Copy the upstream `simple` theme from the bundled runtime:
   `cp -R Searxly.app/Contents/Resources/searxng-runtime/python/lib/python3.12/site-packages/searx/templates/simple .` (or equivalent)
2. Re-apply our minimal overrides + re-test the CSS selectors.

Note: the native instance serves SearXNG's complete built-in simple theme, and Searxly renders its own native SwiftUI SERP from the JSON API — this overlay is kept for reference and for users who browse the SearXNG web UI directly.

Maintained as part of the Searxly project.
