# Social preview image

Generates `site/assets/og-image.png` (1200×630) and
`site/assets/og-image@2x.png` (2400×1260) for the landing page and social previews.

```bash
cd scripts/og
npm i -D playwright && npx playwright install chromium   # one-time
node render.mjs
```

`render.mjs` opens `template.html` (self-contained, dark "midnight terminal"
design that mirrors the landing page) in headless Chromium and writes both
sizes. To tweak the card, edit `template.html` and re-run.

`icon.png` here is a copy of the app icon used by the template; `node_modules`
and the npm manifests are gitignored.
