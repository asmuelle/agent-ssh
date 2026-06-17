// Render the social-preview card to a 1200x630 PNG with Playwright/Chromium.
// Usage: node scripts/og/render.mjs
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const template = "file://" + join(here, "template.html");
const out = join(here, "..", "..", "site", "assets", "og-image.png");

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 2,
});
await page.goto(template, { waitUntil: "networkidle" });
await page.waitForTimeout(250);
await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1200, height: 630 } });
await browser.close();
console.log("wrote", out);
