// Renderizza ogni SVG in PNG 1024x1024 con Chromium.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

(async () => {
  const dir = path.join(__dirname, 'svg');
  const out = path.join(__dirname, 'png');
  fs.mkdirSync(out, { recursive: true });
  const names = JSON.parse(fs.readFileSync(path.join(dir, 'names.json')));
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
  for (const n of names) {
    const svg = fs.readFileSync(path.join(dir, n + '.svg'), 'utf8');
    await page.setContent(`<html><body style="margin:0">${svg}</body></html>`);
    await page.screenshot({ path: path.join(out, n + '.png'), clip: { x: 0, y: 0, width: 1024, height: 1024 } });
  }
  await browser.close();
  console.log('rendered', names.length);
})();
