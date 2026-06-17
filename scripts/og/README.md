# Social preview image

Generates `site/assets/og-image.png` (1200×630) — the Open Graph / Twitter card
used by the landing page and by GitHub's social preview.

```bash
cd scripts/og
npm i -D playwright && npx playwright install chromium   # one-time
node render.mjs
```

`render.mjs` opens `template.html` (self-contained, dark "midnight terminal"
design that mirrors the landing page) in headless Chromium at 2× and writes the
PNG. To tweak the card, edit `template.html` and re-run. Re-downscale to the
canonical 1200×630 if you want an exact-size copy:

```bash
sips -z 630 1200 ../../site/assets/og-image.png
```

`icon.png` here is a copy of the app icon used by the template; `node_modules`
and the npm manifests are gitignored.
