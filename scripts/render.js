// Render a page in headless Chromium and print what a user would see.
//
//   node scripts/render.js <url> [screenshot.png]
//
// Prints the page's visible text. Waits for the app to finish loading rather
// than for network idle, because pages with a live EventSource never go idle.
// Needs playwright-core (NODE_PATH) and a Chromium binary (CHROME).
const { chromium } = require("playwright-core");

(async () => {
  const [url, shot] = process.argv.slice(2);
  if (!url) {
    console.error("usage: render.js <url> [screenshot.png]");
    process.exit(2);
  }
  const browser = await chromium.launch({ executablePath: process.env.CHROME, args: ["--no-sandbox"] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(url, { waitUntil: "load", timeout: 15000 });
    // Wait until the wasm app has rendered something and nothing says "Loading".
    await page
      .waitForFunction(
        () => document.body && document.body.innerText.trim().length > 0 && !/Loading/i.test(document.body.innerText),
        null,
        { timeout: 10000 },
      )
      .catch(() => {});
    await page.waitForTimeout(500);
    if (shot) await page.screenshot({ path: shot, fullPage: false });
    const text = (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, " ").trim();
    for (const e of errors) console.log(`Error (page): ${e}`);
    console.log(text);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.log(`Error (render): ${e.message}`);
  process.exit(1);
});
