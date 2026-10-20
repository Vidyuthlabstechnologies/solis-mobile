// Renders the marketing kit: sales sheet PDF (US Letter) and 5 carousel PNGs (1080x1350).
//   node marketing/kit/tools/render.cjs
// Uses puppeteer-core from marketing/video/node_modules and the installed Chrome.
const path = require("path");
const { pathToFileURL } = require("url");
const KIT = path.join(__dirname, "..");
const puppeteer = require(path.join(KIT, "..", "video", "node_modules", "puppeteer-core"));
const CHROME = process.env.CHROME || "C:/Program Files/Google/Chrome/Application/chrome.exe";

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: "new", args: ["--allow-file-access-from-files"] });
  const page = await browser.newPage();

  const sheet = pathToFileURL(path.join(KIT, "src", "sales-sheet.html")).href;
  await page.goto(sheet, { waitUntil: "networkidle0" });
  await page.evaluateHandle("document.fonts.ready");
  await page.pdf({ path: path.join(KIT, "SOLIS-Sales-Sheet.pdf"), width: "8.5in", height: "11in", printBackground: true, pageRanges: "1" });
  await page.setViewport({ width: 816, height: 1056, deviceScaleFactor: 1.5 });
  await page.screenshot({ path: path.join(KIT, "src", "sales-sheet-preview.png") });
  console.log("SOLIS-Sales-Sheet.pdf");

  await page.setViewport({ width: 1080, height: 1350, deviceScaleFactor: 1 });
  const car = pathToFileURL(path.join(KIT, "src", "carousel.html")).href;
  for (let s = 1; s <= 5; s++) {
    await page.goto(`${car}?s=${s}`, { waitUntil: "networkidle0" });
    await page.evaluateHandle("document.fonts.ready");
    const out = path.join(KIT, "carousel", `solis-carousel-${s}.png`);
    await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1080, height: 1350 } });
    console.log(path.basename(out));
  }
  await browser.close();
})();
