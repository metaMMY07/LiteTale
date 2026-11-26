// Offline CSS geometry replay using the repository's browser-fixture runtime.
// No book scripts, accounts, external requests or full text are exported.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);
const root = path.resolve(__dirname, '..');
const input = fs.readFileSync(process.argv[2], 'utf8');
const probe = fs.readFileSync(path.join(root, 'lib/assets/epub_artwork_probe.js'), 'utf8');
const out = path.join(root, 'output/playwright/epub-artwork');
fs.mkdirSync(out, {recursive:true});
const profiles = [
  [18, 1.55, '22px 2.2em 0'], [18, 1.6, '20px 2.2em 0'],
  [18, 1.55, '22px 2em 0'],
];
(async () => {
  const browser = await chromium.launch({executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH, headless:true});
  try {
    const context = await browser.newContext({viewport:{width:360,height:800},deviceScaleFactor:2});
    let current = input;
    await context.route('**/*', route => {
      const url = route.request().url();
      if (url === 'https://litetale-epub.invalid/reader-serif.ttf') {
        return route.fulfill({path:path.join(root, 'lib/assets/fonts/LXGWNeoZhiSongPlus.ttf'), contentType:'font/ttf'});
      }
      if (url === 'https://litetale-epub.invalid/index.html') {
        return route.fulfill({body:current, contentType:'text/html'});
      }
      return route.abort();
    });
    const results = [];
    for (let i=0; i<profiles.length; i++) {
      const [font, leading, padding] = profiles[i];
      current = input.replace('html{font-size:18px!important;}', 'html{font-size:'+font+'px!important;}')
        .replace('padding:22px 2.2em 0!important;', 'padding:'+padding+'!important;')
        .replace('line-height:1.55em!important;', 'line-height:'+leading+'em!important;');
      const page = await context.newPage();
      await page.goto('https://litetale-epub.invalid/index.html');
      await page.evaluate(() => document.fonts.ready);
      await page.evaluate(probe);
      const metrics = await page.evaluate(() => {
        const rect = e => {
          const box=e.getBoundingClientRect(), s=getComputedStyle(e);
          return {x:box.x,y:box.y,w:box.width,h:box.height,font:s.fontSize,
            leading:s.lineHeight,float:s.cssFloat,margin:s.margin};
        };
        return {body:rect(document.body), main:rect(document.querySelector('.fl')),
          right:Array.from(document.querySelectorAll('.fr')).map(rect),
          paragraphs:Array.from(document.querySelectorAll('.fl p')).map(rect),
          fonts:Array.from(document.fonts).map(f=>({family:f.family,status:f.status}))};
      });
      results.push({profile:i,font,leading,padding,metrics});
      assert(metrics.right[0].y <= metrics.main.y + 1, 'First vertical credit fell below title');
      assert(metrics.right[2].y >= metrics.main.y + metrics.main.h - 1,
        'Last credit should flow below the main title column');
      assert(metrics.right.every(r => r.y + r.h < 800), 'A credit is clipped by the page');
      const margins = metrics.right.map(r => r.margin);
      await page.evaluate(probe);
      const again = await page.evaluate(() => Array.from(document.querySelectorAll('.fr'))
        .map(e => getComputedStyle(e).margin));
      assert.deepEqual(again,margins,'Normalization is not idempotent');
      await page.screenshot({path:path.join(out, 'profile-'+i+'.png'),fullPage:true});
      await page.close();
    }
    fs.writeFileSync(path.join(out, 'geometry.json'),JSON.stringify(results,null,2));
    for (const r of results) console.log(JSON.stringify({profile:r.profile,font:r.font,
      leading:r.leading,padding:r.padding,main:r.metrics.main,right:r.metrics.right}));
    await context.close();
  } finally {await browser.close();}
})().catch(error => {console.error(error.message);process.exit(1);});
