// Read only bounded book/list structure in the installed app's WebView.
// No cookies, account forms, raw HTML or whole-document text leave the page.
const fs = require('node:fs');
const path = require('node:path');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function connectPage() {
  const targets = await (await fetch('http://127.0.0.1:9335/json/list')).json();
  const target = targets.find(candidate => candidate.type === 'page' && candidate.url === 'about:blank');
  if (!target) throw new Error('Idle WebView not found; stop before any navigation');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let serial = 0;
  const pending = new Map();
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timeout);
    if (message.error) request.reject(new Error(message.error.message));
    else request.resolve(message.result);
  };
  function call(method, params = {}) {
    const id = ++serial;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { pending.delete(id); reject(new Error('CDP command timeout')); }, 10000);
      pending.set(id, { resolve, reject, timeout });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(fn) {
    const response = await call('Runtime.evaluate', { expression: `(${fn.toString()})()`, returnByValue: true });
    if (response.exceptionDetails) throw new Error('Bounded DOM evaluation failed');
    return response.result.value;
  }
  async function extract(script) {
    const response = await call('Runtime.evaluate', { expression: script, returnByValue: true });
    if (response.exceptionDetails) throw new Error('Book extraction failed');
    return JSON.parse(response.result.value);
  }
  return { call, evaluate, extract, close: () => socket.close() };
}

async function main() {
  const target = process.argv[2];
  const url = new URL(target);
  if (url.origin !== 'https://www.wenku8.net' ||
      !['/modules/article/search.php', '/modules/article/tags.php',
        '/modules/article/toplist.php', '/modules/article/articlelist.php'].includes(url.pathname)) {
    throw new Error('Only configured-origin book lists may be inspected');
  }
  const page = await connectPage();
  try {
    await page.call('Page.navigate', { url: target });
    let loaded = false;
    for (let attempt = 0; attempt < 60; attempt++) {
      await delay(500);
      const state = await page.evaluate(() => ({ url: location.href, ready: document.readyState === 'complete' }));
      if (state.url !== 'about:blank' && state.ready) { loaded = true; break; }
    }
    if (!loaded) throw new Error('List navigation timed out');
    const result = await page.evaluate(() => {
      const content = document.querySelector('#content');
      const text = content ? content.innerText : '';
      const books = Array.from((content || document.createElement('div')).querySelectorAll('a'))
        .filter(anchor => {
          try { const link = new URL(anchor.href); return link.origin === location.origin && /^\/book\/[1-9][0-9]*\.htm$/.test(link.pathname); }
          catch (_) { return false; }
        });
      const samples = books.slice(0, 4).map(anchor => ({
        href: anchor.getAttribute('href'),
        title: (anchor.getAttribute('title') || '').slice(0, 120),
        text: (anchor.textContent || '').trim().slice(0, 120),
        image: anchor.querySelector('img')?.getAttribute('src') || null,
        parentTag: anchor.parentElement?.tagName,
      }));
      return {
        url: location.href,
        gridCount: document.querySelectorAll('table.grid').length,
        gridHeader: Array.from(document.querySelectorAll('#content table.grid tr:first-child th, #content table.grid tr:first-child td'))
          .slice(0, 8).map(cell => cell.textContent.trim().slice(0, 100)),
        oldCoverSelectorCount: document.querySelectorAll('table.grid tr td>div div>a>img').length,
        bookLinks: books.length,
        pagination: document.querySelector('#pagestats')?.textContent?.trim().slice(0, 40) || null,
        noResults: /没有符合条件|沒有符合條件|没有找到|沒有找到|未找到|没有搜索|沒有搜索|无搜索结果|無搜尋結果/.test(text),
        tooShort: /至少|两个|兩個|2个|2個/.test(text),
        rateLimited: /间隔|間隔|频繁|頻繁|稍后|稍後/.test(text),
        samples,
      };
    });
    const name = process.argv[3] || 'online-list-structure';
    if (!/^[a-z0-9-]+$/.test(name)) throw new Error('Unsafe report name');
    const out = path.resolve(`build/wenku8-0.1.14/${name}.json`);
    const extractor = path.resolve('build/wenku8-0.1.14/list-extractor.js');
    if (fs.existsSync(extractor)) {
      const extraction = await page.extract(fs.readFileSync(extractor, 'utf8'));
      fs.writeFileSync(path.resolve(`build/wenku8-0.1.14/${name}-extraction.json`), JSON.stringify(extraction, null, 2));
      result.extractedRecords = extraction.data?.records?.length;
      result.extractedFirstTitle = extraction.data?.records?.[0]?.title;
    }
    fs.writeFileSync(out, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  } finally {
    await page.call('Page.navigate', { url: 'about:blank' });
    page.close(); // Disconnect only; do not close the Android WebView.
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
