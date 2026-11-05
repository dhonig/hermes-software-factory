// End-to-end drag and drop check: drag a ready card to the blocked column of a board,
// then reload and confirm it stayed there. Also checks a refused drop leaves the card alone.
//
//   CHROME=... NODE_PATH=... node scripts/dragtest.js <base-url> <board-slug> <task-id>
//
// Run it against a COPY of a board (the fixture), never a live Hermes board.
const { chromium } = require("playwright-core");

(async () => {
  const [base, slug, id] = process.argv.slice(2);
  if (!base || !slug || !id) {
    console.error("usage: dragtest.js <base-url> <board-slug> <task-id>");
    process.exit(2);
  }
  const browser = await chromium.launch({ executablePath: process.env.CHROME, args: ["--no-sandbox"] });
  try {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
    page.on("dialog", (d) => d.accept());
    const card = `.column[data-status] [data-task-id="${id}"]`;
    const inColumn = (s) => page.locator(`.column[data-status="${s}"] [data-task-id="${id}"]`).count();
    const load = async () => {
      await page.goto(`${base}/boards/${slug}`, { waitUntil: "load", timeout: 15000 });
      await page.waitForSelector(card, { timeout: 10000 });
    };
    await load();
    if ((await inColumn("ready")) !== 1) throw new Error(`${id} is not in the ready column`);

    // A move Hermes can't do must be refused: ready -> running.
    await page.dragAndDrop(card, `.column[data-status="running"]`, { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(1000);
    await load();
    if ((await inColumn("ready")) !== 1) throw new Error("a refused drop to running moved the card");

    await page.dragAndDrop(card, `.column[data-status="blocked"]`, { timeout: 5000 });
    await page.waitForTimeout(6000); // the CLI takes a few seconds
    await load();
    if ((await inColumn("blocked")) !== 1) throw new Error(`${id} is not in blocked after the drop and a reload`);
    console.log(`ok: ${id} moved ready -> blocked and stayed there after a reload; drop on running refused`);
  } finally {
    await browser.close();
  }
})().catch((e) => { console.log(`FAIL: ${e.message}`); process.exit(1); });
