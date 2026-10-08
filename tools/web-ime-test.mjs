#!/usr/bin/env node
// Web IME acceptance test: drive an input-method composition into a teak app in
// headless Chromium through the DevTools protocol and screenshot each stage.
//
//   cd tools && npm ci
//   node tools/web-ime-test.mjs <dist-dir> <out-prefix> --click X,Y [--composition TEXT] [--commit TEXT]
//        [--wait-ms 2500] [--width 1280 --height 800] [--chrome PATH]
//
// Stages (PNG per stage, `<out-prefix>-<stage>.png`):
//   focused   the app is idle with a focused text field (the hidden <textarea> holds DOM focus)
//   preedit   after Input.imeSetComposition: the preedit shows inline, underlined, at the caret
//   committed after Input.insertText: the preedit is replaced by the committed text, once
//   cancel    a second composition cancelled with an empty imeSetComposition + Escape: nothing inserted
// Checks: no page errors; the hidden field exists and is focused; the three stages differ pixel-wise
// (preedit drawn; commit changes the content; cancel returns to the committed image).
// Exit: 0 ok, 1 check failed, 2 usage.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import puppeteer from 'puppeteer-core';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const valueFlags = ['--click', '--composition', '--commit', '--wait-ms', '--width', '--height', '--chrome'];
const pos = argv.filter((a, i) => !a.startsWith('--') && !valueFlags.includes(argv[i - 1]));
if (pos.length < 2 || !opt('--click')) {
  console.error('usage: web-ime-test.mjs <dist-dir> <out-prefix> --click X,Y [--composition TEXT] [--commit TEXT] [--wait-ms N] [--width W --height H] [--chrome PATH]');
  process.exit(2);
}
const root = path.resolve(pos[0]);
const prefix = pos[1];
const [cx, cy] = opt('--click').split(',').map(Number);
const composition = opt('--composition', 'にほん');
const commit = opt('--commit', '日本');
const waitMs = Number(opt('--wait-ms', 2500));
const width = Number(opt('--width', 1280));
const height = Number(opt('--height', 800));

const chrome = [opt('--chrome'), process.env.CHROME_PATH,
  ...['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser'].map((n) => { try { return execFileSync('which', [n], { encoding: 'utf8' }).trim(); } catch { return null; } }),
].find((c) => c && fs.existsSync(c));
if (!chrome) { console.error('no Chrome/Chromium found (set CHROME_PATH or --chrome)'); process.exit(2); }

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  let file;
  try { file = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname)); } catch { res.writeHead(400).end(); return; }
  if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
  if (file === path.join(root, 'favicon.ico')) { res.writeHead(204).end(); return; }
  try {
    if (fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  } catch { res.writeHead(404).end('not found'); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await puppeteer.launch({
  executablePath: chrome, headless: true, protocolTimeout: 120000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--hide-scrollbars', `--window-size=${width},${height}`,
    '--ignore-gpu-blocklist', '--enable-unsafe-webgpu', '--enable-webgpu-developer-features',
    '--enable-unsafe-swiftshader', '--enable-features=Vulkan,WebGPU', '--use-vulkan=swiftshader',
    '--use-webgpu-adapter=swiftshader', `--use-angle=${process.env.WEBSHOT_ANGLE || 'swiftshader'}`],
});
const problems = [];
// Number of pixels that differ between two PNGs (decoded in a scratch page).
async function pixelDiff(browser, a, b) {
  const scratch = await browser.newPage();
  try {
    return await scratch.evaluate(async (x, y) => {
      const load = async (b64) => {
        const bytes = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
        const img = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
        const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
        const ctx = c.getContext('2d'); ctx.drawImage(img, 0, 0);
        return ctx.getImageData(0, 0, c.width, c.height).data;
      };
      const [da, db] = [await load(x), await load(y)];
      let n = 0;
      for (let i = 0; i < da.length; i += 4) if (da[i] !== db[i] || da[i + 1] !== db[i + 1] || da[i + 2] !== db[i + 2]) n++;
      return n;
    }, Buffer.from(a).toString('base64'), Buffer.from(b).toString('base64'));
  } finally { await scratch.close(); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hashes = {};
const pngs = {};
try {
  const page = await browser.newPage();
  await page.setViewport({ width, height });
  page.on('pageerror', (e) => { problems.push(`pageerror: ${e.message || e}`); console.log(`[pageerror] ${e.stack || e}`); });
  page.on('console', (m) => { if (m.type() === 'error') console.log(`[console.error] ${m.text()}`); });
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await sleep(waitMs);

  const shot = async (stage) => {
    await sleep(500); // a couple of frames
    const png = await page.screenshot({ type: 'png' });
    fs.mkdirSync(path.dirname(path.resolve(prefix)), { recursive: true });
    fs.writeFileSync(`${prefix}-${stage}.png`, png);
    pngs[stage] = png;
    hashes[stage] = crypto.createHash('sha1').update(png).digest('hex');
    console.log(`[shot] ${prefix}-${stage}.png`);
  };

  await page.mouse.click(cx, cy);
  await sleep(600);
  const dom = await page.evaluate(() => {
    const ta = document.querySelector('textarea[data-zunk-ime]');
    return { exists: !!ta, focused: !!ta && document.activeElement === ta };
  });
  console.log(`[ime] hidden field ${JSON.stringify(dom)}`);
  if (!dom.exists) problems.push('no hidden IME <textarea>: the bridge never activated');
  else if (!dom.focused) problems.push('the hidden IME <textarea> does not hold focus after clicking the field');
  await shot('focused');

  const cdp = await page.createCDPSession();
  await cdp.send('Input.imeSetComposition', { text: composition, selectionStart: composition.length, selectionEnd: composition.length });
  await shot('preedit');

  await cdp.send('Input.insertText', { text: commit });
  await shot('committed');

  await cdp.send('Input.imeSetComposition', { text: composition, selectionStart: composition.length, selectionEnd: composition.length });
  await sleep(300);
  await cdp.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 });
  await shot('cancel');

  if (hashes.preedit === hashes.focused) problems.push('preedit stage looks identical to the focused stage: no composition was drawn');
  if (hashes.committed === hashes.preedit) problems.push('committed stage looks identical to the preedit stage');
  if (hashes.committed === hashes.focused) problems.push('committed stage looks identical to the focused stage: nothing was inserted');
  // The caret blinks, so allow a few pixels of difference (a caret is ~2x20 px).
  const diff = await pixelDiff(browser, pngs.committed, pngs.cancel);
  console.log(`[ime] cancel vs committed: ${diff} differing pixels`);
  if (diff > 120) problems.push(`a cancelled composition changed the content (${diff} pixels differ from the committed stage)`);
} finally {
  await browser.close();
  server.close();
}
if (problems.length) { console.error('IME TEST FAIL:\n  ' + problems.join('\n  ')); process.exit(1); }
console.log('IME TEST OK');
