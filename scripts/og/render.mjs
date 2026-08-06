// Render the social-preview card to a 1200x630 PNG with Playwright/Chromium.
// Usage: node scripts/og/render.mjs
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const template = "file://" + join(here, "template.html");
const outputDirectory = join(here, "..", "..", "site", "assets");

const browser = await chromium.launch();
for (const [scale, fileName] of [[1, "og-image.png"], [2, "og-image@2x.png"]]) {
  const page = await browser.newPage({
    viewport: { width: 1200, height: 630 },
    deviceScaleFactor: scale,
  });
  await page.goto(template, { waitUntil: "networkidle" });
  await page.waitForTimeout(250);
  const output = join(outputDirectory, fileName);
  await page.screenshot({ path: output, clip: { x: 0, y: 0, width: 1200, height: 630 } });
  await page.close();
  console.log("wrote", output);
}
await browser.close();
