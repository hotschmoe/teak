#!/usr/bin/env node
// rAF cost of a web example under scrolling: serve a zunk `dist/`, load it in headless Chromium,
// wrap requestAnimationFrame so every frame callback (wasm update + view + layout + render + the
// WebGPU command encoding, i.e. everything the page does per frame on the main thread) is timed, drive
// the mouse wheel over the page, and report per-frame JS time. Software (SwiftShader) WebGPU does the
// actual rasterization off the main thread, so this measures the app's own cost, not the GPU.
//
//   cd tools && npm ci
//   node tools/web-frame-bench.mjs <dist-dir> [--wheel X,Y] [--frames 240] [--delta 120] [--shot out.png]
//        [--click X,Y] [--keys ArrowDown,...] [--width 1100 --height 700] [--chrome PATH]
// Env: WEBSHOT_ANGLE=vulkan on hosts whose SwiftShader needs it (see webshot.mjs).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import puppeteer from 'puppeteer-core';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const valueFlags = ['--wheel', '--frames', '--delta', '--shot', '--click', '--keys', '--width', '--height', '--chrome'];
const pos = argv.filter((a, i) => !a.startsWith('--') && !valueFlags.includes(argv[i - 1]));
if (pos.length < 1) { console.error('usage: web-frame-bench.mjs <dist-dir> [--wheel X,Y] [--frames N] [--delta PX] [--shot out.png] [--click X,Y] [--keys K,K]'); process.exit(2); }
const root = path.resolve(pos[0]);
const width = Number(opt('--width', 1100)), height = Number(opt('--height', 700));
const frames = Number(opt('--frames', 240));
const delta = Number(opt('--delta', 120));
const [wx, wy] = opt('--wheel', '300,400').split(',').map(Number);

const chrome = [opt('--chrome'), process.env.CHROME_PATH,
  ...['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser'].map((n) => { try { return execFileSync('which', [n], { encoding: 'utf8' }).trim(); } catch { return null; } }),
].find((c) => c && fs.existsSync(c));
if (!chrome) { console.error('no Chrome/Chromium found (set CHROME_PATH or --chrome)'); process.exit(2); }

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.wasm': 'application/wasm', '.ttf': 'font/ttf' };
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
  executablePath: chrome, headless: true, protocolTimeout: 180000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--hide-scrollbars', `--window-size=${width},${height}`,
    '--ignore-gpu-blocklist', '--enable-unsafe-webgpu', '--enable-webgpu-developer-features',
    '--enable-unsafe-swiftshader', '--enable-features=Vulkan,WebGPU', '--use-vulkan=swiftshader',
    '--use-webgpu-adapter=swiftshader', `--use-angle=${process.env.WEBSHOT_ANGLE || 'swiftshader'}`],
});
const problems = [];
try {
  const page = await browser.newPage();
  await page.setViewport({ width, height });
  page.on('pageerror', (e) => { problems.push(`pageerror: ${e.message || e}`); console.log(`[pageerror] ${e.stack || e}`); });
  // Time every requestAnimationFrame callback.
  await page.evaluateOnNewDocument(() => {
    const raf = window.requestAnimationFrame.bind(window);
    window.__frameMs = [];
    window.requestAnimationFrame = (cb) => raf((t) => {
      const t0 = performance.now();
      cb(t);
      window.__frameMs.push(performance.now() - t0);
    });
  });
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await new Promise((r) => setTimeout(r, 3000));
  if (opt('--click')) {
    const [cx, cy] = opt('--click').split(',').map(Number);
    await page.mouse.click(cx, cy);
    await new Promise((r) => setTimeout(r, 300));
  }
  await page.mouse.move(wx, wy);
  await page.evaluate(() => { window.__frameMs.length = 0; });
  const profile = argv.includes('--profile');
  const cdp = profile ? await page.createCDPSession() : null;
  if (cdp) { await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', { interval: 200 }); await cdp.send('Profiler.start'); }
  const keys = (opt('--keys', '') || '').split(',').filter(Boolean);
  for (let i = 0; i < frames; i++) {
    if (keys.length) await page.keyboard.press(keys[i % keys.length]);
    else await page.mouse.wheel({ deltaY: delta });
    await new Promise((r) => setTimeout(r, 16));
  }
  await new Promise((r) => setTimeout(r, 500));
  if (cdp) {
    const { profile: prof } = await cdp.send('Profiler.stop');
    const self = new Map();
    const dts = prof.timeDeltas;
    const byId = new Map(prof.nodes.map((n) => [n.id, n]));
    prof.samples.forEach((id, i) => {
      const n = byId.get(id);
      const key = `${n.callFrame.functionName || '(anon)'} ${n.callFrame.url.split('/').pop()}`;
      self.set(key, (self.get(key) || 0) + (dts[i] || 0));
    });
    const total = [...self.values()].reduce((a, b) => a + b, 0);
    console.log('[profile] self time, top 14 (of ' + (total / 1000).toFixed(0) + ' ms sampled):');
    [...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 14).forEach(([k, v]) => console.log(`  ${(v / 1000).toFixed(1).padStart(8)} ms  ${k}`));
  }
  const ms = await page.evaluate(() => window.__frameMs.slice());
  if (!ms.length) problems.push('no animation frames ran');
  const sorted = [...ms].sort((a, b) => a - b);
  const q = (p) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];
  const mean = ms.reduce((a, b) => a + b, 0) / Math.max(1, ms.length);
  console.log(`[bench] ${ms.length} rAF callbacks: mean ${mean.toFixed(2)} ms, p50 ${q(0.5).toFixed(2)}, p95 ${q(0.95).toFixed(2)}, max ${sorted[sorted.length - 1]?.toFixed(2)}`);
  if (opt('--shot')) {
    fs.mkdirSync(path.dirname(path.resolve(opt('--shot'))), { recursive: true });
    fs.writeFileSync(opt('--shot'), await page.screenshot({ type: 'png' }));
    console.log(`[shot] ${opt('--shot')}`);
  }
} finally {
  await browser.close();
  server.close();
}
if (problems.length) { console.error('BENCH FAIL:\n  ' + problems.join('\n  ')); process.exit(1); }
