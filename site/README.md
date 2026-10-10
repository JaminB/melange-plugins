# melange-plugins site

<!--
The plugins catalogue site (GitHub Pages, https://jaminb.github.io/melange-plugins/). This is the one place in this
repo that uses npm: the site is built only in CI by .github/workflows/pages.yml and is never part of a plugin release.
-->

An [Astro Starlight](https://starlight.astro.build/) site built from the repo's own data: `../index.json` (what the
in-game Store reads), `../plugins/<id>/` (README, CHANGELOG, store.json, LICENSE, screenshots), `../schema/`,
`../policy/`, `../CONTRIBUTING.md` and `../README.md`. It is built only in CI by the Pages workflow and is never
shipped in a release.

```sh
npm ci
npm run check   # drift check: every plugin in index.json has README.md and store.json, every page generates
npm run dev     # generate, then astro dev
npm run build   # generate, then astro build (output in dist/)
npm run generate  # generate only
npm run check:links  # after build: every /melange-plugins/ link in dist/ resolves to a file
```

`scripts/prebuild.mjs` runs the generators below; each can also be run on its own (`node scripts/<name>.mjs`) and
cleans its own output first. Everything they write is gitignored; never commit it.

| Script | Writes |
| --- | --- |
| `catalogue.mjs` | `src/data/catalogue.json` (landing page cards) |
| `plugin-pages.mjs` | `src/content/docs/plugins/<id>.md`, images in `public/plugins/<id>/` |
| `publish-docs.mjs` | `src/content/docs/publish/` (CONTRIBUTING, schema references, policy) |
| `about.mjs` | `src/content/docs/about.md` (README's Privacy and Licence) |

`scripts/sidebar.mjs` exports the Starlight sidebar, built from `../index.json`. `scripts/lib/schema-md.mjs` is a copy
of the Melange site's schema renderer; keep the two in sync.

Look and feel: `src/styles/theme.css` and the SVGs in `src/assets/` are the "Field Manual" theme shared with the
Melange site (keep `theme.css` a verbatim copy); this site's additions are in `src/styles/site.css`. Fonts are
self-hosted from the @fontsource packages. `src/components/` holds the Starlight overrides (Header with the site nav,
Footer with the non-affiliation notice, Hero for the landing page, MobileMenuFooter) and the catalogue card;
`src/pages/index.astro` is the landing page and its category/text filter (plain JS, state in the URL hash).
