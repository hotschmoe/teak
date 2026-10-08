#!/usr/bin/env node
// Web startup profile: serve a zunk `dist/`, load it in headless Chromium and print where the time to first
// frame goes, from the `zunk:*` performance marks the generated JS emits plus Navigation / Resource Timing.
//
//   cd tools && npm ci
//   node tools/web-startup.mjs <dist-dir> [--runs 3] [--baseline <dist-dir>] [--chrome PATH]
//
// With --baseline, both dists are measured alternately (fresh browser per sample, so every sample is a
// cold start and machine noise hits both equally) and the table shows medians side by side.
// `first-cb` is a probe that needs no marks (a wrapped requestAnimationFrame: the end of the first frame
// callback), so older builds can be compared too.
//
// Phases (ms from navigation start, median of the runs):
//   html       document response end
//   wasm-get   wasm response end (download; compile overlaps it with instantiateStreaming)
//   wasm-ready streaming compile + instantiate finished
//   gpu-ready  navigator.gpu adapter + device acquired
//   init       exports.init() (teak Host/Gpu/Runtime construction: shaders, pipelines, fonts, first layout)
//   first-frame the first frame callback returned
//   pipelines  JS-side createShaderModule / createRenderPipeline time and counts (inside init)
// Env: WEBSHOT_ANGLE=vulkan on hosts whose SwiftShader needs it (see webshot.mjs).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import puppeteer from 'puppeteer-core';

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const valueFlags = ['--runs', '--chrome', '--baseline'];
const pos = argv.filter((a, i) => !a.startsWith('--') && !valueFlags.includes(argv[i - 1]));
if (pos.length < 1) { console.error('usage: web-startup.mjs <dist-dir> [--runs N] [--chrome PATH]'); process.exit(2); }
const root = path.resolve(pos[0]);
const runs = Number(opt('--runs', 3));
const baselineDir = opt('--baseline') ? path.resolve(opt('--baseline')) : null;
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


function serve(root) {
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
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r(server)));
}

const flags = ['--no-sandbox', '--disable-dev-shm-usage', '--hide-scrollbars', '--window-size=1280,800',
  '--ignore-gpu-blocklist', '--enable-unsafe-webgpu', '--enable-webgpu-developer-features',
  '--enable-unsafe-swiftshader', '--enable-features=Vulkan,WebGPU', '--use-vulkan=swiftshader',
  '--use-webgpu-adapter=swiftshader', `--use-angle=${process.env.WEBSHOT_ANGLE || 'swiftshader'}`];

/// One cold sample: a fresh browser, one page.
async function sample(server) {
  const url = `http://127.0.0.1:${server.address().port}/`;
  const browser = await puppeteer.launch({ executablePath: chrome, headless: true, protocolTimeout: 120000, args: flags });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 800 });
    await page.evaluateOnNewDocument(() => {
      const raf = window.requestAnimationFrame.bind(window);
      window.__firstCb = null;
      window.requestAnimationFrame = (cb) => raf((t) => { cb(t); if (window.__firstCb === null) window.__firstCb = performance.now(); });
    });
    page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));
    await page.goto(url, { waitUntil: 'load', timeout: 120000 });
    await page.waitForFunction(() => window.__firstCb !== null, { timeout: 120000 });
    await new Promise((r) => setTimeout(r, 250));
    return await page.evaluate(() => {
      const at = (n) => { const e = performance.getEntriesByName(n)[0]; return e ? e.startTime : null; };
      const nav = performance.getEntriesByType('navigation')[0];
      const wasm = performance.getEntriesByType('resource').find((r) => r.name.endsWith('.wasm'));
      return {
        html: nav.responseEnd, wasm_get: wasm ? wasm.responseEnd : null, wasm_bytes: wasm ? wasm.encodedBodySize : null,
        wasm_ready: at('zunk:wasm-ready'), gpu_ready: at('zunk:gpu-ready'), init_end: at('zunk:init-end'),
        first_cb: window.__firstCb, stats: window.__zunkStats || null,
      };
    });
  } finally {
    await browser.close();
  }
}

const med = (xs) => { const v = xs.filter((x) => x != null).sort((a, b) => a - b); return v.length ? v[Math.floor(v.length / 2)] : null; };
const servers = [await serve(root)];
if (baselineDir) servers.push(await serve(baselineDir));
const results = servers.map(() => []);
try {
  for (let i = 0; i < runs; i++) {
    for (let k = 0; k < servers.length; k++) results[k].push(await sample(servers[k]));
  }
} finally {
  servers.forEach((s) => s.close());
}
const cols = baselineDir ? ['baseline', 'this'] : ['this'];
const order = baselineDir ? [1, 0] : [0];
console.log(`[startup] ${runs} cold samples each (fresh browser), medians, ms from navigation start; wasm ${(med(results[0].map((s) => s.wasm_bytes)) / 1024).toFixed(0)} KiB`);
console.log('  phase'.padEnd(14) + cols.map((c) => c.padStart(10)).join(''));
const line = (name, key) => console.log(('  ' + name).padEnd(14) + order.map((k) => { const v = med(results[k].map((s) => s[key])); return (v == null ? '-' : v.toFixed(0)).padStart(10); }).join(''));
line('html', 'html');
line('wasm-get', 'wasm_get');
line('wasm-ready', 'wasm_ready');
line('gpu-ready', 'gpu_ready');
line('init-end', 'init_end');
line('first-cb', 'first_cb');
for (let k = 0; k < servers.length; k++) {
  const all = results[k].map((s) => s.first_cb.toFixed(0)).join(', ');
  console.log(`  ${cols[order.indexOf(k)] ?? ''} first-cb samples: ${all}`);
}
const st = results[0].find((s) => s.stats)?.stats;
if (st) console.log(`  gpu objects (this): ${st.shaders} shader modules ${st.shaderMs.toFixed(1)} ms, ${st.pipelines} render pipelines ${st.pipelineMs.toFixed(1)} ms (JS side, inside init)`);
