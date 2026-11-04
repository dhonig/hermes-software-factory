// End-to-end live update check: open a board page, change a task in the board's
// kanban.db, and confirm the page shows the change without a reload.
//
//   CHROME=... NODE_PATH=... node scripts/livetest.js <base-url> <board-slug> <kanban.db>
//
// Run it against a COPY of a board (e.g. the fixture), never a live Hermes board.
const { chromium } = require("playwright-core");
const { execFileSync } = require("child_process");

(async () => {
  const [base, slug, db] = process.argv.slice(2);
  if (!base || !slug || !db) {
    console.error("usage: livetest.js <base-url> <board-slug> <kanban.db>");
    process.exit(2);
  }
  const browser = await chromium.launch({ executablePath: process.env.CHROME, args: ["--no-sandbox"] });
  try {
    const page = await browser.newPage();
    await page.goto(`${base}/boards/${slug}`, { waitUntil: "load", timeout: 15000 });
    await page.waitForFunction(() => document.body.innerText.includes("ID:"), null, { timeout: 10000 });
    const probe = `LIVE-UPDATE-PROBE-${Date.now()}`;
    execFileSync("sqlite3", [db,
      `update tasks set title='${probe}' where id=(select id from tasks order by id limit 1);` +
      `insert into task_events(task_id, kind, payload, created_at) values ((select id from tasks order by id limit 1), 'edited', NULL, strftime('%s','now'));`]);
    for (let i = 0; i < 20; i++) {
      await page.waitForTimeout(500);
      if ((await page.evaluate(() => document.body.innerText)).includes(probe)) {
        console.log(`ok: page showed the change after ${(i + 1) * 0.5}s without a reload`);
        return;
      }
    }
    console.log("FAIL: page did not update within 10s of the change");
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})().catch((e) => { console.log(`FAIL: ${e.message}`); process.exit(1); });
