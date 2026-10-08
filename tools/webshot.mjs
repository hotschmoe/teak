#!/usr/bin/env node
// Web smoke test: serve a zunk `dist/`, load it in headless Chromium with
// software (SwiftShader) WebGPU, assert no page errors and a non-blank canvas,
// and write a screenshot.
//
//   cd tools && npm ci
//   node tools/webshot.mjs <dist-dir> <out.png> [--wait-ms 3000] [--width 1280 --height 800]
//        [--min-colors 8] [--chrome /path/to/chrome]
//
// Chrome is found via --chrome, $CHROME_PATH, then google-chrome / chromium on
// PATH. Exit: 0 ok, 1 check failed, 2 usage.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import puppeteer from 'puppeteer-core';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const valueFlags = ['--wait-ms', '--width', '--height', '--min-colors', '--chrome', '--args'];
const pos = argv.filter((a, i) => !a.startsWith('--') && !valueFlags.includes(argv[i - 1]));
if (pos.length < 2) {
  console.error('usage: webshot.mjs <dist-dir> <out.png> [--wait-ms N] [--width W --height H] [--min-colors N] [--chrome PATH] [--args "--flag ..."] [--page-shot]');
  process.exit(2);
}
const root = path.resolve(pos[0]);
const out = pos[1];
const waitMs = Number(opt('--wait-ms', 3000));
const width = Number(opt('--width', 1280));
const height = Number(opt('--height', 800));
const minColors = Number(opt('--min-colors', 8));

function findChrome() {
  const cands = [opt('--chrome'), process.env.CHROME_PATH];
  for (const name of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    try { cands.push(execFileSync('which', [name], { encoding: 'utf8' }).trim()); } catch {}
  }
  return cands.find((c) => c && fs.existsSync(c));
}
const chrome = findChrome();
if (!chrome) { console.error('no Chrome/Chromium found (set CHROME_PATH or --chrome)'); process.exit(2); }

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.wgsl': 'text/plain', '.ttf': 'font/ttf',
};
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

const browser = await puppeteer.launch({ dumpio: process.env.WEBSHOT_DUMPIO === "1",
  executablePath: chrome,
  headless: true,
  protocolTimeout: 120000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--hide-scrollbars', `--window-size=${width},${height}`,
    '--ignore-gpu-blocklist', '--enable-unsafe-webgpu', '--enable-webgpu-developer-features',
    '--enable-unsafe-swiftshader', '--enable-features=Vulkan,WebGPU', '--use-vulkan=swiftshader',
    '--use-webgpu-adapter=swiftshader', '--use-angle=vulkan', ...(opt('--args', '').split(/\s+/).filter(Boolean))],
});
const problems = [];
try {
  const page = await browser.newPage();
  await page.setViewport({ width, height });
  page.on('console', (m) => console.log(`[console.${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => { problems.push(`pageerror: ${e.message || e}`); console.log(`[pageerror] ${e.stack || e}`); });
  page.on('requestfailed', (r) => { problems.push(`requestfailed: ${r.url()}`); console.log(`[requestfailed] ${r.url()}`); });
  page.on('response', (r) => { if (r.status() >= 400) { problems.push(`http ${r.status()}: ${r.url()}`); console.log(`[http ${r.status()}] ${r.url()}`); } });

  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  const adapter = await page.evaluate(async () => {
    if (!navigator.gpu) return 'navigator.gpu missing';
    const a = await navigator.gpu.requestAdapter();
    return a ? `ok ${a.info?.architecture ?? ''}` : 'requestAdapter() returned null';
  });
  console.log(`[webgpu] ${adapter}`);
  if (!adapter.startsWith('ok')) problems.push(`WebGPU unavailable: ${adapter}`);
  await new Promise((r) => setTimeout(r, waitMs));

  const canvas = argv.includes('--page-shot') ? null : await page.$('canvas');
  const png = canvas ? await canvas.screenshot({ type: 'png' }) : await page.screenshot({ type: 'png' });
  fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
  fs.writeFileSync(out, png);
  console.log(`[shot] wrote ${out} (${canvas ? 'canvas element' : 'full page, no <canvas>'})`);
  if (!canvas && !argv.includes('--page-shot')) problems.push('no <canvas> element on page');

  // Decode the PNG in a scratch page and measure pixel variance there.
  const scratch = await browser.newPage();
  const stats = await scratch.evaluate(async (b64) => {
    const bytes = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
    const img = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
    const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
    const ctx = c.getContext('2d'); ctx.drawImage(img, 0, 0);
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    const colors = new Set(); let sum = 0, sum2 = 0; const n = d.length / 4;
    for (let i = 0; i < d.length; i += 4) {
      colors.add((d[i] << 16) | (d[i + 1] << 8) | d[i + 2]);
      const l = 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
      sum += l; sum2 += l * l;
    }
    const mean = sum / n;
    return { w: img.width, h: img.height, colors: colors.size, mean, std: Math.sqrt(Math.max(0, sum2 / n - mean * mean)) };
  }, Buffer.from(png).toString('base64'));
  console.log(`[pixels] ${JSON.stringify(stats)}`);
  if (stats.colors < minColors || stats.std < 1) problems.push(`canvas looks blank (colors=${stats.colors}, luma std=${stats.std.toFixed(2)})`);
} finally {
  await browser.close();
  server.close();
}
if (problems.length) { console.error('WEBSHOT FAIL:\n  ' + problems.join('\n  ')); process.exit(1); }
console.log('WEBSHOT OK');
