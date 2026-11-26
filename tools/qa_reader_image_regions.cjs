// Real Chromium replay of LiteTale's shipped offline paginator and image regions.
// Self-authored content only; all requests are intercepted, with no source logins.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE_PATH);
const root = path.resolve(__dirname, '..');
const out = path.join(root, 'output/playwright/reader-images-1.2.0');
fs.mkdirSync(out, {recursive:true});
const resource = 'a'.repeat(64) + '.png';
const imageUrl = 'https://litetale-epub.invalid/resource/' + resource;
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64');
const origin = 'https://litetale-epub.invalid';
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH});
  const report = [];
  try {
    for (const mode of ['flow','fixed','svg']) {
      const fixed = mode !== 'flow';
      const page = await browser.newPage({viewport:{width:640,height:900}});
      const external = [], errors = [];
      page.on('pageerror', e => errors.push(String(e)));
      const html = mode === 'svg' ? `<html><head><meta name="viewport" content="width=800,height=1000"/></head><body style="margin:0"><svg width="800" height="1000" viewBox="0 0 800 1000"><image href="${imageUrl}" x="100" y="200" width="200" height="100"/></svg></body></html>` : fixed
        ? `<html><head><meta name="viewport" content="width=800,height=1000"/></head><body style="margin:0"><img style="position:absolute;left:100px;top:200px;width:200px;height:100px;object-fit:contain" src="${imageUrl}"><img style="display:none" src="${imageUrl}"></body></html>`
        : `<html><head><style>body{margin:0}p{margin:0}.spacer{height:1100px}img{display:block;width:160px;height:160px}</style></head><body><p>Self-authored illustration geometry.</p><img src="${imageUrl}"><div class="spacer"></div><p>Second visible illustration.</p><img src="${imageUrl}"><img style="visibility:hidden" src="${imageUrl}"></body></html>`;
      await page.route('**/*', async route => {
        const u = new URL(route.request().url());
        if (u.origin !== origin) {external.push(u.href); return route.abort();}
        if(u.pathname === '/chapter') return route.fulfill({contentType:'text/html', body:html});
        if(u.pathname === '/resource/' + resource) return route.fulfill({contentType:'image/png', body:png});
        const known = {'/paginator.js':'lib/assets/epub_foliate_paginator.js','/engine.js':'lib/assets/epub_page_engine.js','/reader-serif.ttf':'lib/assets/fonts/LXGWNeoZhiSongPlus.ttf'};
        if (known[u.pathname]) return route.fulfill({body:fs.readFileSync(path.join(root,known[u.pathname])), contentType:u.pathname.endsWith('.js')?'text/javascript':'font/ttf'});
        if(u.pathname === '/index') return route.fulfill({contentType:'text/html', body:`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><script type="module" src="/paginator.js"></script><script src="/engine.js"></script>`});
        return route.abort();
      });
      await page.goto(origin + '/index');
      await page.evaluate(options => startEpub(options), {width:640,height:900,left:76,top:40,contentWidth:488,contentHeight:814,fontSize:20,lineHeight:1.5,paragraphGap:12,paper:'#ffffff',ink:'#000000',fixed,chapterUrl:origin+'/chapter'});
      await page.waitForFunction(() => window.EpubEngine?.ready || window.EpubEngine?.error, {timeout:20000});
      const info = await page.evaluate(() => ({ready:EpubEngine.ready,error:EpubEngine.error,pages:EpubEngine.pages.length,imageCount:EpubEngine.imageCount}));
      assert.equal(info.ready,true,JSON.stringify(info));
      const pages=[];
      for(let i=0;i<info.pages;i++) {
        await page.evaluate(i=>EpubEngine.select(i),i);
        const regions=await page.evaluate(()=>EpubEngine.imageRegions());
        for(const r of regions) {
          assert.equal(r.resource,resource);
          assert(r.rect.every(n=>Number.isFinite(n)&&n>=0&&n<=1));
          assert(r.rect[2]>r.rect[0] && r.rect[3]>r.rect[1]);
        }
        pages.push(regions);
        if(regions.length) await page.screenshot({path:path.join(out,`${mode}-${i}.png`)});
      }
      if(fixed) {
        assert.equal(pages[0].length,1,'hidden image must not receive a hit target');
        const r=pages[0][0].rect;
        [120/640,210/900,200/640,290/900].forEach((v,i)=>assert(Math.abs(v-r[i])<.002,`contain area wrong: ${r}`));
      } else {
        assert(info.pages>=2,'fixture must cover a real page boundary');
        assert(pages[0].length>=1,'first page illustration must be clickable');
        assert(pages.slice(1).some(p=>p.length),'later page illustration must be clickable');
      }
      assert.deepEqual(external,[]); assert.deepEqual(errors,[]);
      report.push({mode,fixed,...info,pages,external,errors}); await page.close();
    }
    fs.writeFileSync(path.join(out,'report.json'),JSON.stringify(report,null,2));
    console.log(JSON.stringify(report.map(x=>({mode:x.mode,pages:x.pages.length,hotspots:x.pages.flat().length,errors:x.errors}))));
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
