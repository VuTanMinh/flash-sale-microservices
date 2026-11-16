// Render Mermaid sequence diagrams (report/figures/<name>.mmd) to PNG with the
// report's sequence settings (mermaid-sequence.json), in headless Chromium.
// Used for the seq-fail-* figures; seq_logos.py then adds the technology badges.
//
//   node report/figures/render_mmd.cjs <mermaid.min.js> <chrome.exe> <name> [<name> ...]
//
// Needs the npm packages mermaid (11.4.1) and playwright-core, installed outside
// the repository; their paths are passed in or resolved from NODE_PATH.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

(async () => {
  const [mermaidJs, chrome, ...names] = process.argv.slice(2);
  const here = __dirname;
  const seqConfig = JSON.parse(fs.readFileSync(path.join(here, 'mermaid-sequence.json'), 'utf8'));
  const browser = await chromium.launch({ executablePath: chrome, headless: true });
  const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 1400, height: 1000 } });
  await page.setContent('<!doctype html><html><body style="margin:0;background:#fff"><div id="d"></div></body></html>');
  await page.addScriptTag({ path: mermaidJs });
  for (const name of names) {
    const src = fs.readFileSync(path.join(here, name + '.mmd'), 'utf8');
    await page.evaluate(async ({ src, cfg }) => {
      window.mermaid.initialize({ startOnLoad: false, theme: 'default', ...cfg });
      const { svg } = await window.mermaid.render('g' + Date.now(), src);
      document.getElementById('d').innerHTML = svg;
    }, { src, cfg: seqConfig });
    const el = await page.$('#d svg');
    await el.screenshot({ path: path.join(here, name + '.png') });
    console.log('rendered', name + '.png');
  }
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
