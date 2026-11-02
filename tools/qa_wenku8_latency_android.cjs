// Bounded timing probe for the installed app's own Wenku8 WebView.
// Forward only the current LiteTale PID's devtools socket to localhost:9335.
// Never record request headers, cookies, forms, account text or chapter content.
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

async function main() {
  const output = process.argv[2];
  const seconds = Number(process.argv[3] || 25);
  if (!output || seconds < 1 || seconds > 60) throw new Error('Output path and 1–60 second duration required');
  const targets = await (await fetch('http://127.0.0.1:9335/json/list')).json();
  const target = targets.find(t => t.type === 'page' && (t.url === 'about:blank' || t.url.startsWith('https://www.wenku8.net/')));
  if (!target) throw new Error('No LiteTale Wenku8 document found');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  const pending = new Map();
  const docs = new Map();
  const events = [];
  let serial = 0;
  const start = performance.now();
  const now = () => Math.round(performance.now() - start);
  function publicPath(value) {
    try {
      const u = new URL(value);
      return u.origin === 'https://www.wenku8.net' &&
        (/^\/(?:book\/\d+\.htm|novel\/\d+\/\d+\/(?:index|\d+)\.htm)$/.test(u.pathname) ||
         ['/', '/index.php', '/so.php', '/modules/article/search.php', '/modules/article/tags.php', '/modules/article/toplist.php', '/modules/article/articlelist.php'].includes(u.pathname)) ? u.pathname : null;
    } catch (_) { return null; }
  }
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const p = pending.get(message.id);
      if (!p) return;
      pending.delete(message.id); clearTimeout(p.timer);
      return message.error ? p.reject(new Error(message.error.message)) : p.resolve(message.result);
    }
    const p = message.params;
    if (message.method === 'Network.requestWillBeSent' && ['Document', 'Fetch'].includes(p.type)) {
      const pathname = publicPath(p.request.url);
      if (pathname) {
        docs.set(p.requestId, { pathname, startedMs: now(), type: p.type });
        events.push({ event: 'request', pathname, type: p.type, atMs: now() });
      }
    } else if (message.method === 'Network.responseReceived' && docs.has(p.requestId)) {
      const doc = docs.get(p.requestId);
      events.push({ event: 'response', pathname: doc.pathname, status: p.response.status, atMs: now(), elapsedMs: now() - doc.startedMs, fromDiskCache: p.response.fromDiskCache || false });
    } else if (message.method === 'Network.loadingFinished' && docs.has(p.requestId)) {
      const doc = docs.get(p.requestId);
      events.push({ event: 'body', pathname: doc.pathname, atMs: now(), elapsedMs: now() - doc.startedMs });
    } else if (message.method === 'Page.domContentEventFired' || message.method === 'Page.loadEventFired') {
      events.push({ event: message.method, atMs: now() });
    }
  };
  function call(method, params = {}) {
    const id = ++serial;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP timeout')); }, 6000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  await call('Network.enable'); await call('Page.enable');
  console.log('Timing observer ready');
  if (process.argv[4] === '--tap') {
    const [x, y] = process.argv.slice(5, 7).map(Number);
    if (![x, y].every(n => Number.isInteger(n) && n >= 0 && n <= 4000)) throw new Error('Invalid public UI tap');
    events.push({ event: 'tap', atMs: now(), x, y });
    execFileSync('D:/Codex-Migrated/Android/Sdk/platform-tools/adb.exe', ['-s', 'emulator-5554', 'shell', 'input', 'tap', String(x), String(y)], { timeout: 5000 });
  } else if (process.argv[4] === '--search-enter') {
    events.push({ event: 'submit-search', atMs: now() });
    execFileSync('D:/Codex-Migrated/Android/Sdk/platform-tools/adb.exe', ['-s', 'emulator-5554', 'shell', 'input', 'keyevent', '66'], { timeout: 5000 });
  } else if (process.argv[4] === '--swipe') {
    const points = process.argv.slice(5, 9).map(Number);
    if (points.length !== 4 || !points.every(n => Number.isInteger(n) && n >= 0 && n <= 4000)) throw new Error('Invalid public UI swipe');
    events.push({ event: 'swipe', atMs: now() });
    execFileSync('D:/Codex-Migrated/Android/Sdk/platform-tools/adb.exe', ['-s', 'emulator-5554', 'shell', 'input', 'swipe', ...points.map(String), '350'], { timeout: 5000 });
  }
  let last = '';
  for (let i = 0; i < seconds * 4; i++) {
    const r = await call('Runtime.evaluate', { expression: `JSON.stringify({path:location.pathname,ready:document.readyState,parked:window.__liteTaleReadContext===true,fetchPending:window.__liteTaleDocumentRead?.pending===true,book:!!document.querySelector('#content span b'),catalog:!!document.querySelector('table.css'),chapter:!!document.querySelector('#content'),navigation:performance.getEntriesByType('navigation').map(n=>({response:Math.round(n.responseStart),body:Math.round(n.responseEnd),interactive:Math.round(n.domInteractive),dom:Math.round(n.domContentLoadedEventEnd),load:Math.round(n.loadEventEnd)}))})`, returnByValue: true });
    const value = r.result.value;
    if (typeof value === 'string' && value !== last) {
      const data = JSON.parse(value);
      if (data.path === 'blank' || data.path === '/blank' || !data.path || publicPath('https://www.wenku8.net' + data.path)) events.push({ event: 'state', atMs: now(), ...data });
      last = value;
    }
    await pause(250);
  }
  await call('Network.disable');
  socket.close();
  fs.writeFileSync(output, JSON.stringify({ events }, null, 2));
  console.log(JSON.stringify({ output, events: events.filter(e => e.event !== 'state') }));
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
