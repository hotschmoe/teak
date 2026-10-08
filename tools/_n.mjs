import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
import puppeteer from 'puppeteer-core';
const root = path.resolve(process.argv[2]); const out = process.argv[3]; const hook = process.argv[4] === 'hook';
const MIME={'.html':'text/html','.js':'text/javascript','.wasm':'application/wasm'};
const server = http.createServer((req,res)=>{let f=path.join(root,decodeURIComponent(new URL(req.url,'http://x').pathname)); try{ if(fs.statSync(f).isDirectory()) f=path.join(f,'index.html'); res.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'}); fs.createReadStream(f).pipe(res);}catch{res.writeHead(404).end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const b = await puppeteer.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']}); // no WebGPU flags
const p = await b.newPage(); await p.setViewport({width:900,height:500});
p.on('console',m=>console.log('[console]',m.text().slice(0,120)));
if (hook) await p.evaluateOnNewDocument(() => { window.zunkFallback = async (info) => { document.body.innerHTML = '<h1 id=fb>custom fallback: ' + info.reason + '</h1>'; return true; }; });
await p.goto(`http://127.0.0.1:${server.address().port}/`); await new Promise(r=>setTimeout(r,2500));
console.log('gpu?', await p.evaluate(()=>!!navigator.gpu), 'alert?', await p.evaluate(()=>!!document.getElementById('zunk-no-webgpu')), 'fb?', await p.evaluate(()=>!!document.getElementById('fb')));
fs.writeFileSync(out, await p.screenshot()); await b.close(); server.close();
