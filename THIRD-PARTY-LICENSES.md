# Third-Party Licenses & Corresponding Source

The **Searxly application** (the SwiftUI/WebKit macOS app, its Swift source, and
brand assets) is licensed under the **PolyForm Noncommercial License 1.0.0** — see
[LICENSE](LICENSE).

That license does **not** apply to the third-party components Searxly bundles or
distributes. Those keep their own licenses. This document inventories them and
provides the written offer of Corresponding Source required by the GNU AGPL.

---

## 1. SearXNG (AGPL-3.0-or-later)

Searxly's private-search feature is powered by **SearXNG**, an independent
metasearch engine. Searxly bundles SearXNG as a self-contained Python runtime
and **runs it as a separate process** on `127.0.0.1`; the Searxly app communicates
with it over SearXNG's HTTP/JSON API. Searxly also distributes a modified SearXNG
theme and configuration overlay.

| | |
|---|---|
| **Component** | SearXNG metasearch engine |
| **Copyright** | © SearXNG contributors |
| **License** | GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`) |
| **Upstream** | https://github.com/searxng/searxng |
| **Bundled version** | `2026.6.23+e371371` |
| **Full license text** | [LocalSearxng/LICENSE](LocalSearxng/LICENSE) |

### Searxly's modifications to SearXNG

The following files in this repository are **derivative works of SearXNG** and are
therefore licensed under **AGPL-3.0-or-later** (not PolyForm):

- `LocalSearxng/custom/templates/simple/` — Jinja template overrides
  (`base.html`, `index.html`, `search.html`, `results.html`, `categories.html`,
  `result_templates/default.html`)
- `LocalSearxng/custom/static/themes/simple/searxly.css` — theme stylesheet
- `LocalSearxng/searxng/settings.yml.example` — settings overlay
- `LocalSearxng/searxng/limiter.toml` — limiter overlay

Runtime configuration changes (secret-key generation and local toggles) are
applied by `Searxly/Services/LocalSearxngManager+ConfigPatching.swift`; that
logic is visible in this source tree.

### Why the app itself remains under PolyForm

SearXNG runs as a **separate program** that Searxly launches and talks to over a
socket (HTTP/JSON). Under the FSF's own guidance, programs that communicate at
arm's length via sockets are normally separate works (mere aggregation), so the
AGPL's copyleft does not extend to Searxly's own Swift code. The AGPL **does**
govern the bundled SearXNG and the modifications listed above, which is why they
are licensed AGPL-3.0-or-later and their Corresponding Source is offered below.

### Written offer of Corresponding Source (AGPL §6)

> The Corresponding Source for the exact version of SearXNG bundled in any Searxly
> release — including Searxly's modifications — is available to anyone who receives
> Searxly. It is published here:
>
> - **Modifications** (theme + config overlay): the `LocalSearxng/` directory of
>   this repository — https://github.com/Searxly/Searxly-source-code
> - **Upstream engine source**, pinned to the bundled version
>   `2026.6.23+e371371`: https://github.com/searxng/searxng
> - Additionally, the complete SearXNG Python **source** ships inside every macOS
>   build at `Searxly.app/Contents/Resources/searxng-runtime/`.
>
> For at least three (3) years, the maintainer will also provide, on request, a
> complete machine-readable copy of the Corresponding Source for the SearXNG
> version distributed in a given release. Contact: the official **@Searxly**
> account on X.

You can regenerate a single Corresponding-Source archive with
[`scripts/make-searxng-corresponding-source.sh`](scripts/make-searxng-corresponding-source.sh).

---

## 2. Bundled Python runtime and PyPI packages

Each retains its own license (BSD/MIT/Apache-2.0/PSF/etc.). The individual license
texts ship with every build under:

```
Searxly.app/Contents/Resources/searxng-runtime/python/lib/python3.12/**/*.dist-info/
```

This includes, among others, Flask, Werkzeug, Jinja2, httpx, h2, Babel,
flask-babel, msgspec, and the CPython standard library.

---

## 3. Operator obligations checklist

Bundling AGPL software is permitted, but distributing and network-serving it carry
conditions. Keep these satisfied for each release:

- [x] Ship SearXNG's license text with the app (travels in the runtime `dist-info`
      and in `LocalSearxng/LICENSE`).
- [x] Mark Searxly's SearXNG modifications as AGPL (SPDX headers + this document).
- [x] Do not sublicense the SearXNG parts under a more restrictive
      (e.g. noncommercial) license — carved out in `README.md` and `NOTICE`.
- [ ] **Keep the public source current per release.** Ensure the `LocalSearxng/`
      overlay in the public repo, and the pinned upstream version, match whatever
      each shipped/updated build contains (Sparkle updates included).
- [ ] **Hosted instances → AGPL §13.** For any SearXNG you operate as a network
      service (e.g. `search.searxly.app`, used by the iOS client), you must offer
      its Corresponding Source — including your modifications — to its users. The
      standard way is to set SearXNG's `brand.git_url` (in that server's
      `settings.yml`) to your public modified-source URL, so the "source code"
      link in SearXNG's own UI points there. The local `127.0.0.1` instance on a
      user's own Mac does **not** trigger §13 (the user is the operator).
- [ ] **Paid/Maximum edition.** Charging money is fine under AGPL, but paying users
      must still receive the Corresponding Source of the (modified) SearXNG and may
      not be barred from redistributing that component. Do not frame the SearXNG
      portion as noncommercial or non-redistributable.
- [ ] *(Recommended, optional)* Surface an "Open-source licenses" / attribution
      screen in the app or on the website that names SearXNG, its AGPL license, and
      the source URL. (Not required to change app behavior — the notices already
      travel inside the bundle.)

---

*This document is provided for compliance transparency and is not legal advice.
For the commercial/paid edition, have an IP lawyer confirm the arrangement.*
