// Entirely local fixtures: all network requests are intercepted.
const assert = require('node:assert/strict');
async function main() {
  let input = ''; for await (const chunk of process.stdin) input += chunk;
  const scripts = JSON.parse(input);
  const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);
  const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH });
  try {
    const page = await browser.newPage();
    let mode = 'gbk', gets = 0, assets = 0, foreign = 0, hasSession = true;
    let releaseTail;
    const tailGate = new Promise(resolve => { releaseTail = resolve; });
    await page.route('**/*', async route => {
      const request = route.request(), url = new URL(request.url());
      if (url.origin === scripts.host && url.pathname === '/tail.js') {
        await tailGate;
        await route.fulfill({ contentType:'application/javascript', body:'' });
        return;
      }
      if (url.origin === scripts.host && url.pathname === '/modules/article/search.php') {
        await route.fulfill({ contentType:'text/html; charset=utf-8', body:
          '<title>Search</title><div id="content"><table class="grid"><tr><td>complete results</td></tr></table></div>'+
          '<div id="pagelink"><em id="pagestats">1/2</em><a class="last" href="?page=2">2</a></div><script src="/tail.js"></script>' });
        return;
      }
      if (url.origin !== scripts.host) { foreign++; await route.abort(); return; }
      if (url.pathname==='/modules/article/bookcase.php') {
        gets++;
        await route.fulfill({contentType:'text/html; charset=utf-8', body:
          '<div>qaPrivateAccountShouldNotLeavePage</div><select name="classlist"><option value="0">全部</option><option value="1">分组</option></select>'+
          '<table><tr><td class="odd"><input type="checkbox" value="20"></td><td><a href="/modules/article/readbookcase.php?aid=101&bid=20">fixture</a></td>'+
          '<td><a href="/modules/article/search.php?author=x">作者</a></td><td><a href="/modules/article/reader.php?aid=101&cid=19">章节</a></td></tr></table>'+
          '<img src="/unexpected-cover.png"><script>window.qaUnexpectedExecution=true</script>'});
        return;
      }
      if (url.pathname === '/') {
        const fetched = request.resourceType() === 'fetch';
        if (fetched) gets++;
        await route.fulfill({ contentType: 'text/html; charset=utf-8',
          headers: { 'set-cookie': 'qaWenku8Session=local-fixture; Path=/; Secure; SameSite=Lax' },
          body: '<meta charset="utf-8"><form action="/so.php" method="post"><input name="searchkey"><select name="searchtype"><option value="articlename">书名</option></select><input type="hidden" name="qaToken" value="preserved"></form>' + (fetched ? scripts.homeHtml : '') });
        return;
      }
      if (url.pathname !== '/novel/0/101/19.htm') { assets++; await route.abort(); return; }
      gets++; assert.equal(request.method(), 'GET');
      hasSession &&= (await request.allHeaders()).cookie?.includes('qaWenku8Session=local-fixture');
      if (mode === 'denied') { await route.fulfill({ status: 403, contentType: 'text/html', body: '<title>Just a moment</title>' }); return; }
      if (mode === 'limited') { await route.fulfill({ status:429, headers:{'Retry-After':'60'}, contentType:'text/html', body:'<title>Too many requests</title>' }); return; }
      if (mode === 'limited-date') { await route.fulfill({ status:429, headers:{'Retry-After':new Date(Date.now()+61000).toUTCString()}, contentType:'text/html', body:'' }); return; }
      if (mode === 'redirect') { await route.fulfill({ status: 302, headers: { location: 'https://foreign.invalid/login' } }); return; }
      if (mode === 'timeout') { await new Promise(resolve => setTimeout(resolve, 250)); await route.abort().catch(() => {}); return; }
      if (mode === 'large') { await route.fulfill({ contentType: 'text/html', body: 'x'.repeat(1024 * 1024 + 1) }); return; }
      const before = Buffer.from('<meta charset="gbk"><div id="content">');
      const after = Buffer.from('<script>window.qaUnexpectedExecution=true</script><img src="/image.png"></div>');
      const body = mode === 'gbk' ? Buffer.concat([before, Buffer.from([0xc4, 0xe3, 0xba, 0xc3]), after]) :
        Buffer.from('<meta charset="gbk"><div id="content">UTF8 正文</div>');
      await route.fulfill({ contentType: mode === 'gbk' ? 'text/html' : 'text/html; charset=utf-8', body });
    });
    await page.goto(scripts.host + '/', { waitUntil: 'domcontentloaded' });
    assert.equal(await page.evaluate(scripts.park), true);
    async function read(script = scripts.read) {
      assert.equal(await page.evaluate(script), true);
      await page.waitForFunction(() => window.__liteTaleDocumentRead?.pending === false);
      return JSON.parse(await page.evaluate(scripts.state));
    }
    let result = await read();
    const payload = JSON.parse(result.payload);
    assert.ok(payload.data.content.startsWith('你好'));
    assert.equal(payload.url, scripts.host + '/novel/0/101/19.htm');
    assert.equal(await page.evaluate(() => window.qaUnexpectedExecution), undefined);
    assert.equal(await page.evaluate(() => document.querySelector('#content')), null);
    assert.equal(await page.evaluate(() => document.querySelector('input[name=qaToken]').value), 'preserved');
    result = await read(scripts.bookshelfRead);
    const shelf=JSON.parse(result.payload);
    assert.equal(shelf.groups.length,2); assert.equal(shelf.items[0].aid,'101');
    assert.equal(shelf.items[0].bid,'20'); assert.equal(shelf.items[0].cid,'19');
    assert.equal(result.payload.includes('qaPrivateAccountShouldNotLeavePage'),false);
    assert.equal(await page.evaluate(() => window.qaUnexpectedExecution),undefined);
    await page.evaluate(scripts.park); // The inert page can be reused repeatedly.
    mode = 'utf8'; result = await read();
    assert.equal(JSON.parse(result.payload).data.content, 'UTF8 正文');
    mode = 'denied'; result = await read(); assert.equal(result.status, 403);
    mode = 'limited'; result = await read(); assert.equal(result.status,429); assert.equal(result.retryAfterSeconds,60);
    mode = 'limited-date'; result = await read(); assert.equal(result.status,429); assert.ok(result.retryAfterSeconds>=59 && result.retryAfterSeconds<=61);
    mode = 'redirect'; result = await read(); assert.equal(result.error, 'navigation');
    mode = 'large'; result = await read(); assert.equal(result.error, 'size');
    mode = 'timeout'; result = await read(scripts.shortRead); assert.equal(result.error, 'timeout');
    await page.waitForTimeout(300);
    // A cold empty context must recover the site's real form from its first
    // fetched home; later searches need no extra homepage navigation.
    await page.evaluate(html => { document.open(); document.write(html); document.close(); }, scripts.emptyContext);
    assert.equal(await page.evaluate(() => document.forms.length), 0);
    result = await read(scripts.homeRead);
    assert.ok(JSON.parse(result.payload).blocks.length > 0);
    assert.equal(await page.evaluate(scripts.park), true);
    assert.equal(await page.evaluate(() => document.querySelector('input[name=qaToken]').value), 'preserved');
    assert.equal(assets, 0, 'Detached documents must not fetch covers, scripts or styles');
    assert.equal(foreign, 0, 'Redirects must not send the session to another origin');
    assert.ok(hasSession, 'All reads must use the already established browser session');
    await page.goto(scripts.host + '/modules/article/search.php?searchtype=articlename&searchkey=Re', { waitUntil:'commit' });
    await page.waitForFunction(() => document.querySelector('#pagelink a.last'));
    const early = JSON.parse(await page.evaluate(scripts.pageState));
    assert.equal(early.searchReady, true);
    assert.equal(early.domReady, false, 'Result readiness must not depend on unrelated tail scripts');
    releaseTail();
    await page.waitForLoadState('domcontentloaded');
    await page.evaluate(() => {document.title='第429章';document.body.insertAdjacentHTML('afterbegin','<h1>第429章</h1>');});
    assert.equal(JSON.parse(await page.evaluate(scripts.pageState)).rateLimited,false,'A chapter number is not a response status');
    await page.evaluate(() => {document.title='429 Too Many Requests';});
    assert.equal(JSON.parse(await page.evaluate(scripts.pageState)).rateLimited,true);
    process.stdout.write(JSON.stringify({ passed: true, reads: gets, assetRequests: assets, foreignRequests: foreign, gbk: true, utf8: true, sessionPreserved: hasSession }));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
